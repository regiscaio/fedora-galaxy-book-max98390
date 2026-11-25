#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
FILTER="$REPO_ROOT/scripts/kmodtool-queue-only-filter.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-kmodtool-filter-tests.XXXXXX")"
KERNELS="${KERNELS:-7.1.6-201.fc44.x86_64 7.1.8-200.fc44.x86_64}"
KMODNAME=galaxybook-max98390

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-kmodtool-filter-tests.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup EXIT

require_kmodtool_kernels() {
    local kernel

    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    for kernel in $KERNELS; do
        [[ -f "/usr/src/kernels/${kernel}/Makefile" ]] || \
            skip "kernel development tree is unavailable: $kernel"
    done
}

generate_raw_exact() {
    local output="$1"

    require_kmodtool_kernels
    /usr/bin/kmodtool \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod \
        --for-kernels "$KERNELS" > "$output"
}

generate_raw_akmod() {
    local output="$1"

    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    /usr/bin/kmodtool \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod > "$output"
}

make_fake_kmodtool() {
    local fake_command="$1"

    printf '%s\n' \
        '#!/usr/bin/bash' \
        'set -euo pipefail' \
        'case "${KMODTOOL_TEST_MODE:-output}" in' \
        '  output) /usr/bin/cat -- "$KMODTOOL_TEST_OUTPUT" ;;' \
        '  warning) /usr/bin/cat -- "$KMODTOOL_TEST_OUTPUT"; printf "%s\n" synthetic-warning >&2 ;;' \
        '  failure) printf "%s\n" partial-output; printf "%s\n" synthetic-failure >&2; exit 73 ;;' \
        'esac' > "$fake_command"
    chmod 0755 "$fake_command"
}

run_fake_exact() {
    local input="$1"
    local mode="$2"
    local fake="$TEST_ROOT/fake-kmodtool"

    make_fake_kmodtool "$fake"
    KMODTOOL_TEST_OUTPUT="$input" KMODTOOL_TEST_MODE="$mode" \
        "$FILTER" --expected-kernels "$KERNELS" -- \
        "$fake" \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod \
        --for-kernels "$KERNELS"
}

run_fake_akmod() {
    local input="$1"
    local mode="$2"
    local fake="$TEST_ROOT/fake-kmodtool-akmod"

    make_fake_kmodtool "$fake"
    KMODTOOL_TEST_OUTPUT="$input" KMODTOOL_TEST_MODE="$mode" \
        "$FILTER" --expected-kernels "" -- \
        "$fake" \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod
}

assert_rejected_without_stdout() {
    local expected_status="$1"
    local output="$2"
    local actual_status="$3"
    local context="$4"

    assert_eq "$expected_status" "$actual_status" "$context returned the wrong status"
    [[ ! -s "$output" ]] || fail "$context leaked unauthenticated stdout"
}

test_real_per_kernel_output_becomes_strictly_queue_only() {
    local output="$TEST_ROOT/per-kernel.out"
    local kernel_count

    require_kmodtool_kernels
    kernel_count="$(wc -w <<< "$KERNELS")"
    "$FILTER" --expected-kernels "$KERNELS" -- \
        /usr/bin/kmodtool \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod \
        --for-kernels "$KERNELS" > "$output"

    assert_file_not_contains_fixed "$output" depmod \
        'filtered output retains an in-transaction depmod path'
    assert_file_not_contains_fixed "$output" weak-modules \
        'filtered output retains an in-transaction weak-modules path'
    assert_prefix_count "$output" '%preun' 0 \
        'filtered output retains a preun scriptlet'
    assert_prefix_count "$output" '%post          -n %{package_kmod_name}' \
        "$kernel_count" 'filtered output has the wrong per-kernel post count'
    assert_prefix_count "$output" '%postun        -n %{package_kmod_name}' \
        "$kernel_count" 'filtered output has the wrong per-kernel postun count'
    awk '
        /^%post(un)?[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
            if (getline <= 0 || $0 != ":") exit 1
            if (getline <= 0 || NF) exit 1
            count++
        }
        END { exit count == 4 ? 0 : 1 }
    ' "$output" || fail 'per-kernel scriptlets are not single no-ops'
    assert_file_contains_fixed "$output" \
        '%global kmodtool_queue_only_filter_ok 1' \
        'validated output lacks the success marker'
}

