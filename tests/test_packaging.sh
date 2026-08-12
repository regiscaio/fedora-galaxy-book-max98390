#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
SPEC="$REPO_ROOT/packaging/fedora/galaxybook-max98390-kmod.spec"
PRESET="$REPO_ROOT/data/systemd-preset/80-galaxybook-max98390.preset"
FINALIZER="$REPO_ROOT/scripts/max98390-kmod-finalize.sh"
FINALIZER_SERVICE="$REPO_ROOT/data/systemd/max98390-kmod-finalize.service"
FINALIZER_PATH="$REPO_ROOT/data/systemd/max98390-kmod-finalize.path"
SETUP_SERVICE="$REPO_ROOT/data/systemd/max98390-hda-i2c-setup.service"
KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"

[[ "$KERNEL_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe KERNEL_VERSION: $KERNEL_VERSION"

cleanup_packaging_fixture() {
    [[ -n "${PACKAGING_TMPDIR:-}" ]] || return 0
    case "$PACKAGING_TMPDIR" in
        "${TMPDIR:-/tmp}"/max98390-packaging-tests.*)
            rm -rf -- "$PACKAGING_TMPDIR"
            ;;
        *)
            printf 'refusing to remove unexpected fixture path: %s\n' "$PACKAGING_TMPDIR" >&2
            ;;
    esac
}

new_packaging_fixture() {
    PACKAGING_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/max98390-packaging-tests.XXXXXX")"
    trap cleanup_packaging_fixture EXIT
}

test_spec_forwards_requested_kernels() {
    assert_file_contains_fixed "$SPEC" '%{?kernels:--for-kernels "%{?kernels}"}' \
        'spec does not forward the Fedora akmods %{?kernels} macro to kmodtool --for-kernels'
}

test_systemd_preset_is_packaged() {
    assert_file_contains_fixed "$PRESET" 'enable max98390-hda-i2c-setup.service' \
        'preset does not enable the I2C setup unit'
    assert_file_contains_fixed "$PRESET" 'enable max98390-hda-check-upstream.service' \
        'preset does not enable the upstream check unit'
    assert_file_contains_fixed "$PRESET" 'enable max98390-kmod-finalize.path' \
        'preset does not enable the finalization path unit'
    assert_file_contains_fixed "$PRESET" 'enable max98390-kmod-finalize.service' \
        'preset does not enable finalization at boot'
    assert_file_contains_fixed "$SPEC" '%{_presetdir}/80-galaxybook-max98390.preset' \
        'spec does not include the vendor preset in the common package'
    assert_file_not_contains_fixed "$SPEC" 'systemctl enable max98390' \
        'spec still enables units manually instead of using the vendor preset'
    assert_file_not_contains_fixed "$SPEC" 'systemctl disable max98390' \
        'spec still disables units manually instead of using systemd macros'
}

