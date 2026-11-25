#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
SPEC="$REPO_ROOT/packaging/fedora/galaxybook-max98390-kmod.spec"
HELPER="$REPO_ROOT/scripts/finalizer-transaction.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-upgrade-quiescence-tests.XXXXXX")"
KERNEL_VERSION="${KERNEL_VERSION:-7.3.4-200.fc44.x86_64}"
COMMON_PACKAGE=galaxybook-max98390-kmod-common

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-upgrade-quiescence-tests.*)
            rm -rf -- "$TEST_ROOT"
            ;;
        *)
            printf 'refusing to remove unexpected fixture path: %s\n' "$TEST_ROOT" >&2
            ;;
    esac
}
trap cleanup EXIT

declare -a PRETRANS_ARGV=()
declare -a POSTTRANS_ARGV=()
POSTTRANS_BODY=""

read_rendered_scriptlets() {
    local metadata="$TEST_ROOT/scriptlet-metadata"
    local package="" section="" line

    command -v rpmspec >/dev/null 2>&1 || skip 'rpmspec is not installed'
    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    rpmspec -q \
        --qf $'PACKAGE=%{NAME}\nPRE-BEGIN\n[%{PRETRANSPROG}\n]PRE-END\nPOST-BEGIN\n[%{POSTTRANSPROG}\n]POST-END\nPOSTBODY-BEGIN\n%{POSTTRANS}\nPOSTBODY-END\n' \
        --define "_sourcedir $REPO_ROOT/scripts" \
        --define "_libexecdir $TEST_ROOT/libexec" \
        --define "kernels $KERNEL_VERSION" \
        --define 'pkg_version_override 1.00.12' \
        "$SPEC" > "$metadata"

    PRETRANS_ARGV=()
    POSTTRANS_ARGV=()
    POSTTRANS_BODY=""
    while IFS= read -r line; do
        case "$line" in
            PACKAGE=*)
                package="${line#PACKAGE=}"
                section=""
                ;;
            PRE-BEGIN|POST-BEGIN|POSTBODY-BEGIN)
                section="${line%-BEGIN}"
                ;;
            PRE-END|POST-END|POSTBODY-END)
                section=""
                ;;
            *)
                [[ "$package" == "$COMMON_PACKAGE" ]] || continue
                case "$section" in
                    PRE) PRETRANS_ARGV+=("$line") ;;
                    POST) POSTTRANS_ARGV+=("$line") ;;
                    POSTBODY) POSTTRANS_BODY+="${POSTTRANS_BODY:+$'\n'}${line}" ;;
                esac
                ;;
        esac
    done < "$metadata"
}