test_akmod_only_output_has_only_the_two_known_scriptlets() {
    local output="$TEST_ROOT/akmod-only.out"

    command -v kmodtool >/dev/null 2>&1 || skip 'kmodtool is not installed'
    "$FILTER" --expected-kernels "" -- \
        /usr/bin/kmodtool \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod > "$output"

    assert_file_not_contains_fixed "$output" depmod \
        'akmod-only template unexpectedly contains depmod'
    assert_prefix_count "$output" '%package       -n %{package_kmod_name}' 0 \
        'akmod-only template contains a per-kernel package'
    assert_prefix_count "$output" "%posttrans     -n akmod-$KMODNAME" 1 \
        'akmod-only template has the wrong posttrans count'
    assert_prefix_count "$output" "%post     -n akmod-$KMODNAME" 1 \
        'akmod-only template has the wrong post count'
    assert_file_contains_fixed "$output" \
        "nohup /usr/sbin/akmods --from-akmod-posttrans --akmod $KMODNAME &> /dev/null &" \
        'akmod posttrans body changed'
    assert_file_contains_fixed "$output" \
        "[ -x /usr/sbin/akmods-ostree-post ] && /usr/sbin/akmods-ostree-post $KMODNAME" \
        'akmod post body changed'
    assert_file_contains_fixed "$output" \
        '%global kmodtool_queue_only_filter_ok 1' \
        'akmod-only output lacks the success marker'
}

test_upstream_failure_preserves_status_and_emits_no_partial_output() {
    local raw="$TEST_ROOT/upstream-raw.spec"
    local output="$TEST_ROOT/upstream-failure.out"
    local status

    generate_raw_exact "$raw"
    set +e
    run_fake_exact "$raw" failure > "$output" 2> "$TEST_ROOT/upstream-failure.err"
    status=$?
    set -e

    assert_rejected_without_stdout 73 "$output" "$status" 'upstream failure'
    assert_file_contains_fixed "$TEST_ROOT/upstream-failure.err" synthetic-failure \
        'upstream failure diagnostic was lost'
}

test_status_zero_stderr_fails_closed() {
    local raw="$TEST_ROOT/stderr-raw.spec"
    local output="$TEST_ROOT/stderr.out"
    local status

    generate_raw_exact "$raw"
    set +e
    run_fake_exact "$raw" warning > "$output" 2> "$TEST_ROOT/stderr.err"
    status=$?
    set -e

    assert_rejected_without_stdout 65 "$output" "$status" 'status-zero stderr'
    assert_file_contains_fixed "$TEST_ROOT/stderr.err" synthetic-warning \
        'status-zero diagnostic was lost'
}

test_noncanonical_byte_streams_fail_closed() {
    local mode input output status raw="$TEST_ROOT/bytes-raw.spec"

    generate_raw_exact "$raw"
    for mode in nul cr missing_lf; do
        input="$TEST_ROOT/${mode}.spec"
        output="$TEST_ROOT/${mode}.out"
        cp -- "$raw" "$input"
        case "$mode" in
            nul)
                printf '\0\n' >> "$input"
                ;;
            cr)
                printf '\r\n' >> "$input"
                ;;
            missing_lf)
                printf x >> "$input"
                ;;
        esac
        set +e
        run_fake_exact "$input" output > "$output" 2> "$TEST_ROOT/${mode}.err"
        status=$?
        set -e
        assert_rejected_without_stdout 65 "$output" "$status" "$mode byte stream"
    done
}

test_exact_scriptlet_mutations_and_duplicates_fail_closed() {
    local mode mutated output status raw="$TEST_ROOT/exact-raw.spec"

    generate_raw_exact "$raw"
    for mode in body duplicate; do
        mutated="$TEST_ROOT/${mode}.spec"
        output="$TEST_ROOT/${mode}.out"
        case "$mode" in
            body)
                awk '
                    !injected && /^%\{_kmodtool_depmod_post\}$/ {
                        print
                        print "/usr/bin/touch /tmp/should-never-run"
                        injected=1
                        next
                    }
                    { print }
                ' "$raw" > "$mutated"
                ;;
            duplicate)
                awk '
                    !duplicated && /^Requires\(post\):/ {
                        print
                        print
                        duplicated=1
                        next
                    }
                    { print }
                ' "$raw" > "$mutated"
                ;;
        esac
        set +e
        run_fake_exact "$mutated" output > "$output" 2> "$TEST_ROOT/${mode}.err"
        status=$?
        set -e
        assert_rejected_without_stdout 65 "$output" "$status" "$mode mutation"
    done
}

