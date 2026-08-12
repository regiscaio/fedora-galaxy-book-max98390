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

FAKE_PAYLOAD_OWNER=""
FAKE_LEGACY_OWNER=""
FAKE_WRONG_VERMAGIC=0
FAKE_TRANSIENT_REMAINING_FILE="$TEST_ROOT/transient-remaining"
FAKE_BLOCK_REQUEST="$TEST_ROOT/block-request"
FAKE_BLOCK_ENTERED="$TEST_ROOT/block-entered"
FAKE_BLOCK_RELEASE="$TEST_ROOT/block-release"
FAKE_RPM_CALLS="$TEST_ROOT/rpm-calls"
FAKE_DEPMOD_CALLS="$TEST_ROOT/depmod-calls"
FAKE_SLEEP_CALLS="$TEST_ROOT/sleep-calls"
FAKE_SYSTEMCTL_CALLS="$TEST_ROOT/systemctl-calls"
FAKE_RUNNING_KERNEL="test-running.x86_64"

fake_rpm() {
    local path="${*: -1}"
    local remaining=0

    printf '%s\n' "$path" >> "$FAKE_RPM_CALLS"
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
}

fake_flock() {
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

test_finalizer_validates_then_removes_unmanaged_legacy
test_owner_or_vermagic_failure_preserves_legacy
test_rpm_owned_legacy_is_preserved
test_trigger_only_queues_exact_paths_without_rpm_query
test_lock_warning_is_retried_and_never_emitted
test_enqueue_during_worker_remains_pending_then_converges
test_finalizer_waits_for_active_rpm_writer
test_nonrunning_failure_defers_once_and_running_boot_retries
test_running_failure_stays_pending_without_directory_churn
test_private_lock_rejects_symlink_and_wrong_owner_contract
test_rpm_lock_rejects_symlink_and_wrong_owner_contract

printf 'test_kmod_finalize: ok\n'
