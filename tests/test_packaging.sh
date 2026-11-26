#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
SPEC="$REPO_ROOT/packaging/fedora/galaxybook-max98390-kmod.spec"
PRESET="$REPO_ROOT/data/systemd-preset/80-galaxybook-max98390.preset"
FINALIZER="$REPO_ROOT/scripts/max98390-kmod-finalize.sh"
LIFECYCLE_LOCK="$REPO_ROOT/scripts/kmod-lifecycle-lock.sh"
KMODTOOL_FILTER="$REPO_ROOT/scripts/kmodtool-queue-only-filter.sh"
TRANSACTION_HELPER="$REPO_ROOT/scripts/finalizer-transaction.sh"
DEPMOD_CONFIG="$REPO_ROOT/data/depmod.d/galaxybook-max98390.conf"
MAKEFILE="$REPO_ROOT/Makefile"
VERSION_SCRIPT="$REPO_ROOT/scripts/package-version.sh"
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

test_natural_version_satisfies_transaction_floor() {
    local natural_version comparison

    command -v rpm >/dev/null 2>&1 || skip 'rpm is not installed'
    natural_version="$("$VERSION_SCRIPT")"
    [[ "$natural_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        fail "natural package version is malformed: $natural_version"
    comparison="$(RPMVER_LEFT="$natural_version" RPMVER_RIGHT=1.00.12 \
        rpm --eval '%{lua:io.write(rpm.vercmp(os.getenv("RPMVER_LEFT"), os.getenv("RPMVER_RIGHT")), "\n")}' \
        2>/dev/null)"
    [[ "$comparison" =~ ^-?[01]$ ]] || \
        fail "rpm.vercmp returned a non-canonical result: $comparison"
    (( comparison >= 0 )) || \
        fail "natural version $natural_version is below transaction floor 1.00.12; create a normal release commit before building"
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
    local expanded rhel_expanded repo_expanded trigger_body

    command -v rpmspec >/dev/null 2>&1 || skip 'rpmspec is not installed'
    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    new_packaging_fixture
    expanded="$PACKAGING_TMPDIR/expanded.spec"
    repo_expanded="$PACKAGING_TMPDIR/repo.spec"
    rhel_expanded="$PACKAGING_TMPDIR/rhel-expanded.spec"
    trigger_body="$PACKAGING_TMPDIR/trigger.body"
    rpmspec -P --define "_sourcedir $REPO_ROOT/scripts" "$SPEC" > "$repo_expanded"
    rpmspec -P \
        --define "_sourcedir $REPO_ROOT/scripts" \
        --define "kernels $KERNEL_VERSION" \
        "$SPEC" > "$expanded"
    rpmspec -P \
        --define "_sourcedir $REPO_ROOT/scripts" \
        --define "kernels $KERNEL_VERSION" \
        --define "with_rhel_kabi 1" \
        "$SPEC" > "$rhel_expanded"

    awk '
        /^%transfiletriggerin / { in_trigger = 1; next }
        in_trigger && /^%/ { exit }
        in_trigger { print }
    ' "$repo_expanded" > "$trigger_body"
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
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'KillMode=control-group' \
        'finalizer does not terminate the complete OFD-holding process tree'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'TimeoutStartSec=20min' \
        'finalizer timeout is too short for multiple per-kernel RPM lock waits'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'Restart=on-failure' \
        'global-lock failure does not trigger a durable retry'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'RestartSec=60s' \
        'global-lock retry delay is not bounded'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'StartLimitIntervalSec=30min' \
        'finalizer retry burst has no explicit interval'
    assert_file_contains_fixed "$FINALIZER_SERVICE" 'StartLimitBurst=20' \
        'finalizer retry burst is not bounded'
    assert_file_contains_fixed "$FINALIZER_SERVICE" \
        'ExecStartPost=/usr/bin/systemctl --no-block start max98390-hda-i2c-setup.service' \
        'a successful finalizer retry does not requeue the dependent hardware setup'
    assert_file_contains_fixed "$SETUP_SERVICE" 'Requires=max98390-kmod-finalize.service' \
        'I2C setup can start without successful module finalization'
    assert_file_contains_fixed "$SETUP_SERVICE" 'After=akmods.service systemd-modules-load.service max98390-kmod-finalize.service' \
        'I2C setup is not ordered after module finalization'
    assert_file_contains_fixed "$FINALIZER" '"$FLOCK_COMMAND" --fcntl --shared' \
        'finalizer does not hold the RPM-compatible read lock'
    assert_file_contains_fixed "$FINALIZER" 'acquire_kmod_lifecycle_lock' \
        'finalizer does not acquire the cross-driver lifecycle lock'
    assert_file_not_contains_fixed "$SPEC" '%transfiletriggerun' \
        'package erase can trigger destructive module cleanup'
    # The packaged depmod.d pathname legitimately contains the token "depmod".
    # Exact no-op assertions below, plus the trigger-body checks above, prove
    # that no generated per-kernel scriptlet executes depmod/weak-modules.
    assert_file_not_contains_fixed "$rhel_expanded" \
        '%preun         -n kmod-galaxybook-max98390-' \
        'RHEL-kABI expansion still emits an exact-package preun scriptlet'
    awk -v package="kmod-galaxybook-max98390-${KERNEL_VERSION}" '
        $0 == "%post          -n " package ||
            $0 == "%postun        -n " package {
            in_scriptlet = 1
            scriptlet_count++
            next
        }
        in_scriptlet && /^%/ {
            in_scriptlet = 0
        }
        in_scriptlet && NF {
            body_count++
            if ($0 != ":") {
                bad_body = 1
            }
        }
        END {
            exit(scriptlet_count == 2 && body_count == 2 && !bad_body ? 0 : 1)
        }
    ' "$expanded" || fail \
        'generated per-kernel post/postun scriptlets are not strict queue-only no-ops'
    awk '
        /^%post(un)?[[:space:]]+-n[[:space:]]+kmod-galaxybook-max98390-/ {
            if (getline <= 0 || $0 != ":") exit 1
            if (getline <= 0 || NF) exit 1
            count++
        }
        END { exit count == 2 ? 0 : 1 }
    ' "$rhel_expanded" || fail \
        'RHEL-kABI per-kernel post/postun scriptlets are not strict no-ops'
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
    local output expected_payload actual expected

    command -v rpmspec >/dev/null 2>&1 || skip 'rpmspec is not installed'
    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/rpmspec.out"
    expected_payload="/lib/modules/$KERNEL_VERSION/extra/galaxybook-max98390/"

    # akmodsbuild hands every result to DNF; an extra common RPM would
    # run its host-wide pretrans during a local --rebuild/reinstall.
    actual=$(rpmspec -q --builtrpms --qf '%{NAME}\n' \
        --define "_sourcedir $REPO_ROOT/scripts" --define "kernels $KERNEL_VERSION" "$SPEC")
    [[ "$actual" == "kmod-galaxybook-max98390-$KERNEL_VERSION" ]] || \
        fail "unexpected set of explicit-kernel RPMs: $actual"
    actual=$(rpmspec -q --builtrpms --qf '%{NAME}\n' \
        --define "_sourcedir $REPO_ROOT/scripts" "$SPEC" | LC_ALL=C sort)
    expected=$'akmod-galaxybook-max98390\ngalaxybook-max98390-kmod-common\nkmod-galaxybook-max98390'
    [[ "$actual" == "$expected" ]] || fail "unexpected repository RPMs: $actual"

    rpmspec -P \
        --define "_sourcedir $REPO_ROOT/scripts" \
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
    assert_file_not_contains_fixed "$output" '%transfiletriggerin' \
        'kernel rebuild redeclared the file trigger owned by the installed common package'
    assert_file_not_contains_fixed "$output" '%package -n galaxybook-max98390-kmod-common' \
        'kernel rebuild would reinstall the repository common package'
    assert_file_not_contains_fixed "$output" '/usr/libexec/galaxybook-max98390/' \
        'kernel rebuild unexpectedly stages the common helpers'
    assert_file_not_contains_fixed "$output" '/var/lib/galaxybook-max98390/' \
        'kernel rebuild unexpectedly stages the host-wide queue directories'
    assert_file_contains_fixed "$output" 'galaxybook-max98390-kmod-common >=' \
        'kernel rebuild no longer depends on a compatible repository common package'

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
    local output provides requires scriptlets

    command -v rpm >/dev/null 2>&1 || skip 'rpm is not installed'
    [[ -n "$rpm_path" ]] || \
        skip 'set KMOD_RPM to the exact freshly built per-kernel RPM'

    [[ -f "$rpm_path" ]] || fail "KMOD_RPM does not exist: $rpm_path"
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/rpm-files.out"
    provides="$PACKAGING_TMPDIR/rpm-provides.out"
    requires="$PACKAGING_TMPDIR/rpm-requires.out"
    scriptlets="$PACKAGING_TMPDIR/rpm-scriptlets.out"

    rpm -qpl "$rpm_path" > "$output"
    rpm -qp --provides "$rpm_path" > "$provides"
    rpm -qp --requires "$rpm_path" > "$requires"
    rpm -qp --scripts "$rpm_path" > "$scriptlets"

    assert_file_contains_fixed "$output" "/lib/modules/$KERNEL_VERSION/" \
        'RPM payload targets a different kernel or is an empty metapackage'
    assert_file_contains_fixed "$output" '/snd-hda-scodec-max98390.ko' \
        'RPM payload lacks the core module'
    assert_file_contains_fixed "$output" '/snd-hda-scodec-max98390-i2c.ko' \
        'RPM payload lacks the I2C module'
    grep -Eq -- "^kernel-modules(-for-kernel)?[[:space:]]*=[[:space:]]*$KERNEL_VERSION$" "$provides" || \
        fail 'RPM does not provide kernel modules for the requested kernel'
    assert_file_not_contains_fixed "$requires" depmod \
        'per-kernel RPM retains a depmod scriptlet dependency'
    assert_file_not_contains_fixed "$requires" weak-modules \
        'per-kernel RPM retains a weak-modules scriptlet dependency'
    assert_file_not_contains_fixed "$scriptlets" depmod \
        'per-kernel RPM retains an in-transaction depmod call'
    assert_file_not_contains_fixed "$scriptlets" weak-modules \
        'per-kernel RPM retains an in-transaction weak-modules call'
    assert_file_not_contains_fixed "$scriptlets" preun \
        'per-kernel RPM retains an in-transaction preun scriptlet'
    assert_prefix_count "$scriptlets" \
        ':' 2 \
        'per-kernel RPM post/postun scriptlets are not strict no-ops'
}

test_built_common_rpm_contains_preset() {
    local rpm_path="${COMMON_RPM:-}"
    local output requires scriptlets file_modes file_digests helper_digest pretrans_body

    command -v rpm >/dev/null 2>&1 || skip 'rpm is not installed'
    [[ -n "$rpm_path" ]] || \
        skip 'set COMMON_RPM to the exact freshly built common RPM'

    [[ -f "$rpm_path" ]] || fail "COMMON_RPM does not exist: $rpm_path"
    new_packaging_fixture
    output="$PACKAGING_TMPDIR/common-rpm-files.out"
    requires="$PACKAGING_TMPDIR/common-rpm-requires.out"
    scriptlets="$PACKAGING_TMPDIR/common-rpm-scriptlets.out"
    file_modes="$PACKAGING_TMPDIR/common-rpm-file-modes.out"
    file_digests="$PACKAGING_TMPDIR/common-rpm-file-digests.out"
    pretrans_body="$PACKAGING_TMPDIR/common-rpm-pretrans.body"
    rpm -qpl "$rpm_path" > "$output"
    rpm -qp --requires "$rpm_path" > "$requires"
    rpm -qp --scripts "$rpm_path" > "$scriptlets"
    rpm -qp --qf '[%{FILENAMES}\t%{FILEMODES:perms}\n]' \
        "$rpm_path" > "$file_modes"
    rpm -qp --qf '[%{FILENAMES}\t%{FILEDIGESTS}\n]' \
        "$rpm_path" > "$file_digests"
    rpm -qp --qf '%{PRETRANS}' "$rpm_path" > "$pretrans_body"
    bash -n "$pretrans_body" || \
        fail 'built common RPM pretrans is not valid Bash'
    helper_digest="$(sha256sum "$TRANSACTION_HELPER")"
    helper_digest="${helper_digest%% *}"
    assert_file_contains_fixed "$output" \
        '/usr/lib/systemd/system-preset/80-galaxybook-max98390.preset' \
        'common RPM payload lacks the vendor preset'
    assert_file_contains_fixed "$output" \
        '/usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh' \
        'common RPM payload lacks the finalizer helper'
    assert_file_contains_fixed "$output" \
        '/usr/libexec/galaxybook-max98390/finalizer-transaction' \
        'common RPM payload lacks the transaction recovery helper'
    assert_file_contains_fixed "$output" \
        '/usr/libexec/galaxybook-max98390/kmod-lifecycle-lock.sh' \
        'common RPM payload lacks the cross-driver lifecycle lock helper'
    assert_file_contains_fixed "$output" \
        '/usr/lib/depmod.d/galaxybook-max98390.conf' \
        'common RPM payload lacks the non-destructive MAX98390 priority policy'
    assert_file_contains_fixed "$file_modes" \
        $'/usr/libexec/galaxybook-max98390/kmod-lifecycle-lock.sh\t-rw-r--r--' \
        'packaged lifecycle helper is not source-only mode 0644'
    assert_file_contains_fixed "$file_modes" \
        $'/usr/libexec/galaxybook-max98390/finalizer-transaction\t-rwxr-xr-x' \
        'packaged transaction recovery helper is not executable mode 0755'
    assert_file_contains_fixed "$file_digests" \
        $'/usr/libexec/galaxybook-max98390/finalizer-transaction\t'"$helper_digest" \
        'packaged transaction recovery helper differs from Source2'
    cmp -s -- "$TRANSACTION_HELPER" "$pretrans_body" || \
        fail 'built common RPM pretrans differs from the complete Source2 helper'
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
    for dependency in bash coreutils diffutils rpm systemd util-linux-core; do
        assert_file_contains_fixed "$requires" "$dependency" \
            "common RPM lacks runtime dependency $dependency"
    done
    assert_file_contains_fixed "$requires" \
        '(galaxybook-ov02c10-kmod-common >= 1.00.25 if galaxybook-ov02c10-kmod-common)' \
        'common RPM does not fence an installed legacy OV02C10 peer'
    assert_file_contains_fixed "$requires" \
        '(galaxybook-setup >= 1.00.48 if galaxybook-setup)' \
        'common RPM does not fence an installed legacy setup peer'
    assert_file_contains_fixed "$scriptlets" \
        'usage: finalizer-transaction <rpm-instance-count>' \
        'built common RPM does not embed the transaction helper in pretrans'
    assert_file_contains_fixed "$scriptlets" \
        '/usr/libexec/galaxybook-max98390/finalizer-transaction --posttrans "$1"' \
        'built common RPM does not invoke posttrans recovery with the instance count'
}

test_lifecycle_lock_contract_is_packaged() {
    assert_file_contains_fixed "$LIFECYCLE_LOCK" \
        'kmod_lifecycle_lock_path="/run/lock/galaxybook-kmod-lifecycle.lock"' \
        'lifecycle helper does not use the fixed cross-driver lock path'
    assert_file_contains_fixed "$LIFECYCLE_LOCK" \
        'kmod_lifecycle_lock_timeout_seconds="600"' \
        'lifecycle helper does not bound lock contention'
    assert_file_contains_fixed "$LIFECYCLE_LOCK" \
        'GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD' \
        'lifecycle helper cannot authenticate an inherited descriptor'
    assert_file_contains_fixed "$SPEC" \
        'scripts/kmod-lifecycle-lock.sh' \
        'spec does not install the cross-driver lifecycle helper'
    assert_file_contains_fixed "$SPEC" \
        '%{_libexecdir}/%{prjname}/kmod-lifecycle-lock.sh' \
        'spec does not own the installed cross-driver lifecycle helper'
}

test_depmod_override_is_narrow_and_packaged() {
    assert_file_contains_fixed "$DEPMOD_CONFIG" \
        'override snd-hda-scodec-max98390 * extra/galaxybook-max98390/sound/hda/codecs/side-codecs' \
        'depmod policy does not prioritize the RPM-owned MAX98390 core payload'
    assert_file_contains_fixed "$DEPMOD_CONFIG" \
        'override snd-hda-scodec-max98390-i2c * extra/galaxybook-max98390/sound/hda/codecs/side-codecs' \
        'depmod policy does not prioritize the RPM-owned MAX98390 I2C payload'
    assert_prefix_count "$DEPMOD_CONFIG" 'override ' 2 \
        'depmod policy contains rules outside the two MAX98390 module names'
    assert_file_contains_fixed "$SPEC" \
        'data/depmod.d/galaxybook-max98390.conf' \
        'spec does not install the MAX98390 depmod policy'
    assert_file_contains_fixed "$SPEC" \
        '%{_depmoddir}/galaxybook-max98390.conf' \
        'common package does not own the MAX98390 depmod policy'
}

test_kmodtool_filter_is_a_fail_closed_build_source() {
    assert_file_contains_fixed "$SPEC" \
        'Source1:        kmodtool-queue-only-filter.sh' \
        'spec does not declare the queue-only kmodtool filter as a source'
    assert_file_contains_fixed "$SPEC" \
        '/usr/bin/bash "%{SOURCE1}" --expected-kernels' \
        'spec does not run kmodtool through the queue-only filter'
    assert_file_contains_fixed "$SPEC" \
        '%if %{exists:/usr/bin/kmodtool}' \
        'spec cannot defer kmodtool until binary BuildRequires are installed'
    assert_file_contains_fixed "$SPEC" \
        '%if %{kmodtool_queue_only_filter_ok} != 1' \
        'spec does not require the exact kmodtool filter success sentinel'
    assert_file_contains_fixed "$SPEC" \
        '%global kmodtool_queue_only_build_verified 1' \
        'successful filtering does not authorize the binary build stages'
    assert_file_contains_fixed "$SPEC" \
        '%global kmodtool_queue_only_filter_deferred 1' \
        'source-only bootstrap does not record deferred filtering'
    assert_file_contains_fixed "$SPEC" \
        '%{?kernels:%{error:kmodtool is required to generate a source RPM with explicit kernels}}' \
        'source-only bootstrap can discard an explicit kernel payload request'
    assert_file_contains_fixed "$SPEC" \
        'kmodtool queue-only filtering was deferred; refusing an unverified binary build' \
        'binary prep does not fail closed after source-only bootstrap'
    assert_file_contains_fixed "$KMODTOOL_FILTER" \
        '> "${kmodtool_queue_only_temp_dir}/command.stdout"' \
        'kmodtool filter does not buffer upstream output before validation'
    assert_file_contains_fixed "$MAKEFILE" \
        'cp "$(KMODTOOL_FILTER)" "$(RPMBUILD_DIR)/SOURCES/"' \
        'RPM build does not stage the declared kmodtool filter source'
    for dependency in akmods bash coreutils diffutils kmodtool; do
        assert_file_contains_fixed "$SPEC" "BuildRequires:  $dependency" \
            "spec lacks kmodtool filter build dependency $dependency"
    done
}

test_release_source_is_exactly_the_committed_tree() {
    assert_file_contains_fixed "$MAKEFILE" \
        'git diff --quiet --ignore-submodules --' \
        'source build does not reject tracked worktree changes'
    assert_file_contains_fixed "$MAKEFILE" \
        "git archive --format=tar --prefix='\$(PACKAGE_NAME)-\$(VERSION)/' HEAD" \
        'source tarball is not archived from the exact release commit'
    assert_file_not_contains_fixed "$MAKEFILE" \
        "--transform='s,^\\./,\$(PACKAGE_NAME)-\$(VERSION)/,'" \
        'source tarball still includes arbitrary worktree paths'
}

test_common_upgrade_uses_authenticated_transaction_recovery() {
    local dependency

    assert_file_contains_fixed "$SPEC" \
        'Source2:        finalizer-transaction.sh' \
        'common upgrade does not declare the transaction helper source'
    assert_file_contains_fixed "$SPEC" \
        'Source3:        finalizer-transaction-pretrans.sh' \
        'common upgrade does not declare the macro-escaped pretrans source'
    assert_file_contains_fixed "$SPEC" \
        '%pretrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}" -f %{SOURCE3}' \
        'common upgrade does not embed the escaped helper through the sanitized interpreter'
    assert_file_contains_fixed "$SPEC" \
        'install -Dm0755 %{SOURCE2}' \
        'installed transaction helper does not use the authenticated Source2 bytes'
    assert_file_contains_fixed "$SPEC" \
        '%posttrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}"' \
        'common upgrade has no sanitized post-transaction recovery hook'
    assert_file_contains_fixed "$SPEC" \
        '%{_libexecdir}/%{prjname}/finalizer-transaction --posttrans "$1"' \
        'posttrans does not forward its phase and RPM instance count'
    assert_file_contains_fixed "$SPEC" \
        'GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=max98390-hda-i2c-setup.service' \
        'transaction ABI does not fence the dependent hardware setup service'
    assert_file_contains_fixed "$TRANSACTION_HELPER" \
        'finalizer_transaction_mask_and_drain' \
        'transaction helper does not mask and drain the old graph'
    assert_file_contains_fixed "$TRANSACTION_HELPER" \
        'start --no-block' \
        'transaction recovery can wait on a worker while holding the RPM fence'
    assert_file_contains_fixed "$MAKEFILE" \
        'cp "$(FINALIZER_TRANSACTION)" "$(RPMBUILD_DIR)/SOURCES/"' \
        'RPM build does not stage the transaction helper source'
    assert_file_contains_fixed "$MAKEFILE" \
        "sed 's/%/%%/g' \"\$<\" > \"\$@\"" \
        'RPM build does not mechanically escape the complete pretrans source'
    assert_file_not_contains_fixed "$TRANSACTION_HELPER" '%{' \
        'Source2 contains an RPM macro token that can corrupt pretrans expansion'
    for dependency in bash coreutils diffutils rpm systemd util-linux-core; do
        assert_file_contains_fixed "$SPEC" "Requires(pretrans): $dependency" \
            "pretrans lacks transaction helper dependency $dependency"
        assert_file_contains_fixed "$SPEC" "Requires(posttrans): $dependency" \
            "posttrans lacks transaction helper dependency $dependency"
    done
    assert_file_not_contains_fixed "$SPEC" \
        'Conflicts:      galaxybook-max98390-kmod <' \
        'common package prevents normal akmods bootstrap upgrades'
}

test_spec_rejects_a_filter_without_success_marker() {
    local fake_source_dir output status

    command -v rpmspec >/dev/null 2>&1 || skip 'rpmspec is not installed'
    new_packaging_fixture
    fake_source_dir="$PACKAGING_TMPDIR/fake-sources"
    output="$PACKAGING_TMPDIR/rejected-filter.out"
    mkdir -p "$fake_source_dir"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 73' \
        > "$fake_source_dir/kmodtool-queue-only-filter.sh"
    chmod 0755 "$fake_source_dir/kmodtool-queue-only-filter.sh"

    set +e
    rpmspec -P \
        --define "_sourcedir $fake_source_dir" \
        --define "kernels $KERNEL_VERSION" \
        --define "kmodtool_queue_only_filter_ok 1" \
        --define "kmodtool_queue_only_filter_ok 1" \
        "$SPEC" > "$output" 2>&1
    status=$?
    set -e

    (( status != 0 )) || fail \
        'spec accepted a failed filter through stacked external success macros'
    assert_file_contains_fixed "$output" 'kmodtool queue-only filtering failed' \
        'spec rejection did not identify the missing filter success marker'
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    natural_version_satisfies_transaction_floor \
    spec_forwards_requested_kernels \
    systemd_preset_is_packaged \
    finalizer_is_ordered_and_transaction_safe \
    kmodtool_generates_kernel_payload_manifest \
    rpmspec_expands_per_kernel_payload \
    built_rpm_contains_both_modules \
    built_common_rpm_contains_preset \
    lifecycle_lock_contract_is_packaged \
    depmod_override_is_narrow_and_packaged \
    kmodtool_filter_is_a_fail_closed_build_source \
    release_source_is_exactly_the_committed_tree \
    common_upgrade_uses_authenticated_transaction_recovery \
    spec_rejects_a_filter_without_success_marker