test_unexpected_scriptlet_headers_fail_closed() {
    local header label mutated output status raw="$TEST_ROOT/headers-raw.spec"

    generate_raw_exact "$raw"
    for label in macro pre posttrans concrete trigger; do
        case "$label" in
            macro) header='%pre -n %{package_kmod_name}' ;;
            pre) header='%pre -n galaxybook-max98390-kmod-common' ;;
            posttrans) header='%posttrans -n %{kmod_pkg_name}-%{kmod_for_kernel}' ;;
            concrete) header="%posttrans -n kmod-$KMODNAME-7.1.6-201.fc44.x86_64" ;;
            trigger) header="%transfiletriggerin -n $KMODNAME" ;;
        esac
        mutated="$TEST_ROOT/header-${label}.spec"
        output="$TEST_ROOT/header-${label}.out"
        awk -v header="$header" '
            !injected && /^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
                print header
                print "/usr/bin/true"
                print ""
                injected=1
            }
            { print }
        ' "$raw" > "$mutated"
        set +e
        run_fake_exact "$mutated" output > "$output" 2> "$TEST_ROOT/header-${label}.err"
        status=$?
        set -e
        assert_rejected_without_stdout 65 "$output" "$status" "$label scriptlet"
    done
}

test_akmod_scriptlet_mutation_and_literal_header_fail_closed() {
    local mode mutated output status raw="$TEST_ROOT/akmod-raw.spec"

    generate_raw_akmod "$raw"
    for mode in post posttrans literal; do
        mutated="$TEST_ROOT/akmod-${mode}.spec"
        output="$TEST_ROOT/akmod-${mode}.out"
        case "$mode" in
            post|posttrans)
                awk -v header="%${mode}" -v package="akmod-$KMODNAME" '
                    !injected && index($0, header) == 1 && $0 ~ ("-n " package "$") {
                        print
                        if (getline <= 0) exit 2
                        print
                        print "/usr/bin/true"
                        injected=1
                        next
                    }
                    { print }
                ' "$raw" > "$mutated"
                ;;
            literal)
                awk -v package="akmod-$KMODNAME" '
                    !injected && $0 ~ ("^%files[[:space:]]+-n[[:space:]]+" package "$") {
                        print "%verifyscript -n " package
                        print "/usr/bin/true"
                        print ""
                        injected=1
                    }
                    { print }
                ' "$raw" > "$mutated"
                ;;
        esac
        set +e
        run_fake_akmod "$mutated" output > "$output" 2> "$TEST_ROOT/akmod-${mode}.err"
        status=$?
        set -e
        assert_rejected_without_stdout 65 "$output" "$status" "akmod $mode mutation"
    done
}

test_forged_marker_and_argument_mismatch_fail_closed() {
    local forged="$TEST_ROOT/forged.spec" raw="$TEST_ROOT/forged-raw.spec"
    local output="$TEST_ROOT/forged.out" status

    generate_raw_exact "$raw"
    {
        /usr/bin/cat -- "$raw"
        printf '%%global kmodtool_queue_only_filter_ok 1\n'
    } > "$forged"
    set +e
    run_fake_exact "$forged" output > "$output" 2> "$TEST_ROOT/forged.err"
    status=$?
    set -e
    assert_rejected_without_stdout 65 "$output" "$status" 'forged marker'

    set +e
    "$FILTER" --expected-kernels "$KERNELS" -- \
        /usr/bin/kmodtool \
        --target x86_64 \
        --repo fedora \
        --kmodname "$KMODNAME" \
        --akmod \
        --for-kernels '7.1.6-201.fc44.x86_64' \
        > "$TEST_ROOT/mismatch.out" 2> "$TEST_ROOT/mismatch.err"
    status=$?
    set -e
    assert_rejected_without_stdout 64 "$TEST_ROOT/mismatch.out" "$status" \
        'kernel argument mismatch'
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    real_per_kernel_output_becomes_strictly_queue_only \
    akmod_only_output_has_only_the_two_known_scriptlets \
    upstream_failure_preserves_status_and_emits_no_partial_output \
    status_zero_stderr_fails_closed \
    noncanonical_byte_streams_fail_closed \
    exact_scriptlet_mutations_and_duplicates_fail_closed \
    unexpected_scriptlet_headers_fail_closed \
    akmod_scriptlet_mutation_and_literal_header_fail_closed \
    forged_marker_and_argument_mismatch_fail_closed