assert_array_equal() {
    local context="$1" expected_name="$2" actual_name="$3"
    local -n expected_ref="$expected_name"
    local -n actual_ref="$actual_name"
    local index

    assert_eq "${#expected_ref[@]}" "${#actual_ref[@]}" "$context argument count"
    for ((index = 0; index < ${#expected_ref[@]}; index++)); do
        assert_eq "${expected_ref[$index]}" "${actual_ref[$index]}" \
            "$context argument $index"
    done
}

expected_interpreter_argv() {
    EXPECTED_ARGV=(
        /usr/bin/env
        -i
        PATH=/usr/bin:/usr/sbin
        GALAXYBOOK_FINALIZER_FAMILY=max98390
        GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-max98390-kmod-common
        GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.12-0
        GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-ov02c10-kmod-common
        GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.25-0
        GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup
        GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0
        GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=max98390-kmod-finalize.path
        GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=max98390-hda-i2c-setup.service
        GALAXYBOOK_FINALIZER_SERVICE_UNIT=max98390-kmod-finalize.service
        GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-max98390/pending
        GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-max98390-finalizer-transaction-recovery.service
        GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-max98390-finalizer-transaction
        GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/max98390-kmod-finalize.service/cgroup.procs
        /usr/bin/bash
        --noprofile
        --norc
    )
}

test_rendered_interpreters_sanitize_environment_and_forward_count() {
    local probe="$TEST_ROOT/pretrans-probe"
    local observed="$TEST_ROOT/pretrans-observed"
    local -a EXPECTED_ARGV=()

    read_rendered_scriptlets
    expected_interpreter_argv
    assert_array_equal 'pretrans interpreter' EXPECTED_ARGV PRETRANS_ARGV
    assert_array_equal 'posttrans interpreter' EXPECTED_ARGV POSTTRANS_ARGV

    printf '%s\n' \
        '#!/usr/bin/bash' \
        'set -euo pipefail' \
        '[[ "$#" -eq 1 && "$1" == 2 ]]' \
        '[[ "${HOME+x}" != x ]]' \
        '[[ "${GALAXYBOOK_FINALIZER_UNEXPECTED+x}" != x ]]' \
        'printf "%s\n" "$GALAXYBOOK_FINALIZER_FAMILY" "$GALAXYBOOK_FINALIZER_OWN_FLOOR" "$GALAXYBOOK_FINALIZER_PEER_FLOOR" "$GALAXYBOOK_FINALIZER_SETUP_FLOOR" > "$0.observed"' \
        > "$probe"
    chmod 0755 "$probe"
    HOME=/unsafe GALAXYBOOK_FINALIZER_UNEXPECTED=unsafe \
        "${PRETRANS_ARGV[@]}" "$probe" 2
    mv -- "$probe.observed" "$observed"
    assert_file_contains_fixed "$observed" max98390 \
        'rendered pretrans lost the family ABI'
    assert_file_contains_fixed "$observed" 0:1.00.12-0 \
        'rendered pretrans lost the MAX98390 floor'
    assert_file_contains_fixed "$observed" 0:1.00.25-0 \
        'rendered pretrans lost the OV02C10 floor'
    assert_file_contains_fixed "$observed" 0:1.00.48-0 \
        'rendered pretrans lost the Setup floor'
}

test_rendered_posttrans_invokes_installed_helper_with_phase_and_count() {
    local helper_path="$TEST_ROOT/libexec/galaxybook-max98390/finalizer-transaction"
    local body="$TEST_ROOT/posttrans.body"
    local probe_dir="${helper_path%/*}"

    read_rendered_scriptlets
    mkdir -p -- "$probe_dir"
    printf '%s\n' \
        '#!/usr/bin/bash' \
        'set -euo pipefail' \
        'printf "%s\n" "$*" > "${0%/*}/observed.args"' \
        'printf "%s\n" "$GALAXYBOOK_FINALIZER_FAMILY" "$GALAXYBOOK_FINALIZER_OWN_FLOOR" "$GALAXYBOOK_FINALIZER_PEER_FLOOR" "$GALAXYBOOK_FINALIZER_SETUP_FLOOR" > "${0%/*}/observed.env"' \
        '[[ "${HOME+x}" != x ]]' \
        '[[ "${GALAXYBOOK_FINALIZER_UNEXPECTED+x}" != x ]]' \
        > "$helper_path"
    chmod 0755 "$helper_path"
    printf '%s\n' "$POSTTRANS_BODY" > "$body"

    HOME=/unsafe GALAXYBOOK_FINALIZER_UNEXPECTED=unsafe \
        "${POSTTRANS_ARGV[@]}" "$body" 2
    assert_eq '--posttrans 2' "$(< "$probe_dir/observed.args")" \
        'rendered posttrans did not forward phase and RPM instance count'
    assert_file_contains_fixed "$probe_dir/observed.env" max98390 \
        'rendered posttrans lost the family ABI'
    assert_file_contains_fixed "$probe_dir/observed.env" 0:1.00.12-0 \
        'rendered posttrans lost the MAX98390 floor'
    assert_file_contains_fixed "$probe_dir/observed.env" 0:1.00.25-0 \
        'rendered posttrans lost the OV02C10 floor'
    assert_file_contains_fixed "$probe_dir/observed.env" 0:1.00.48-0 \
        'rendered posttrans lost the Setup floor'
}

test_source2_is_embedded_and_installed_from_the_same_helper() {
    assert_file_contains_fixed "$SPEC" \
        'Source2:        finalizer-transaction.sh' \
        'spec does not declare the transaction helper as Source2'
    assert_file_contains_fixed "$SPEC" \
        'Source3:        finalizer-transaction-pretrans.sh' \
        'spec does not declare the mechanically escaped pretrans source'
    assert_file_contains_fixed "$SPEC" \
        '%pretrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}" -f %{SOURCE3}' \
        'pretrans does not embed Source3 through the sanitized interpreter'
    assert_file_contains_fixed "$SPEC" \
        'install -Dm0755 %{SOURCE2}' \
        'spec does not install the exact helper bytes embedded in pretrans'
    assert_file_contains_fixed "$SPEC" \
        '%{_libexecdir}/%{prjname}/finalizer-transaction' \
        'common package does not own the installed transaction helper'
    assert_file_contains_fixed "$HELPER" \
        'finalizer_transaction_main "$@"' \
        'transaction helper has no executable entry point'
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    rendered_interpreters_sanitize_environment_and_forward_count \
    rendered_posttrans_invokes_installed_helper_with_phase_and_count \
    source2_is_embedded_and_installed_from_the_same_helper