test_finalizer_is_ordered_and_transaction_safe() {
    local expanded trigger_body

    command -v rpmspec >/dev/null 2>&1 || skip 'rpmspec is not installed'
    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    new_packaging_fixture
    expanded="$PACKAGING_TMPDIR/expanded.spec"
    trigger_body="$PACKAGING_TMPDIR/trigger.body"
    rpmspec -P --define "kernels $KERNEL_VERSION" "$SPEC" > "$expanded"

    awk '
        /^%transfiletriggerin / { in_trigger = 1; next }
        in_trigger && /^%/ { exit }
        in_trigger { print }
    ' "$expanded" > "$trigger_body"
    assert_file_contains_fixed "$trigger_body" \
        '/usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh --from-rpm-trigger' \
        'RPM file trigger does not delegate to queue-only mode'
    assert_file_not_contains_fixed "$trigger_body" 'rpm ' \
        'RPM file trigger still re-enters the RPM database'
    assert_file_not_contains_fixed "$trigger_body" 'rm ' \
        'RPM file trigger still removes legacy modules inside the transaction'
    assert_file_not_contains_fixed "$trigger_body" 'depmod' \
        'RPM file trigger still mutates module indexes inside the transaction'

    assert_file_contains_fixed "$FINALIZER_PATH" \
        'PathChanged=/var/lib/galaxybook-max98390/pending' \
        'path unit does not observe atomic queue publication'
    assert_file_not_contains_fixed "$FINALIZER_PATH" 'PathExistsGlob=' \
        'path unit can busy-loop on a structurally invalid pending marker'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'Wants=akmods.service systemd-logind.service' \
        'finalizer does not pull in akmods and the inhibitor service'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'After=local-fs.target akmods.service systemd-logind.service' \
        'finalizer is not ordered after akmods and systemd-logind'
    assert_file_contains_fixed "$FINALIZER_SERVICE" \
        'ExecStart=/usr/bin/systemd-inhibit --mode=block --what=shutdown:sleep:idle' \
        'finalizer work is not protected by a shutdown/sleep inhibitor'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'TimeoutStartSec=20min' \
        'finalizer timeout is too short for multiple per-kernel RPM lock waits'
    assert_file_contains_fixed "$SETUP_SERVICE" 'Requires=max98390-kmod-finalize.service' \
        'I2C setup can start without successful module finalization'
    assert_file_contains_fixed "$SETUP_SERVICE" 'After=akmods.service systemd-modules-load.service max98390-kmod-finalize.service' \
        'I2C setup is not ordered after module finalization'
    assert_file_contains_fixed "$FINALIZER" '"$FLOCK_COMMAND" --fcntl --shared' \
        'finalizer does not hold the RPM-compatible read lock'
    assert_file_not_contains_fixed "$SPEC" '%transfiletriggerun' \
        'package erase can trigger destructive module cleanup'
}

