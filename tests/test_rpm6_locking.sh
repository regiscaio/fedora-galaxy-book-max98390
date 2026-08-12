#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$TEST_DIR/fixtures/rpm-transaction"
PAYLOAD_PATH=/opt/max98390-rpm-lock-test/module.ko

if [[ "${MAX98390_RPM6_EPHEMERAL_TEST:-0}" != 1 ]]; then
    printf 'test_rpm6_locking: skipped (requires an explicitly ephemeral root container)\n'
    exit 0
fi
if [[ "$EUID" -ne 0 || ! -e /run/.containerenv ]]; then
    printf 'test_rpm6_locking: refusing to mutate a non-ephemeral RPM database\n' >&2
    exit 1
fi

for command in flock rpm rpmbuild timeout; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'test_rpm6_locking: missing command %s\n' "$command" >&2
        exit 1
    }
done
[[ "$(rpm --version)" == 'RPM version 6.'* ]] || {
    printf 'test_rpm6_locking: RPM 6 is required\n' >&2
    exit 1
}
flock --help | grep -Fq -- '--fcntl' || {
    printf 'test_rpm6_locking: util-linux flock lacks --fcntl\n' >&2
    exit 1
}

test_root="$(mktemp -d /tmp/max98390-rpm6-locking.XXXXXX)"
topdir="$test_root/rpmbuild"
mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

for fixture in payload writer; do
    rpmbuild -bb "$FIXTURE_DIR/${fixture}.spec" \
        --define "_topdir $topdir" \
        > "$test_root/build-${fixture}.log" 2>&1
done
payload_rpm="$(find "$topdir/RPMS" -type f -name 'max98390-rpm-lock-payload-*.rpm' -print -quit)"
writer_rpm="$(find "$topdir/RPMS" -type f -name 'max98390-rpm-lock-writer-*.rpm' -print -quit)"
[[ -f "$payload_rpm" && -f "$writer_rpm" ]]

rpm --nodeps -i "$payload_rpm"
lock_path="$(rpm --eval '%{_rpmlock_path}')"
[[ "$lock_path" == /* && -f "$lock_path" && ! -L "$lock_path" ]]

# The parent OFD read lock is compatible with the child RPM query. The exact
# owner must be returned without the RPM 6 nested-lock diagnostic on stderr.
exec {read_fd}<"$lock_path"
flock --fcntl --shared "$read_fd"
rpm -qf --qf '%{NAME}\n' -- "$PAYLOAD_PATH" \
    > "$test_root/owner.out" 2> "$test_root/owner.err"
[[ "$(< "$test_root/owner.out")" == max98390-rpm-lock-payload ]]
[[ ! -s "$test_root/owner.err" ]]

# A real RPM write transaction cannot enter while the shared OFD/POSIX record
# lock is held. RPM may fail fast or wait; both preserve the critical section.
set +e
timeout 2 rpm --nodeps --replacepkgs -i "$writer_rpm" \
    > "$test_root/writer-blocked.out" 2>&1
blocked_status=$?
set -e
(( blocked_status != 0 ))
exec {read_fd}<&-
rpm --nodeps --replacepkgs -i "$writer_rpm"

run_release_case() {
    local mode="$1"
    local ready="$test_root/${mode}.ready"
    local release="$test_root/${mode}.release"
    local holder_pid attempt holder_status=0 blocked drain_fd

    (
        local holder_fd
        exec {holder_fd}<"$lock_path"
        flock --fcntl --shared "$holder_fd"
        : > "$ready"
        if [[ "$mode" == signal ]]; then
            # This child inherits the OFD and deliberately outlives a TERM
            # sent only to its parent shell. A real systemd stop targets the
            # whole control group; this synthetic edge proves the standalone
            # lifecycle without relying on scheduler timing.
            /usr/bin/bash -c 'trap "" TERM HUP; /usr/bin/sleep 0.25'
        else
            while [[ ! -f "$release" ]]; do
                /usr/bin/sleep 0.01
            done
        fi
        [[ "$mode" == failure ]] && exit 73
        exit 0
    ) &
    holder_pid=$!
    for ((attempt = 1; attempt <= 200; attempt++)); do
        [[ -f "$ready" ]] && break
        /usr/bin/sleep 0.01
    done
    [[ -f "$ready" ]]

    set +e
    timeout 2 rpm --nodeps --replacepkgs -i "$writer_rpm" \
        > "$test_root/${mode}-blocked.out" 2>&1
    blocked=$?
    set -e
    (( blocked != 0 ))

    if [[ "$mode" == signal ]]; then
        kill -TERM "$holder_pid"
    else
        : > "$release"
    fi
    set +e
    wait "$holder_pid"
    holder_status=$?
    set -e
    case "$mode" in
        success) [[ "$holder_status" == 0 ]] ;;
        failure) [[ "$holder_status" == 73 ]] ;;
        signal) (( holder_status > 128 )) ;;
    esac

    # A shell can exit from SIGTERM while a short-lived child still owns the
    # inherited open-file-description. Wait for an exclusive OFD checkpoint
    # before the next transaction so signal release is deterministic rather
    # than dependent on scheduler timing.
    exec {drain_fd}<>"$lock_path"
    flock --fcntl --exclusive --timeout 2 "$drain_fd"
    exec {drain_fd}>&-
    rpm --nodeps --replacepkgs -i "$writer_rpm"
}

run_release_case success
run_release_case failure
run_release_case signal

printf 'test_rpm6_locking: ok (%s)\n' "$(rpm --version)"
