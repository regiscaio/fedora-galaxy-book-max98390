#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
SPEC="$REPO_ROOT/packaging/fedora/galaxybook-max98390-kmod.spec"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-dependency-fence-tests.XXXXXX")"

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-dependency-fence-tests.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup EXIT

build_fixture_rpm() {
    local name="$1"
    local version="$2"
    shift 2
    local topdir="$TEST_ROOT/rpmbuild-$name-$version"
    local spec_file="$topdir/SPECS/$name.spec"
    local requirement

    mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    {
        printf '%s\n' \
            "Name: $name" \
            "Version: $version" \
            'Release: 1' \
            'Summary: Isolated dependency solver fixture' \
            'License: MIT' \
            'BuildArch: noarch'
        for requirement in "$@"; do
            printf 'Requires: %s\n' "$requirement"
        done
        printf '%s\n' \
            '%description' \
            'Isolated dependency solver fixture.' \
            '%files'
    } > "$spec_file"
    rpmbuild -bb --quiet "$spec_file" --define "_topdir $topdir" \
        > "$TEST_ROOT/rpmbuild-$name-$version.log" 2>&1
    find "$topdir/RPMS" -type f -name "$name-$version-1.noarch.rpm" -print -quit
}

initialize_rpm_root() {
    local installroot="$1"

    mkdir -p "$installroot"
    rpm --root "$installroot" --initdb
}

seed_installed_rpm() {
    local installroot="$1"
    local rpm_path="$2"

    rpm --root "$installroot" --install --justdb --nodeps "$rpm_path"
}

dnf_solve() {
    local installroot="$1"
    local stored_transaction="$2"
    shift 2

    dnf5 --assumeyes \
        --installroot="$installroot" \
        --releasever=44 \
        --use-host-config \
        --disable-repo='*' \
        --no-gpgchecks \
        --setopt=install_weak_deps=False \
        install --store="$stored_transaction" "$@"
}

test_conditional_peer_floor_solver_matrix() {
    local max_requirement='(galaxybook-ov02c10-kmod-common >= 1.00.25 if galaxybook-ov02c10-kmod-common)'
    local setup_requirement='(galaxybook-setup >= 1.00.48 if galaxybook-setup)'
    local target ov_old ov_new setup_old setup_new
    local root status

    command -v rpmbuild >/dev/null 2>&1 || skip 'rpmbuild is not installed'
    command -v dnf5 >/dev/null 2>&1 || skip 'dnf5 is not installed'
    (( EUID == 0 )) || skip 'run the isolated DNF solver matrix as root in an ephemeral container'
    assert_file_contains_fixed "$SPEC" "Requires:       $max_requirement" \
        'spec lacks the conditional OV02C10 compatibility floor'
    assert_file_contains_fixed "$SPEC" "Requires:       $setup_requirement" \
        'spec lacks the conditional setup compatibility floor'

    target="$(build_fixture_rpm galaxybook-max98390-fence-test 1.00.12 \
        "$max_requirement" "$setup_requirement")"
    ov_old="$(build_fixture_rpm galaxybook-ov02c10-kmod-common 1.00.24)"
    ov_new="$(build_fixture_rpm galaxybook-ov02c10-kmod-common 1.00.25)"
    setup_old="$(build_fixture_rpm galaxybook-setup 1.00.47)"
    setup_new="$(build_fixture_rpm galaxybook-setup 1.00.48)"
    for rpm_path in "$target" "$ov_old" "$ov_new" "$setup_old" "$setup_new"; do
        [[ -f "$rpm_path" ]] || fail "fixture RPM was not built: $rpm_path"
    done

    root="$TEST_ROOT/root-absent"
    initialize_rpm_root "$root"
    if ! dnf_solve "$root" "$TEST_ROOT/transaction-absent" "$target" \
        > "$TEST_ROOT/absent.log" 2>&1; then
        tail -20 "$TEST_ROOT/absent.log" >&2
        fail 'absent optional peers were pulled or blocked installation'
    fi

    root="$TEST_ROOT/root-old"
    initialize_rpm_root "$root"
    seed_installed_rpm "$root" "$ov_old"
    seed_installed_rpm "$root" "$setup_old"
    set +e
    dnf_solve "$root" "$TEST_ROOT/transaction-old-reject" "$target" \
        > "$TEST_ROOT/old-reject.log" 2>&1
    status=$?
    set -e
    (( status != 0 )) || fail 'legacy peers were accepted without upgrades'
    rpm --root "$root" -q galaxybook-ov02c10-kmod-common-1.00.24-1.noarch \
        galaxybook-setup-1.00.47-1.noarch >/dev/null || \
        fail 'failed solve removed or replaced a legacy peer'
    if rpm --root "$root" -q galaxybook-max98390-fence-test >/dev/null 2>&1; then
        fail 'failed solve partially installed the target'
    fi

    dnf_solve "$root" "$TEST_ROOT/transaction-upgrade" \
        "$target" "$ov_new" "$setup_new" \
        > "$TEST_ROOT/upgrade.log" 2>&1 || \
        fail 'compatible peer upgrades did not solve with the target'

    root="$TEST_ROOT/root-new"
    initialize_rpm_root "$root"
    seed_installed_rpm "$root" "$ov_new"
    seed_installed_rpm "$root" "$setup_new"
    dnf_solve "$root" "$TEST_ROOT/transaction-new" "$target" \
        > "$TEST_ROOT/new.log" 2>&1 || \
        fail 'already-compatible peers did not solve with the target'
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    conditional_peer_floor_solver_matrix