test_kmodtool_generates_kernel_payload_manifest() {
    local output expected_payload

    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/kmodtool.out"
    expected_payload="/lib/modules/$KERNEL_VERSION/extra/galaxybook-max98390/"

    kmodtool \
        --target "${RPM_ARCH:-x86_64}" \
        --repo fedora \
        --kmodname galaxybook-max98390 \
        --akmod \
        --for-kernels "$KERNEL_VERSION" > "$output"

    awk -v expected="${KERNEL_VERSION}___" '
        $1 == "%global" && $2 == "kernel_versions" && index($3, expected) == 1 {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$output" || fail 'kmodtool emitted an empty or wrong kernel_versions macro'
    assert_file_contains_fixed "$output" "$expected_payload" \
        'kmodtool did not declare the per-kernel module payload directory'
    assert_file_contains_fixed "$output" "kernel-modules%{!?with_rhel_kabi:-for-kernel} = $KERNEL_VERSION" \
        'kmodtool did not provide the requested kernel module capability'
}

test_rpmspec_expands_per_kernel_payload() {
    local output expected_payload

    command -v rpmspec >/dev/null 2>&1 || skip 'rpmspec is not installed'
    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/rpmspec.out"
    expected_payload="/lib/modules/$KERNEL_VERSION/extra/galaxybook-max98390/"

    rpmspec -P \
        --define "kernels $KERNEL_VERSION" \
        "$SPEC" > "$output"

    assert_file_contains_fixed "$output" \
        "%package       -n kmod-galaxybook-max98390-$KERNEL_VERSION" \
        'expanded spec has no package for the requested kernel'
    assert_file_contains_fixed "$output" "for kernel_version in ${KERNEL_VERSION}___" \
        'expanded spec has an empty kernel build loop'
    assert_file_contains_fixed "$output" "$expected_payload" \
        'expanded spec has no per-kernel payload manifest'
    assert_file_contains_fixed "$output" 'snd-hda-scodec-max98390.ko' \
        'expanded spec does not install the core module'
    assert_file_contains_fixed "$output" 'snd-hda-scodec-max98390-i2c.ko' \
        'expanded spec does not install the I2C module'
    assert_file_contains_fixed "$output" \
        '/usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh --from-rpm-trigger' \
        'expanded RPM trigger does not use the queue-only finalizer mode'

    awk -v payload="$expected_payload" '
        /^%files[[:space:]]+-n[[:space:]]+kmod-galaxybook-max98390-/ &&
            $NF != "kmod-galaxybook-max98390" {
            in_kernel_files = 1
            next
        }
        in_kernel_files && \
            /^%(package|description|prep|build|install|post|preun|postun|files|global)([[:space:]]|$)/ {
            in_kernel_files = 0
        }
        in_kernel_files && index($0, payload) {
            found_payload = 1
        }
        END {
            exit(found_payload ? 0 : 1)
        }
    ' "$output" || fail 'only the empty tracking metapackage was generated; no per-kernel %files payload exists'
}

test_built_rpm_contains_both_modules() {
    local rpm_path="${KMOD_RPM:-}"
    local output provides

    command -v rpm >/dev/null 2>&1 || skip 'rpm is not installed'
    [[ -n "$rpm_path" ]] || \
        skip 'set KMOD_RPM to the exact freshly built per-kernel RPM'

    [[ -f "$rpm_path" ]] || fail "KMOD_RPM does not exist: $rpm_path"
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/rpm-files.out"
    provides="$PACKAGING_TMPDIR/rpm-provides.out"

    rpm -qpl "$rpm_path" > "$output"
    rpm -qp --provides "$rpm_path" > "$provides"

    assert_file_contains_fixed "$output" "/lib/modules/$KERNEL_VERSION/" \
        'RPM payload targets a different kernel or is an empty metapackage'
    assert_file_contains_fixed "$output" '/snd-hda-scodec-max98390.ko' \
        'RPM payload lacks the core module'
    assert_file_contains_fixed "$output" '/snd-hda-scodec-max98390-i2c.ko' \
        'RPM payload lacks the I2C module'
    grep -Eq -- "^kernel-modules(-for-kernel)?[[:space:]]*=[[:space:]]*$KERNEL_VERSION$" "$provides" || \
        fail 'RPM does not provide kernel modules for the requested kernel'
}

test_built_common_rpm_contains_preset() {
    local rpm_path="${COMMON_RPM:-}"
    local output requires

    command -v rpm >/dev/null 2>&1 || skip 'rpm is not installed'
    [[ -n "$rpm_path" ]] || \
        skip 'set COMMON_RPM to the exact freshly built common RPM'

    [[ -f "$rpm_path" ]] || fail "COMMON_RPM does not exist: $rpm_path"
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/common-rpm-files.out"
    requires="$PACKAGING_TMPDIR/common-rpm-requires.out"
    rpm -qpl "$rpm_path" > "$output"
    rpm -qp --requires "$rpm_path" > "$requires"
    assert_file_contains_fixed "$output" \
        '/usr/lib/systemd/system-preset/80-galaxybook-max98390.preset' \
        'common RPM payload lacks the vendor preset'
    assert_file_contains_fixed "$output" \
        '/usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh' \
        'common RPM payload lacks the finalizer helper'
    assert_file_contains_fixed "$output" \
        '/usr/lib/systemd/system/max98390-kmod-finalize.path' \
        'common RPM payload lacks the finalizer path unit'
    assert_file_contains_fixed "$output" \
        '/usr/lib/systemd/system/max98390-kmod-finalize.service' \
        'common RPM payload lacks the finalizer service'
    assert_file_contains_fixed "$output" \
        '/var/lib/galaxybook-max98390/pending' \
        'common RPM payload lacks the durable pending directory'
    assert_file_contains_fixed "$output" \
        '/var/lib/galaxybook-max98390/deferred' \
        'common RPM payload lacks the deferred retry directory'
    for dependency in bash rpm systemd util-linux-core; do
        assert_file_contains_fixed "$requires" "$dependency" \
            "common RPM lacks runtime dependency $dependency"
    done
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    spec_forwards_requested_kernels \
    systemd_preset_is_packaged \
    finalizer_is_ordered_and_transaction_safe \
    kmodtool_generates_kernel_payload_manifest \
    rpmspec_expands_per_kernel_payload \
    built_rpm_contains_both_modules \
    built_common_rpm_contains_preset
