#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
FINALIZER="$REPO_ROOT/scripts/max98390-kmod-finalize.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-finalize-tests.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-finalize-tests.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
}
trap cleanup EXIT

export MAX98390_MODULE_ROOT="$TEST_ROOT/modules"
export MAX98390_FINALIZE_STATE_ROOT="$TEST_ROOT/state"
export MAX98390_FINALIZE_LOCK_ROOT="$TEST_ROOT/locks/private"
export MAX98390_STATE_UID="$(id -u)"
export MAX98390_STATE_GID="$(id -g)"
export MAX98390_ALLOW_NON_ROOT=1
export MAX98390_RPM_QUERY_ATTEMPTS=5
export MAX98390_RPM_QUERY_DELAY_SECONDS=0
export MAX98390_RPM_LOCK_PATH="$TEST_ROOT/rpm.lock"
export MAX98390_RPM_LOCK_TIMEOUT_SECONDS=5

# shellcheck source=../scripts/max98390-kmod-finalize.sh
source "$FINALIZER"

mkdir -p "$TEST_ROOT/locks"
: > "$MAX98390_RPM_LOCK_PATH"

# The production path is deliberately fixed. Unit tests source the canonical
# helper and replace its internal fixture values without exposing a runtime
# environment override.
kmod_lifecycle_lock_path="$TEST_ROOT/locks/global.lock"
kmod_lifecycle_lock_timeout_seconds=5
kmod_lifecycle_lock_expected_uid="$(id -u)"
kmod_lifecycle_lock_expected_gid="$(id -g)"
kmod_lifecycle_lock_ancestry=("$TEST_ROOT" "$TEST_ROOT/locks")

FAKE_PAYLOAD_OWNER=""
FAKE_LEGACY_OWNER=""
FAKE_WRONG_VERMAGIC=0
FAKE_TRANSIENT_REMAINING_FILE="$TEST_ROOT/transient-remaining"
FAKE_BLOCK_REQUEST="$TEST_ROOT/block-request"
FAKE_BLOCK_ENTERED="$TEST_ROOT/block-entered"
FAKE_BLOCK_RELEASE="$TEST_ROOT/block-release"
FAKE_RPM_CALLS="$TEST_ROOT/rpm-calls"
FAKE_MODINFO_CALLS="$TEST_ROOT/modinfo-calls"
FAKE_DEPMOD_CALLS="$TEST_ROOT/depmod-calls"
FAKE_LIFECYCLE_EVENTS="$TEST_ROOT/lifecycle-events"
FAKE_SLEEP_CALLS="$TEST_ROOT/sleep-calls"
FAKE_SYSTEMCTL_CALLS="$TEST_ROOT/systemctl-calls"
FAKE_RUNNING_KERNEL="test-running.x86_64"
FAKE_LEGACY_SWAP_SOURCE=""
FAKE_LEGACY_SWAP_TRIGGER=""
FAKE_LEGACY_SWAP_REPLACEMENT=""
FAKE_ASSERT_GLOBAL_HELD=0

