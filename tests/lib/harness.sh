#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'failure: %s\n' "$*" >&2
    exit 1
}

skip() {
    printf '%s\n' "$*" >&2
    exit 77
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local context="${3:-values differ}"

    if [[ "$actual" != "$expected" ]]; then
        fail "$context (expected '$expected', got '$actual')"
    fi
}

assert_file_exists() {
    local path="$1"
    local context="${2:-expected file to exist}"

    [[ -e "$path" ]] || fail "$context: $path"
}

assert_path_missing() {
    local path="$1"
    local context="${2:-expected path to be absent}"

    [[ ! -e "$path" && ! -L "$path" ]] || fail "$context: $path"
}

assert_file_contains_fixed() {
    local path="$1"
    local needle="$2"
    local context="${3:-expected file content was not found}"

    grep -Fq -- "$needle" "$path" || fail "$context: '$needle' in $path"
}

assert_file_not_contains_fixed() {
    local path="$1"
    local needle="$2"
    local context="${3:-unexpected file content was found}"

    if grep -Fq -- "$needle" "$path"; then
        fail "$context: '$needle' in $path"
    fi
}

assert_prefix_count() {
    local path="$1"
    local prefix="$2"
    local expected="$3"
    local context="${4:-unexpected matching line count}"
    local actual

    actual="$({
        awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' "$path"
    })"
    assert_eq "$expected" "$actual" "$context"
}

assert_prefix_min_count() {
    local path="$1"
    local prefix="$2"
    local minimum="$3"
    local context="${4:-too few matching lines}"
    local actual

    actual="$({
        awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' "$path"
    })"
    if (( actual < minimum )); then
        fail "$context (expected at least $minimum, got $actual for '$prefix' in $path)"
    fi
}

run_test_cases() {
    local test_script="$1"
    local mode="$2"
    local selected="$3"
    shift 3

    if [[ "$mode" == "--case" ]]; then
        [[ -n "$selected" ]] || fail 'missing test case name'
        "test_${selected}"
        return
    fi

    local case_name case_output status failures=0 total=0
    for case_name in "$@"; do
        total=$((total + 1))
        set +e
        case_output="$("$test_script" --case "$case_name" 2>&1)"
        status=$?
        set -e

        case "$status" in
            0)
                printf 'ok %d - %s\n' "$total" "$case_name"
                ;;
            77)
                printf 'ok %d - %s # SKIP %s\n' "$total" "$case_name" "$case_output"
                ;;
            *)
                failures=$((failures + 1))
                printf 'not ok %d - %s\n' "$total" "$case_name"
                while IFS= read -r output_line; do
                    printf '# %s\n' "$output_line"
                done <<< "$case_output"
                ;;
        esac
    done

    printf '1..%d\n' "$total"
    (( failures == 0 )) || exit 1
}
