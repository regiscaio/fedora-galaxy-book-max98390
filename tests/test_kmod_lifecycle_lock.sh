#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/kmod-lifecycle-lock.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-lifecycle-lock-tests.XXXXXX")"

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"
# shellcheck source=../scripts/kmod-lifecycle-lock.sh
source "$HELPER"

close_lifecycle_lock() {
    local held_fd="${GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD:-}"

    if [[ "$held_fd" =~ ^[0-9]+$ ]]; then
        exec {held_fd}>&-
    fi
    unset GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD
}

cleanup() {
    close_lifecycle_lock
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-lifecycle-lock-tests.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/run/lock"
chmod 0755 "$TEST_ROOT/run" "$TEST_ROOT/run/lock"
kmod_lifecycle_lock_path="$TEST_ROOT/run/lock/galaxybook-kmod-lifecycle.lock"
kmod_lifecycle_lock_timeout_seconds=1
kmod_lifecycle_lock_expected_uid="$(id -u)"
kmod_lifecycle_lock_expected_gid="$(id -g)"
kmod_lifecycle_lock_ancestry=("$TEST_ROOT/run" "$TEST_ROOT/run/lock")

wait_for_file() {
    local path="$1"
    local attempt

    for ((attempt = 1; attempt <= 200; attempt++)); do
        [[ -f "$path" ]] && return 0
        /usr/bin/sleep 0.01
    done
    fail "timed out waiting for fixture signal: $path"
}

test_creates_authenticated_lock_and_excludes_other_processes() {
    acquire_kmod_lifecycle_lock

    [[ "$(stat -Lc '%u:%g:%a:%h' -- "$kmod_lifecycle_lock_path")" == \
        "${kmod_lifecycle_lock_expected_uid}:${kmod_lifecycle_lock_expected_gid}:600:1" ]]
    validate_kmod_lifecycle_lock
    if /usr/bin/flock --exclusive --nonblock "$kmod_lifecycle_lock_path" true; then
        fail 'another process acquired the global lock while this process held it'
    fi
}

test_external_holder_forces_bounded_failure() {
    local holder_pid
    local ready="$TEST_ROOT/holder.ready"
    local release="$TEST_ROOT/holder.release"

    : > "$kmod_lifecycle_lock_path"
    chmod 0600 "$kmod_lifecycle_lock_path"
    (
        local holder_fd
        exec {holder_fd}<>"$kmod_lifecycle_lock_path"
        /usr/bin/flock --exclusive "$holder_fd"
        : > "$ready"
        while [[ ! -f "$release" ]]; do
            /usr/bin/sleep 0.01
        done
    ) &
    holder_pid=$!
    wait_for_file "$ready"

    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        : > "$release"
        wait "$holder_pid"
        fail 'global lock contention was accepted'
    fi
    [[ -z "${GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD:-}" ]]

    : > "$release"
    wait "$holder_pid"
}

test_rejects_unsafe_file_metadata_and_symlinks() {
    local target="$TEST_ROOT/target.lock"

    : > "$kmod_lifecycle_lock_path"
    chmod 0666 "$kmod_lifecycle_lock_path"
    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'group/world-writable global lock was accepted'
    fi

    rm -f -- "$kmod_lifecycle_lock_path"
    : > "$target"
    chmod 0600 "$target"
    ln -s "$target" "$kmod_lifecycle_lock_path"
    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'symlink global lock was accepted'
    fi

    rm -f -- "$kmod_lifecycle_lock_path"
    ln "$target" "$kmod_lifecycle_lock_path"
    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'hard-linked global lock was accepted'
    fi
}

test_reuses_and_revalidates_inherited_descriptor() {
    local inherited_fd

    acquire_kmod_lifecycle_lock
    inherited_fd="$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD"
    (
        [[ "$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD" == "$inherited_fd" ]]
        acquire_kmod_lifecycle_lock
        [[ "$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD" == "$inherited_fd" ]]
        validate_kmod_lifecycle_lock
    )
    if /usr/bin/flock --exclusive --nonblock "$kmod_lifecycle_lock_path" true; then
        fail 'inherited reuse released the parent lifecycle lock'
    fi
}

test_exec_child_reuses_exported_descriptor() {
    local inherited_fd

    acquire_kmod_lifecycle_lock
    inherited_fd="$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD"
    /usr/bin/bash -euo pipefail -c '
        helper="$1"
        fixture_root="$2"
        expected_uid="$3"
        expected_gid="$4"
        expected_fd="$5"
        source "$helper"
        kmod_lifecycle_lock_path="$fixture_root/run/lock/galaxybook-kmod-lifecycle.lock"
        kmod_lifecycle_lock_timeout_seconds=1
        kmod_lifecycle_lock_expected_uid="$expected_uid"
        kmod_lifecycle_lock_expected_gid="$expected_gid"
        kmod_lifecycle_lock_ancestry=("$fixture_root/run" "$fixture_root/run/lock")
        [[ "$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD" == "$expected_fd" ]]
        acquire_kmod_lifecycle_lock
        [[ "$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD" == "$expected_fd" ]]
        validate_kmod_lifecycle_lock
    ' child "$HELPER" "$TEST_ROOT" \
        "$kmod_lifecycle_lock_expected_uid" \
        "$kmod_lifecycle_lock_expected_gid" "$inherited_fd"

    if /usr/bin/flock --exclusive --nonblock "$kmod_lifecycle_lock_path" true; then
        fail 'exec child reuse released the parent lifecycle lock'
    fi
}

test_rejects_inherited_descriptor_after_path_replacement() {
    local displaced="$TEST_ROOT/displaced.lock"

    acquire_kmod_lifecycle_lock
    mv -T -- "$kmod_lifecycle_lock_path" "$displaced"
    : > "$kmod_lifecycle_lock_path"
    chmod 0600 "$kmod_lifecycle_lock_path"

    if validate_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'an inherited descriptor for a replaced path was accepted'
    fi
    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'acquisition reused an inherited descriptor for the wrong inode'
    fi
}

test_rejects_unsafe_or_symlink_ancestry_without_creating_lock() {
    local real_parent="$TEST_ROOT/real-parent"
    local linked_parent="$TEST_ROOT/linked-parent"

    chmod 0777 "$TEST_ROOT/run/lock"
    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'world-writable lock ancestry was accepted'
    fi
    assert_path_missing "$kmod_lifecycle_lock_path" \
        'unsafe ancestry caused a lock-file side effect'

    chmod 0755 "$TEST_ROOT/run/lock"
    mkdir -p "$real_parent"
    chmod 0755 "$real_parent"
    ln -s "$real_parent" "$linked_parent"
    kmod_lifecycle_lock_path="$linked_parent/galaxybook-kmod-lifecycle.lock"
    kmod_lifecycle_lock_ancestry=("$linked_parent")
    if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
        fail 'symlink lock ancestry was accepted'
    fi
    assert_path_missing "$real_parent/galaxybook-kmod-lifecycle.lock" \
        'symlink ancestry caused a lock-file side effect'
}

test_readonly_empty_descriptor_fails_without_leaking_lock() {
    local child_pid attempt
    local ready="$TEST_ROOT/readonly.ready"
    local checked="$TEST_ROOT/readonly.checked"
    local release="$TEST_ROOT/readonly.release"

    rm -f -- "$kmod_lifecycle_lock_path" "$ready" "$checked" "$release"
    (
        readonly GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD=""
        if acquire_kmod_lifecycle_lock >/dev/null 2>&1; then
            exit 91
        fi
        : > "$ready"
        while [[ ! -f "$checked" ]]; do
            /usr/bin/sleep 0.01
        done
        : > "$release"
    ) &
    child_pid=$!
    wait_for_file "$ready"

    /usr/bin/flock --exclusive --nonblock "$kmod_lifecycle_lock_path" true
    : > "$checked"
    wait_for_file "$release"
    wait "$child_pid"
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    creates_authenticated_lock_and_excludes_other_processes \
    external_holder_forces_bounded_failure \
    rejects_unsafe_file_metadata_and_symlinks \
    reuses_and_revalidates_inherited_descriptor \
    exec_child_reuses_exported_descriptor \
    rejects_inherited_descriptor_after_path_replacement \
    rejects_unsafe_or_symlink_ancestry_without_creating_lock \
    readonly_empty_descriptor_fails_without_leaking_lock