fake_rpm() {
    local path="${*: -1}"
    local remaining=0

    printf '%s\n' "$path" >> "$FAKE_RPM_CALLS"
    printf '%s\n' rpm-query >> "$FAKE_LIFECYCLE_EVENTS"
    if [[ -n "$FAKE_LEGACY_SWAP_TRIGGER" \
        && "$path" == "$FAKE_LEGACY_SWAP_TRIGGER" ]]; then
        mv -fT -- "$FAKE_LEGACY_SWAP_REPLACEMENT" "$FAKE_LEGACY_SWAP_SOURCE"
    fi
    if [[ -f "$FAKE_BLOCK_REQUEST" && ! -f "$FAKE_BLOCK_RELEASE" ]]; then
        : > "$FAKE_BLOCK_ENTERED"
        while [[ ! -f "$FAKE_BLOCK_RELEASE" ]]; do
            /usr/bin/sleep 0.01
        done
    fi

    if [[ -f "$FAKE_TRANSIENT_REMAINING_FILE" ]]; then
        remaining="$(< "$FAKE_TRANSIENT_REMAINING_FILE")"
        if (( remaining > 0 )); then
            printf '%s\n' "$((remaining - 1))" > "$FAKE_TRANSIENT_REMAINING_FILE"
            printf '%s\n' "error: can't create transaction lock (Resource temporarily unavailable)" >&2
            printf '%s\n' "$FAKE_PAYLOAD_OWNER"
            return 0
        fi
    fi

    case "$path" in
        */extra/galaxybook-max98390/*)
            printf '%s\n' "$FAKE_PAYLOAD_OWNER"
            ;;
        */updates/*)
            if [[ -n "$FAKE_LEGACY_OWNER" ]]; then
                printf '%s\n' "$FAKE_LEGACY_OWNER"
            else
                printf 'file %s is not owned by any package\n' "$path" >&2
                return 1
            fi
            ;;
        *)
            return 2
            ;;
    esac
}

fake_modinfo() {
    local path module kernel

    printf '%s\n' modinfo >> "$FAKE_MODINFO_CALLS"
    printf '%s\n' modinfo >> "$FAKE_LIFECYCLE_EVENTS"

    if [[ "$1" == -F && "$2" == vermagic ]]; then
        path="${*: -1}"
        kernel="${path#"$MODULE_ROOT/"}"
        kernel="${kernel%%/*}"
        if (( FAKE_WRONG_VERMAGIC == 1 )); then
            printf '%s SMP preempt mod_unload\n' wrong-kernel.x86_64
        else
            printf '%s SMP preempt mod_unload\n' "$kernel"
        fi
        return
    fi

    if [[ "$1" == -k && "$3" == -n ]]; then
        kernel="$2"
        module="$4"
        printf '%s/%s/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/%s.ko.zst\n' \
            "$MODULE_ROOT" "$kernel" "$module"
        return
    fi
    return 2
}

fake_depmod() {
    printf '%s\n' "$*" >> "$FAKE_DEPMOD_CALLS"
    printf '%s\n' depmod >> "$FAKE_LIFECYCLE_EVENTS"
    if (( FAKE_ASSERT_GLOBAL_HELD == 1 )) \
        && /usr/bin/flock --exclusive --nonblock \
            "$kmod_lifecycle_lock_path" true; then
        printf 'depmod entered without the global lifecycle lock\n' >&2
        return 91
    fi
}

fake_flock() {
    if [[ " $* " == *' --fcntl --shared '* ]]; then
        printf '%s\n' rpm-lock >> "$FAKE_LIFECYCLE_EVENTS"
    elif [[ "$1" == -x ]]; then
        printf '%s\n' private-lock >> "$FAKE_LIFECYCLE_EVENTS"
    fi
    /usr/bin/flock "$@"
}

fake_global_flock() {
    printf 'global-lock %s\n' "$*" >> "$FAKE_LIFECYCLE_EVENTS"
    /usr/bin/flock "$@"
}

fake_sleep() {
    printf '%s\n' "$*" >> "$FAKE_SLEEP_CALLS"
}

fake_systemctl() {
    printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_CALLS"
}

fake_uname() {
    [[ "$1" == -r ]]
    printf '%s\n' "$FAKE_RUNNING_KERNEL"
}

RPM_COMMAND=fake_rpm
MODINFO_COMMAND=fake_modinfo
DEPMOD_COMMAND=fake_depmod
FLOCK_COMMAND=fake_flock
SLEEP_COMMAND=fake_sleep
SYSTEMCTL_COMMAND=fake_systemctl
UNAME_COMMAND=fake_uname
kmod_lifecycle_lock_flock_command=fake_global_flock

new_kernel_fixture() {
    local kernel="$1"
    local expected_dir

    expected_dir="${MODULE_ROOT}/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs"
    mkdir -p "$expected_dir"
    : > "${expected_dir}/${CORE_MODULE}.ko.zst"
    : > "${expected_dir}/${I2C_MODULE}.ko.zst"
    FAKE_PAYLOAD_OWNER="kmod-galaxybook-max98390-${kernel}"
    FAKE_LEGACY_OWNER=""
    FAKE_WRONG_VERMAGIC=0
}

legacy_path() {
    local kernel="$1"
    local module="$2"
    local path="${MODULE_ROOT}/${kernel}/updates/sound/hda/codecs/side-codecs/${module}.ko"

    mkdir -p "${path%/*}"
    : > "$path"
    printf '%s\n' "$path"
}

assert_missing() {
    [[ ! -e "$1" && ! -L "$1" ]] || {
        printf 'expected path to be absent: %s\n' "$1" >&2
        return 1
    }
}

alternate_group_id() {
    local candidate

    while IFS= read -r candidate; do
        if [[ "$candidate" != "$EXPECTED_STATE_GID" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(id -G | tr ' ' '\n')
    if [[ "$EUID" -eq 0 ]]; then
        printf '%s\n' 1
        return 0
    fi
    printf '%s\n' "$EXPECTED_STATE_GID"
}

test_finalizer_validates_then_removes_unmanaged_legacy() {
    local kernel=7.1.8-success.x86_64 legacy

    new_kernel_fixture "$kernel"
    legacy="$(legacy_path "$kernel" "$CORE_MODULE")"
    queue_kernel "$kernel" >/dev/null
    finalize_kernel "$kernel" >/dev/null

    assert_missing "$legacy"
    assert_missing "${PENDING_DIR}/${kernel}.pending"
    grep -Fxq -- "-a $kernel" "$FAKE_DEPMOD_CALLS"
}

test_owner_or_vermagic_failure_preserves_legacy() {
    local owner_kernel=7.1.8-owner-fail.x86_64 owner_legacy
    local vermagic_kernel=7.1.8-vermagic-fail.x86_64 vermagic_legacy

    new_kernel_fixture "$owner_kernel"
    owner_legacy="$(legacy_path "$owner_kernel" "$CORE_MODULE")"
    queue_kernel "$owner_kernel" >/dev/null
    FAKE_PAYLOAD_OWNER=unrelated-kmod
    if finalize_kernel "$owner_kernel" >/dev/null 2>&1; then
        printf 'wrong owner was accepted\n' >&2
        return 1
    fi
    [[ -f "$owner_legacy" ]]
    [[ -f "${PENDING_DIR}/${owner_kernel}.pending" ]]
    rm -f -- "${PENDING_DIR}/${owner_kernel}.pending"

    new_kernel_fixture "$vermagic_kernel"
    vermagic_legacy="$(legacy_path "$vermagic_kernel" "$CORE_MODULE")"
    queue_kernel "$vermagic_kernel" >/dev/null
    FAKE_WRONG_VERMAGIC=1
    if finalize_kernel "$vermagic_kernel" >/dev/null 2>&1; then
        printf 'wrong vermagic was accepted\n' >&2
        return 1
    fi
    [[ -f "$vermagic_legacy" ]]
    [[ -f "${PENDING_DIR}/${vermagic_kernel}.pending" ]]
    rm -f -- "${PENDING_DIR}/${vermagic_kernel}.pending"
}

test_rpm_owned_legacy_is_preserved() {
    local kernel=7.1.8-owned-legacy.x86_64 legacy

    new_kernel_fixture "$kernel"
    legacy="$(legacy_path "$kernel" "$CORE_MODULE")"
    FAKE_LEGACY_OWNER=vendor-kmod
    finalize_kernel "$kernel" >/dev/null
    [[ -f "$legacy" ]]
}

test_legacy_cleanup_rejects_symlink_and_hardlink() {
    local symlink_kernel=7.1.8-legacy-symlink.x86_64
    local hardlink_kernel=7.1.8-legacy-hardlink.x86_64
    local symlink_path hardlink_path alias target

    new_kernel_fixture "$symlink_kernel"
    symlink_path="$(legacy_path "$symlink_kernel" "$CORE_MODULE")"
    target="$TEST_ROOT/legacy-target"
    : > "$target"
    rm -f -- "$symlink_path"
    ln -s "$target" "$symlink_path"
    if finalize_kernel "$symlink_kernel" >/dev/null 2>&1; then
        printf 'symlink legacy override was accepted for cleanup\n' >&2
        return 1
    fi
    [[ -L "$symlink_path" && -f "$target" ]]

    new_kernel_fixture "$hardlink_kernel"
    hardlink_path="$(legacy_path "$hardlink_kernel" "$CORE_MODULE")"
    alias="${hardlink_path}.alias"
    ln "$hardlink_path" "$alias"
    if finalize_kernel "$hardlink_kernel" >/dev/null 2>&1; then
        printf 'hard-linked legacy override was accepted for cleanup\n' >&2
        return 1
    fi
    [[ -f "$hardlink_path" && -f "$alias" ]]
}

test_legacy_cleanup_rejects_identity_swap_before_unlink() {
    local kernel=7.1.8-legacy-swap.x86_64
    local source trigger replacement

    new_kernel_fixture "$kernel"
    source="$(legacy_path "$kernel" "$CORE_MODULE")"
    trigger="$(legacy_path "$kernel" "$I2C_MODULE")"
    replacement="$TEST_ROOT/legacy-replacement"
    printf '%s\n' replacement-must-survive > "$replacement"
    chmod 0644 "$replacement"
    FAKE_LEGACY_SWAP_SOURCE="$source"
    FAKE_LEGACY_SWAP_TRIGGER="$trigger"
    FAKE_LEGACY_SWAP_REPLACEMENT="$replacement"

    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'legacy identity swap before unlink was accepted\n' >&2
        return 1
    fi
    [[ "$(< "$source")" == replacement-must-survive ]]
    [[ -f "$trigger" ]]

    FAKE_LEGACY_SWAP_SOURCE=""
    FAKE_LEGACY_SWAP_TRIGGER=""
    FAKE_LEGACY_SWAP_REPLACEMENT=""
}

test_trigger_only_queues_exact_paths_without_rpm_query() {
    local kernel=7.1.8-trigger.x86_64 nested=7.1.8-nested.x86_64
    local calls_before calls_after

    : > "$FAKE_SYSTEMCTL_CALLS"
    calls_before="$(wc -l < "$FAKE_RPM_CALLS" 2>/dev/null || printf '0\n')"
    queue_from_rpm_trigger <<EOF >/dev/null
/lib/modules/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/${CORE_MODULE}.ko.zst
/usr/lib/modules/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/${I2C_MODULE}.ko.xz
/lib/modules/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/${CORE_MODULE}.ko.backup
/lib/modules/${nested}/unexpected/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/${CORE_MODULE}.ko
EOF
    calls_after="$(wc -l < "$FAKE_RPM_CALLS" 2>/dev/null || printf '0\n')"

    [[ "$calls_after" == "$calls_before" ]]
    [[ -f "${PENDING_DIR}/${kernel}.pending" ]]
    assert_missing "${PENDING_DIR}/${nested}.pending"
    grep -Fxq -- "start --no-block $FINALIZER_PATH_UNIT $FINALIZER_UNIT" "$FAKE_SYSTEMCTL_CALLS"
    rm -f -- "${PENDING_DIR}/${kernel}.pending"
}

test_pending_marker_rejects_hardlinks() {
    local kernel=7.1.8-marker-hardlink.x86_64 marker alias

    queue_kernel "$kernel" >/dev/null
    marker="${PENDING_DIR}/${kernel}.pending"
    alias="${PENDING_DIR}/${kernel}.alias"
    ln "$marker" "$alias"
    if validate_pending_marker "$kernel" "$marker" >/dev/null 2>&1; then
        printf 'hard-linked pending marker was accepted\n' >&2
        return 1
    fi
    rm -f -- "$alias" "$marker"
}

test_lock_warning_is_retried_and_never_emitted() {
    local kernel=7.1.8-lock-retry.x86_64 output

    new_kernel_fixture "$kernel"
    printf '%s\n' 2 > "$FAKE_TRANSIENT_REMAINING_FILE"
    : > "$FAKE_SLEEP_CALLS"
    output="$(finalize_kernel "$kernel" 2>&1)"
    [[ "$output" != *'transaction lock'* ]]
    [[ "$(wc -l < "$FAKE_SLEEP_CALLS")" == 2 ]]
}

test_enqueue_during_worker_remains_pending_then_converges() {
    local kernel=7.1.8-race.x86_64 attempt

    new_kernel_fixture "$kernel"
    queue_kernel "$kernel" >/dev/null
    : > "$FAKE_BLOCK_REQUEST"
    rm -f -- "$FAKE_BLOCK_ENTERED" "$FAKE_BLOCK_RELEASE"

    finalize_kernel "$kernel" > "$TEST_ROOT/race-worker.out" 2>&1 &
    local worker_pid=$!
    for ((attempt = 1; attempt <= 200; attempt++)); do
        [[ -f "$FAKE_BLOCK_ENTERED" ]] && break
        /usr/bin/sleep 0.01
    done
    [[ -f "$FAKE_BLOCK_ENTERED" ]] || {
        printf 'worker did not reach the controlled RPM query\n' >&2
        return 1
    }
    if /usr/bin/flock --fcntl --exclusive --nonblock "$RPM_LOCK_PATH" true; then
        printf 'writer lock was acquired while finalization held the RPM read lock\n' >&2
        return 1
    fi

    queue_kernel "$kernel" >/dev/null
    : > "$FAKE_BLOCK_RELEASE"
    wait "$worker_pid"
    [[ -f "${PENDING_DIR}/${kernel}.pending" ]]
    grep -Fq 'newer finalization request remains queued' "$TEST_ROOT/race-worker.out"

    rm -f -- "$FAKE_BLOCK_REQUEST"
    finalize_kernel "$kernel" >/dev/null
    assert_missing "${PENDING_DIR}/${kernel}.pending"
}

test_finalizer_waits_for_active_rpm_writer() {
    local kernel=7.1.8-rpm-writer.x86_64 attempt calls_before calls_during
    local holder_pid worker_pid

    new_kernel_fixture "$kernel"
    rm -f -- "$TEST_ROOT/writer-acquired" "$TEST_ROOT/writer-release"
    (
        local holder_fd
        exec {holder_fd}<>"$RPM_LOCK_PATH"
        /usr/bin/flock --fcntl --exclusive "$holder_fd"
        : > "$TEST_ROOT/writer-acquired"
        while [[ ! -f "$TEST_ROOT/writer-release" ]]; do
            /usr/bin/sleep 0.01
        done
    ) &
    holder_pid=$!
    for ((attempt = 1; attempt <= 200; attempt++)); do
        [[ -f "$TEST_ROOT/writer-acquired" ]] && break
        /usr/bin/sleep 0.01
    done
    [[ -f "$TEST_ROOT/writer-acquired" ]]

    calls_before="$(wc -l < "$FAKE_RPM_CALLS")"
    finalize_kernel "$kernel" > "$TEST_ROOT/writer-worker.out" 2>&1 &
    worker_pid=$!
    /usr/bin/sleep 0.05
    calls_during="$(wc -l < "$FAKE_RPM_CALLS")"
    [[ "$calls_during" == "$calls_before" ]]
    kill -0 "$worker_pid"

    : > "$TEST_ROOT/writer-release"
    wait "$holder_pid"
    wait "$worker_pid"
}

test_nonrunning_failure_defers_once_and_running_boot_retries() {
    local kernel=7.1.8-deferred.x86_64

    new_kernel_fixture "$kernel"
    queue_kernel "$kernel" >/dev/null
    FAKE_PAYLOAD_OWNER=unrelated-kmod
    FAKE_RUNNING_KERNEL=test-running.x86_64
    process_pending >/dev/null 2>&1
    assert_missing "${PENDING_DIR}/${kernel}.pending"
    [[ -f "${DEFERRED_DIR}/${kernel}.pending" ]]

    FAKE_PAYLOAD_OWNER="kmod-galaxybook-max98390-${kernel}"
    FAKE_RUNNING_KERNEL="$kernel"
    process_pending >/dev/null
    assert_missing "${PENDING_DIR}/${kernel}.pending"
    assert_missing "${DEFERRED_DIR}/${kernel}.pending"
}

test_running_failure_stays_pending_without_directory_churn() {
    local kernel=7.1.8-running-fail.x86_64 identity_before identity_after

    new_kernel_fixture "$kernel"
    queue_kernel "$kernel" >/dev/null
    identity_before="$(marker_identity "${PENDING_DIR}/${kernel}.pending")"
    FAKE_PAYLOAD_OWNER=unrelated-kmod
    FAKE_RUNNING_KERNEL="$kernel"
    if process_pending >/dev/null 2>&1; then
        printf 'running-kernel finalization failure was accepted\n' >&2
        return 1
    fi
    identity_after="$(marker_identity "${PENDING_DIR}/${kernel}.pending")"
    [[ "$identity_after" == "$identity_before" ]]
    assert_missing "${DEFERRED_DIR}/${kernel}.pending"
}

test_state_and_private_lock_creation_override_sgid_group() {
    local original_state_root="$STATE_ROOT"
    local original_pending_dir="$PENDING_DIR"
    local original_deferred_dir="$DEFERRED_DIR"
    local original_lock_root="$LOCK_ROOT"
    local parent="$TEST_ROOT/sgid-parent"
    local inherited_gid

    inherited_gid="$(alternate_group_id)"
    mkdir -p "$parent"
    chgrp "$inherited_gid" "$parent"
    chmod 2755 "$parent"

    STATE_ROOT="$parent/state"
    PENDING_DIR="$STATE_ROOT/pending"
    DEFERRED_DIR="$STATE_ROOT/deferred"
    LOCK_ROOT="$parent/private-lock"
    ensure_state_directories
    ensure_private_lock_directory

    [[ "$(stat -Lc '%u:%g:%a' -- "$STATE_ROOT")" == \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:755" ]]
    [[ "$(stat -Lc '%u:%g:%a' -- "$PENDING_DIR")" == \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:755" ]]
    [[ "$(stat -Lc '%u:%g:%a' -- "$DEFERRED_DIR")" == \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:755" ]]
    [[ "$(stat -Lc '%u:%g:%a' -- "$LOCK_ROOT")" == \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:700" ]]

    STATE_ROOT="$original_state_root"
    PENDING_DIR="$original_pending_dir"
    DEFERRED_DIR="$original_deferred_dir"
    LOCK_ROOT="$original_lock_root"
}

test_state_and_private_lock_reject_writable_ancestry() {
    local original_state_root="$STATE_ROOT"
    local original_pending_dir="$PENDING_DIR"
    local original_deferred_dir="$DEFERRED_DIR"
    local original_lock_root="$LOCK_ROOT"
    local unsafe_parent="$TEST_ROOT/writable-parent"

    mkdir -p "$unsafe_parent"
    chmod 0777 "$unsafe_parent"
    STATE_ROOT="$unsafe_parent/state"
    PENDING_DIR="$STATE_ROOT/pending"
    DEFERRED_DIR="$STATE_ROOT/deferred"
    LOCK_ROOT="$unsafe_parent/private-lock"

    if ensure_state_directories >/dev/null 2>&1; then
        printf 'state directory accepted writable ancestry\n' >&2
        return 1
    fi
    if ensure_private_lock_directory >/dev/null 2>&1; then
        printf 'private lock accepted writable ancestry\n' >&2
        return 1
    fi
    assert_missing "$STATE_ROOT"
    assert_missing "$LOCK_ROOT"

    STATE_ROOT="$original_state_root"
    PENDING_DIR="$original_pending_dir"
    DEFERRED_DIR="$original_deferred_dir"
    LOCK_ROOT="$original_lock_root"
}

test_public_kernel_rejects_unsafe_state_without_side_effects() {
    local kernel=7.1.8-public-state.x86_64
    local original_state_root="$STATE_ROOT"
    local original_pending_dir="$PENDING_DIR"
    local original_deferred_dir="$DEFERRED_DIR"
    local original_modinfo_command="$MODINFO_COMMAND"
    local unsafe_parent="$TEST_ROOT/public-writable-parent"
    local safe_state="$TEST_ROOT/public-safe-state"
    local linked_state="$TEST_ROOT/public-linked-state"
    local legacy rpm_before depmod_before
    local modinfo_calls="$TEST_ROOT/public-state-modinfo-calls"

    new_kernel_fixture "$kernel"
    legacy="$(legacy_path "$kernel" "$CORE_MODULE")"
    : > "$modinfo_calls"
    counting_modinfo() {
        printf '%s\n' "$*" >> "$modinfo_calls"
        fake_modinfo "$@"
    }
    MODINFO_COMMAND=counting_modinfo
    mkdir -p "$unsafe_parent" "$safe_state/pending" "$safe_state/deferred"
    chmod 0777 "$unsafe_parent"
    ln -s "$safe_state" "$linked_state"

    rpm_before="$(wc -l < "$FAKE_RPM_CALLS")"
    depmod_before="$(wc -l < "$FAKE_DEPMOD_CALLS")"
    STATE_ROOT="$linked_state"
    PENDING_DIR="$STATE_ROOT/pending"
    DEFERRED_DIR="$STATE_ROOT/deferred"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'public --kernel accepted a symlink state root\n' >&2
        return 1
    fi
    [[ "$(wc -l < "$FAKE_RPM_CALLS")" == "$rpm_before" ]]
    [[ "$(wc -l < "$FAKE_DEPMOD_CALLS")" == "$depmod_before" ]]
    [[ ! -s "$modinfo_calls" ]]
    [[ -f "$legacy" ]]

    STATE_ROOT="$unsafe_parent/state"
    PENDING_DIR="$STATE_ROOT/pending"
    DEFERRED_DIR="$STATE_ROOT/deferred"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'public --kernel accepted writable state ancestry\n' >&2
        return 1
    fi
    [[ "$(wc -l < "$FAKE_RPM_CALLS")" == "$rpm_before" ]]
    [[ "$(wc -l < "$FAKE_DEPMOD_CALLS")" == "$depmod_before" ]]
    [[ ! -s "$modinfo_calls" ]]
    [[ -f "$legacy" ]]

    STATE_ROOT="$safe_state"
    PENDING_DIR="$STATE_ROOT/pending"
    DEFERRED_DIR="$STATE_ROOT/deferred"
    chmod 0777 "$PENDING_DIR"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'public --kernel accepted writable pending directory\n' >&2
        return 1
    fi
    [[ "$(wc -l < "$FAKE_RPM_CALLS")" == "$rpm_before" ]]
    [[ "$(wc -l < "$FAKE_DEPMOD_CALLS")" == "$depmod_before" ]]
    [[ ! -s "$modinfo_calls" ]]
    [[ -f "$legacy" ]]

    chmod 0755 "$PENDING_DIR"
    chgrp "$(alternate_group_id)" "$DEFERRED_DIR"
    if [[ "$(stat -Lc %g "$DEFERRED_DIR")" != "$EXPECTED_STATE_GID" ]]; then
        if finalize_kernel "$kernel" >/dev/null 2>&1; then
            printf 'public --kernel accepted wrong-group deferred directory\n' >&2
            return 1
        fi
        [[ "$(wc -l < "$FAKE_RPM_CALLS")" == "$rpm_before" ]]
        [[ "$(wc -l < "$FAKE_DEPMOD_CALLS")" == "$depmod_before" ]]
        [[ ! -s "$modinfo_calls" ]]
        [[ -f "$legacy" ]]
    fi

    STATE_ROOT="$original_state_root"
    PENDING_DIR="$original_pending_dir"
    DEFERRED_DIR="$original_deferred_dir"
    MODINFO_COMMAND="$original_modinfo_command"
}

test_private_lock_rejects_symlink_and_wrong_owner_contract() {
    local kernel=7.1.8-lock-safety.x86_64 original_uid unsafe_root

    new_kernel_fixture "$kernel"
    unsafe_root="$TEST_ROOT/locks/unsafe"
    ln -s "$TEST_ROOT/locks" "$unsafe_root"
    LOCK_ROOT="$unsafe_root"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'symlink lock directory was accepted\n' >&2
        return 1
    fi
    assert_missing "$TEST_ROOT/locks/galaxybook-max98390-${kernel}.lock"

    LOCK_ROOT="$TEST_ROOT/locks/wrong-owner"
    original_uid="$EXPECTED_STATE_UID"
    EXPECTED_STATE_UID="$((original_uid + 1))"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'lock directory with unexpected ownership was accepted\n' >&2
        return 1
    fi
    EXPECTED_STATE_UID="$original_uid"
    LOCK_ROOT="$TEST_ROOT/locks/private"
}

test_private_lock_revalidates_group_mode_and_link_count_after_open() {
    local group_kernel=7.1.8-private-group.x86_64
    local hardlink_kernel=7.1.8-private-hardlink.x86_64
    local mutation_kernel=7.1.8-private-mutation.x86_64
    local original_lock_root="$LOCK_ROOT"
    local original_flock_command="$FLOCK_COMMAND"
    local group_root="$TEST_ROOT/locks/group-private"
    local hardlink_root="$TEST_ROOT/locks/hardlink-private"
    local mutation_root="$TEST_ROOT/locks/mutation-private"
    local group_file hardlink_file mutation_file backing_file alternate_gid

    alternate_gid="$(alternate_group_id)"
    if [[ "$alternate_gid" != "$EXPECTED_STATE_GID" ]]; then
        new_kernel_fixture "$group_kernel"
        LOCK_ROOT="$group_root"
        ensure_private_lock_directory
        group_file="$LOCK_ROOT/galaxybook-max98390-${group_kernel}.lock"
        : > "$group_file"
        chmod 0600 "$group_file"
        chgrp "$alternate_gid" "$group_file"
        if finalize_kernel "$group_kernel" >/dev/null 2>&1; then
            printf 'private lock with an unexpected group was accepted\n' >&2
            return 1
        fi
    fi

    new_kernel_fixture "$hardlink_kernel"
    LOCK_ROOT="$hardlink_root"
    ensure_private_lock_directory
    hardlink_file="$LOCK_ROOT/galaxybook-max98390-${hardlink_kernel}.lock"
    backing_file="$LOCK_ROOT/backing.lock"
    : > "$backing_file"
    chmod 0600 "$backing_file"
    ln "$backing_file" "$hardlink_file"
    if finalize_kernel "$hardlink_kernel" >/dev/null 2>&1; then
        printf 'hard-linked private lock was accepted\n' >&2
        return 1
    fi

    new_kernel_fixture "$mutation_kernel"
    LOCK_ROOT="$mutation_root"
    mutation_file="$LOCK_ROOT/galaxybook-max98390-${mutation_kernel}.lock"
    mutating_private_flock() {
        local status

        /usr/bin/flock "$@"
        status=$?
        if (( status == 0 )) && [[ "$1" == -x ]]; then
            chmod 0666 "$mutation_file"
        fi
        return "$status"
    }
    FLOCK_COMMAND=mutating_private_flock
    if finalize_kernel "$mutation_kernel" >/dev/null 2>&1; then
        printf 'private lock mode mutation after flock was accepted\n' >&2
        return 1
    fi

    FLOCK_COMMAND="$original_flock_command"
    LOCK_ROOT="$original_lock_root"
}

test_rpm_lock_rejects_symlink_and_wrong_owner_contract() {
    local kernel=7.1.8-rpm-lock-safety.x86_64 original_path original_uid
    local unsafe_parent

    new_kernel_fixture "$kernel"
    original_path="$RPM_LOCK_PATH"
    unsafe_parent="$TEST_ROOT/unsafe-rpmdb"
    mkdir -p "$TEST_ROOT/real-rpmdb"
    : > "$TEST_ROOT/real-rpmdb/.rpm.lock"
    ln -s "$TEST_ROOT/real-rpmdb" "$unsafe_parent"
    RPM_LOCK_PATH="$unsafe_parent/.rpm.lock"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'symlink RPM lock parent was accepted\n' >&2
        return 1
    fi

    RPM_LOCK_PATH="$original_path"
    original_uid="$EXPECTED_STATE_UID"
    EXPECTED_STATE_UID="$((original_uid + 1))"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'RPM lock with unexpected ownership was accepted\n' >&2
        return 1
    fi
    EXPECTED_STATE_UID="$original_uid"
}

test_rpm_lock_revalidates_group_mode_and_link_count() {
    local kernel=7.1.8-rpm-metadata.x86_64
    local original_flock_command="$FLOCK_COMMAND"
    local alternate_gid alias

    new_kernel_fixture "$kernel"
    alternate_gid="$(alternate_group_id)"
    if [[ "$alternate_gid" != "$EXPECTED_STATE_GID" ]]; then
        chgrp "$alternate_gid" "$RPM_LOCK_PATH"
        if finalize_kernel "$kernel" >/dev/null 2>&1; then
            printf 'RPM lock with an unexpected group was accepted\n' >&2
            return 1
        fi
        chgrp "$EXPECTED_STATE_GID" "$RPM_LOCK_PATH"
    fi

    alias="$TEST_ROOT/rpm.lock.alias"
    ln "$RPM_LOCK_PATH" "$alias"
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'hard-linked RPM lock was accepted\n' >&2
        return 1
    fi
    rm -f -- "$alias"

    mutating_rpm_flock() {
        local status

        /usr/bin/flock "$@"
        status=$?
        if (( status == 0 )) && [[ " $* " == *' --fcntl --shared '* \
            && " $* " != *' --nonblock '* ]]; then
            chmod 0666 "$RPM_LOCK_PATH"
        fi
        return "$status"
    }
    FLOCK_COMMAND=mutating_rpm_flock
    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        printf 'RPM lock mode mutation after OFD acquisition was accepted\n' >&2
        return 1
    fi
    chmod 0644 "$RPM_LOCK_PATH"
    FLOCK_COMMAND="$original_flock_command"
}

test_global_lock_precedes_private_and_rpm_and_covers_ack() {
    local kernel=7.1.8-global-order.x86_64
    local global_line private_line rpm_line depmod_line final_global_line

    new_kernel_fixture "$kernel"
    queue_kernel "$kernel" >/dev/null
    : > "$FAKE_LIFECYCLE_EVENTS"
    FAKE_ASSERT_GLOBAL_HELD=1
    finalize_kernel "$kernel" >/dev/null
    FAKE_ASSERT_GLOBAL_HELD=0

    global_line="$(grep -n -m1 '^global-lock ' "$FAKE_LIFECYCLE_EVENTS" | cut -d: -f1)"
    private_line="$(grep -n -m1 '^private-lock$' "$FAKE_LIFECYCLE_EVENTS" | cut -d: -f1)"
    rpm_line="$(grep -n -m1 '^rpm-lock$' "$FAKE_LIFECYCLE_EVENTS" | cut -d: -f1)"
    depmod_line="$(grep -n -m1 '^depmod$' "$FAKE_LIFECYCLE_EVENTS" | cut -d: -f1)"
    final_global_line="$(grep -n '^global-lock ' "$FAKE_LIFECYCLE_EVENTS" | tail -1 | cut -d: -f1)"

    [[ "$global_line" =~ ^[0-9]+$ && "$private_line" =~ ^[0-9]+$ \
        && "$rpm_line" =~ ^[0-9]+$ && "$depmod_line" =~ ^[0-9]+$ \
        && "$final_global_line" =~ ^[0-9]+$ ]]
    (( global_line < private_line && private_line < rpm_line ))
    (( rpm_line < depmod_line && depmod_line < final_global_line ))
    assert_missing "${PENDING_DIR}/${kernel}.pending"
}

test_global_lock_contention_has_zero_finalization_side_effects() {
    local kernel=7.1.8-global-contention.x86_64 legacy
    local holder_pid attempt unexpected_success=0
    local ready="$TEST_ROOT/global-holder.ready"
    local release="$TEST_ROOT/global-holder.release"

    new_kernel_fixture "$kernel"
    legacy="$(legacy_path "$kernel" "$CORE_MODULE")"
    queue_kernel "$kernel" >/dev/null
    : > "$FAKE_RPM_CALLS"
    : > "$FAKE_MODINFO_CALLS"
    : > "$FAKE_DEPMOD_CALLS"
    rm -f -- "$ready" "$release"
    kmod_lifecycle_lock_timeout_seconds=1
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
    for ((attempt = 1; attempt <= 200; attempt++)); do
        [[ -f "$ready" ]] && break
        /usr/bin/sleep 0.01
    done
    [[ -f "$ready" ]]

    if finalize_kernel "$kernel" >/dev/null 2>&1; then
        unexpected_success=1
    fi
    : > "$release"
    wait "$holder_pid"

    (( unexpected_success == 0 ))
    [[ ! -s "$FAKE_RPM_CALLS" && ! -s "$FAKE_MODINFO_CALLS" \
        && ! -s "$FAKE_DEPMOD_CALLS" ]]
    [[ -f "$legacy" && -f "${PENDING_DIR}/${kernel}.pending" ]]
    assert_missing "${LOCK_ROOT}/galaxybook-max98390-${kernel}.lock"
    rm -f -- "${PENDING_DIR}/${kernel}.pending"
}

test_unsafe_global_lock_has_zero_finalization_side_effects() {
    local mode kernel legacy safe_target

    for mode in metadata symlink; do
        kernel="7.1.8-global-${mode}.x86_64"
        new_kernel_fixture "$kernel"
        legacy="$(legacy_path "$kernel" "$CORE_MODULE")"
        queue_kernel "$kernel" >/dev/null
        : > "$FAKE_RPM_CALLS"
        : > "$FAKE_MODINFO_CALLS"
        : > "$FAKE_DEPMOD_CALLS"

        case "$mode" in
            metadata)
                chmod 0666 "$kmod_lifecycle_lock_path"
                ;;
            symlink)
                safe_target="$TEST_ROOT/global-safe-target"
                rm -f -- "$kmod_lifecycle_lock_path" "$safe_target"
                : > "$safe_target"
                chmod 0600 "$safe_target"
                ln -s "$safe_target" "$kmod_lifecycle_lock_path"
                ;;
        esac

        if finalize_kernel "$kernel" >/dev/null 2>&1; then
            printf 'unsafe global lock was accepted (%s)\n' "$mode" >&2
            return 1
        fi
        [[ ! -s "$FAKE_RPM_CALLS" && ! -s "$FAKE_MODINFO_CALLS" \
            && ! -s "$FAKE_DEPMOD_CALLS" ]]
        [[ -f "$legacy" && -f "${PENDING_DIR}/${kernel}.pending" ]]
        assert_missing "${LOCK_ROOT}/galaxybook-max98390-${kernel}.lock"
        rm -f -- "${PENDING_DIR}/${kernel}.pending" "$kmod_lifecycle_lock_path"
        : > "$kmod_lifecycle_lock_path"
        chmod 0600 "$kmod_lifecycle_lock_path"
    done
}

test_inherited_global_lock_is_reused_before_private_and_rpm() {
    local kernel=7.1.8-global-inherited.x86_64 inherited_fd
    local first_event private_line rpm_line

    new_kernel_fixture "$kernel"
    acquire_kmod_lifecycle_lock
    inherited_fd="$GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD"
    : > "$FAKE_LIFECYCLE_EVENTS"

    finalize_kernel "$kernel" >/dev/null

    first_event="$(sed -n '1p' "$FAKE_LIFECYCLE_EVENTS")"
    private_line="$(grep -n -m1 '^private-lock$' "$FAKE_LIFECYCLE_EVENTS" | cut -d: -f1)"
    rpm_line="$(grep -n -m1 '^rpm-lock$' "$FAKE_LIFECYCLE_EVENTS" | cut -d: -f1)"
    [[ "$first_event" == 'global-lock --exclusive --nonblock '* ]]
    [[ "$first_event" != *'--timeout'* ]]
    (( private_line < rpm_line ))
    validate_kmod_lifecycle_lock

    exec {inherited_fd}>&-
    unset GALAXYBOOK_KMOD_LIFECYCLE_LOCK_FD
}

test_finalizer_validates_then_removes_unmanaged_legacy
test_owner_or_vermagic_failure_preserves_legacy
test_rpm_owned_legacy_is_preserved
test_legacy_cleanup_rejects_symlink_and_hardlink
test_legacy_cleanup_rejects_identity_swap_before_unlink
test_trigger_only_queues_exact_paths_without_rpm_query
test_pending_marker_rejects_hardlinks
test_lock_warning_is_retried_and_never_emitted
test_enqueue_during_worker_remains_pending_then_converges
test_finalizer_waits_for_active_rpm_writer
test_nonrunning_failure_defers_once_and_running_boot_retries
test_running_failure_stays_pending_without_directory_churn
test_state_and_private_lock_creation_override_sgid_group
test_state_and_private_lock_reject_writable_ancestry
test_public_kernel_rejects_unsafe_state_without_side_effects
test_private_lock_rejects_symlink_and_wrong_owner_contract
test_private_lock_revalidates_group_mode_and_link_count_after_open
test_rpm_lock_rejects_symlink_and_wrong_owner_contract
test_rpm_lock_revalidates_group_mode_and_link_count
test_global_lock_precedes_private_and_rpm_and_covers_ack
test_global_lock_contention_has_zero_finalization_side_effects
test_unsafe_global_lock_has_zero_finalization_side_effects
test_inherited_global_lock_is_reused_before_private_and_rpm

printf 'test_kmod_finalize: ok\n'
