#!/usr/bin/bash

set -euo pipefail
export LC_ALL=C

FINALIZER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kmod-lifecycle-lock.sh
source "$FINALIZER_SCRIPT_DIR/kmod-lifecycle-lock.sh"

MODULE_ROOT="${MAX98390_MODULE_ROOT:-/lib/modules}"
STATE_ROOT="${MAX98390_FINALIZE_STATE_ROOT:-/var/lib/galaxybook-max98390}"
PENDING_DIR="${STATE_ROOT}/pending"
DEFERRED_DIR="${STATE_ROOT}/deferred"
LOCK_ROOT="${MAX98390_FINALIZE_LOCK_ROOT:-/run/lock/galaxybook-max98390}"
RPM_COMMAND="${MAX98390_RPM_COMMAND:-/usr/bin/rpm}"
RPM_LOCK_PATH="${MAX98390_RPM_LOCK_PATH:-/usr/lib/sysimage/rpm/.rpm.lock}"
MODINFO_COMMAND="${MAX98390_MODINFO_COMMAND:-/usr/bin/modinfo}"
DEPMOD_COMMAND="${MAX98390_DEPMOD_COMMAND:-/usr/bin/depmod}"
FLOCK_COMMAND="${MAX98390_FLOCK_COMMAND:-/usr/bin/flock}"
SLEEP_COMMAND="${MAX98390_SLEEP_COMMAND:-/usr/bin/sleep}"
SYSTEMCTL_COMMAND="${MAX98390_SYSTEMCTL_COMMAND:-/usr/bin/systemctl}"
UNAME_COMMAND="${MAX98390_UNAME_COMMAND:-/usr/bin/uname}"
EXPECTED_STATE_UID="${MAX98390_STATE_UID:-0}"
EXPECTED_STATE_GID="${MAX98390_STATE_GID:-0}"
RPM_QUERY_ATTEMPTS="${MAX98390_RPM_QUERY_ATTEMPTS:-240}"
RPM_QUERY_DELAY_SECONDS="${MAX98390_RPM_QUERY_DELAY_SECONDS:-0.25}"
RPM_LOCK_TIMEOUT_SECONDS="${MAX98390_RPM_LOCK_TIMEOUT_SECONDS:-90}"

CORE_MODULE="snd-hda-scodec-max98390"
I2C_MODULE="snd-hda-scodec-max98390-i2c"
COMMON_PACKAGE="galaxybook-max98390-kmod-common"
FINALIZER_UNIT="max98390-kmod-finalize.service"
FINALIZER_PATH_UNIT="max98390-kmod-finalize.path"

RPM_OWNER=""
RPM_OWNER_EVR=""
RPM_PACKAGE_EVR=""
RPM_LOCK_FD=""

log() {
    printf 'max98390-kmod-finalize: %s\n' "$*"
}

error() {
    printf 'max98390-kmod-finalize: %s\n' "$*" >&2
}

usage() {
    cat <<'USAGE'
Usage: max98390-kmod-finalize.sh --kernel KERNEL [--kernel KERNEL ...]
       max98390-kmod-finalize.sh --pending
       max98390-kmod-finalize.sh --from-rpm-trigger

Finalize a packaged Galaxy Book MAX98390 module pair after the RPM transaction
that installed it. Public callers should use --kernel. The internal trigger
mode only queues exact module paths and starts the worker asynchronously; it
never queries the RPM database or removes legacy modules inside the transaction.
USAGE
}

validate_configuration() {
    [[ "$RPM_QUERY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
        error "MAX98390_RPM_QUERY_ATTEMPTS must be a positive integer"
        return 2
    }
    [[ "$RPM_QUERY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        error "MAX98390_RPM_QUERY_DELAY_SECONDS must be a non-negative number"
        return 2
    }
    [[ "$RPM_LOCK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
        error "MAX98390_RPM_LOCK_TIMEOUT_SECONDS must be a positive integer"
        return 2
    }
    [[ "$EXPECTED_STATE_UID" =~ ^[0-9]+$ && "$EXPECTED_STATE_GID" =~ ^[0-9]+$ ]] || {
        error "MAX98390_STATE_UID and MAX98390_STATE_GID must be numeric"
        return 2
    }
}

validate_kernel_name() {
    local kernel="$1"

    if [[ ! "$kernel" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        error "Invalid kernel version: $kernel"
        return 1
    fi
}

validate_absolute_path() {
    local path="$1"
    local description="$2"

    if [[ ! "$path" =~ ^/[A-Za-z0-9/._+-]+$ \
        || "$path" == *'//'*
        || "/${path#/}/" == *'/./'*
        || "/${path#/}/" == *'/../'* ]]; then
        error "$description path is unsafe: $path"
        return 1
    fi
}

validate_secure_directory_ancestry() {
    local directory="$1"
    local description="$2"
    local current metadata owner_uid owner_gid mode

    validate_absolute_path "$directory" "$description" || return 1
    current="${directory%/}"
    [[ -n "$current" ]] || current=/

    while true; do
        if [[ ! -d "$current" || -L "$current" ]]; then
            error "$description ancestry is missing or unsafe: $current"
            return 1
        fi
        metadata="$(stat -c '%u:%g:%a' -- "$current")" || return 1
        IFS=: read -r owner_uid owner_gid mode <<< "$metadata"
        if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
            error "$description ancestry has an invalid mode: $current ($mode)"
            return 1
        fi

        if [[ "${MAX98390_ALLOW_NON_ROOT:-0}" == 1 ]]; then
            # Test-only overrides may live below a directory owned by the
            # invoking account, while system ancestors remain root-owned.
            if [[ "$owner_uid" != 0 && "$owner_uid" != "$EXPECTED_STATE_UID" ]]; then
                error "$description ancestry has an unsafe owner: $current ($metadata)"
                return 1
            fi
        elif [[ "$owner_uid:$owner_gid" != \
            "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" ]]; then
            error "$description ancestry has an unsafe owner: $current ($metadata)"
            return 1
        fi

        if (( (8#$mode) & 8#022 )); then
            # /tmp and /var/tmp are acceptable only to the explicitly enabled
            # non-root test contract: their root-owned sticky directories
            # protect the already-created random test root from replacement.
            if [[ "${MAX98390_ALLOW_NON_ROOT:-0}" != 1 \
                || ( "$current" != /tmp && "$current" != /var/tmp ) \
                || "$owner_uid:$owner_gid:$mode" != 0:0:1777 ]]; then
                error "$description ancestry is group- or world-writable: $current"
                return 1
            fi
        fi

        [[ "$current" == / ]] && break
        current="${current%/*}"
        [[ -n "$current" ]] || current=/
    done
}

validate_state_directory() {
    local directory="$1"
    local metadata parent

    validate_absolute_path "$directory" 'State directory' || return 1
    parent="${directory%/*}"
    [[ -n "$parent" ]] || parent=/
    validate_secure_directory_ancestry "$parent" 'State directory' || return 1
    if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
        error "Refusing unsafe state directory: $directory"
        return 1
    fi

    if [[ ! -e "$directory" ]]; then
        install -d -o "$EXPECTED_STATE_UID" -g "$EXPECTED_STATE_GID" \
            -m 0755 -- "$directory"
        # GNU install can preserve an inherited SGID bit on a new directory;
        # apply the final mode explicitly after forcing the intended group.
        chmod 00755 -- "$directory"
    fi
    if [[ ! -d "$directory" || -L "$directory" ]]; then
        error "State directory changed while being secured: $directory"
        return 1
    fi
    metadata="$(stat -Lc '%u:%g:%a' -- "$directory")"
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:755" ]]; then
        error "State directory has unsafe ownership or mode: $directory ($metadata)"
        return 1
    fi
}

ensure_state_directories() {
    validate_state_directory "$STATE_ROOT" || return 1
    validate_state_directory "$PENDING_DIR" || return 1
    validate_state_directory "$DEFERRED_DIR" || return 1
}

queue_kernel() {
    local kernel="$1"
    local marker temporary

    validate_kernel_name "$kernel" || return 1
    ensure_state_directories || return 1

    marker="${PENDING_DIR}/${kernel}.pending"
    if [[ -L "$marker" || ( -e "$marker" && ! -f "$marker" ) ]]; then
        error "Refusing unsafe pending marker: $marker"
        return 1
    fi
    if [[ -e "$marker" ]]; then
        validate_pending_marker "$kernel" "$marker" || return 1
    fi

    temporary="$(mktemp "${PENDING_DIR}/.${kernel}.XXXXXX")"
    if ! printf '%s\n' 'version=1' "kernel=${kernel}" > "$temporary"; then
        rm -f -- "$temporary"
        error "Could not write pending marker for $kernel"
        return 1
    fi
    if ! chown "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" -- "$temporary" \
        || ! chmod 0644 -- "$temporary" \
        || ! mv -fT -- "$temporary" "$marker"; then
        rm -f -- "$temporary"
        error "Could not publish pending marker for $kernel"
        return 1
    fi

    log "Queued MAX98390 finalization for $kernel"
}

validate_pending_marker() {
    local kernel="$1"
    local marker="$2"
    local metadata expected_content

    validate_kernel_name "$kernel" || return 1
    if [[ "$marker" != "${PENDING_DIR}/${kernel}.pending" \
        && "$marker" != "${DEFERRED_DIR}/${kernel}.pending" ]]; then
        error "Pending marker is outside the managed state directories: $marker"
        return 1
    fi
    if [[ ! -f "$marker" || -L "$marker" ]]; then
        error "Refusing unsafe pending marker: $marker"
        return 1
    fi

    metadata="$(stat -Lc '%u:%g:%a:%h' -- "$marker")"
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:644:1" ]]; then
        error "Pending marker has unsafe ownership or mode: $marker ($metadata)"
        return 1
    fi

    expected_content="$(printf '%s\n' 'version=1' "kernel=${kernel}")"
    if [[ "$(< "$marker")" != "$expected_content" ]]; then
        error "Pending marker is malformed: $marker"
        return 1
    fi
}

rpm_owner_state() {
    local path="$1"
    local output status owner evr

    RPM_OWNER=""
    RPM_OWNER_EVR=""
    if [[ -n "$RPM_LOCK_FD" ]]; then
        # Reassert the compatible OFD read lock before every RPM query. This is
        # idempotent on the same open-file-description and authenticates that
        # the full critical section is still serialized against RPM writers.
        if ! validate_open_rpm_lock \
            || ! "$FLOCK_COMMAND" --fcntl --shared --nonblock "$RPM_LOCK_FD" \
            || ! validate_open_rpm_lock; then
            return 2
        fi
    fi
    set +e
    output="$("$RPM_COMMAND" -qf --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' -- "$path" 2>&1)"
    status=$?
    set -e

    owner="${output%%$'\t'*}"
    evr="${output#*$'\t'}"
    if (( status == 0 )) \
        && [[ "$output" == "${owner}"$'\t'"${evr}" \
        && "$output" != *$'\n'* && "$output" != *$'\r'* \
        && "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ \
        && "$evr" =~ ^[0-9]+:[0-9A-Za-z._+~^]+-[0-9A-Za-z._+~^]+$ \
        ]]; then
        RPM_OWNER="$owner"
        RPM_OWNER_EVR="$evr"
        return 0
    fi

    if (( status != 0 )) \
        && [[ "$output" == "file $path is not owned by any package" ]]; then
        return 1
    fi

    # A query executed while RPM still owns its transaction lock reaches this
    # branch because stderr is deliberately folded into the exact result.
    # Treat every unexpected diagnostic as transient/error and fail closed.
    return 2
}

rpm_package_evr_state() {
    local package="$1"
    local output status

    RPM_PACKAGE_EVR=""
    [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 2
    if [[ -n "$RPM_LOCK_FD" ]]; then
        if ! validate_open_rpm_lock \
            || ! "$FLOCK_COMMAND" --fcntl --shared --nonblock "$RPM_LOCK_FD" \
            || ! validate_open_rpm_lock; then
            return 2
        fi
    fi
    set +e
    output="$("$RPM_COMMAND" -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' -- "$package" 2>&1)"
    status=$?
    set -e

    if (( status == 0 )) \
        && [[ "$output" =~ ^[0-9]+:[0-9A-Za-z._+~^]+-[0-9A-Za-z._+~^]+$ ]]; then
        RPM_PACKAGE_EVR="$output"
        return 0
    fi
    if (( status != 0 )) \
        && [[ "$output" == "package $package is not installed" ]]; then
        return 1
    fi
    return 2
}

wait_for_package_evr() {
    local package="$1"
    local attempt state

    for ((attempt = 1; attempt <= RPM_QUERY_ATTEMPTS; attempt++)); do
        if rpm_package_evr_state "$package"; then
            return 0
        else
            state=$?
        fi
        if (( state == 1 )); then
            error "Required RPM package is not installed: $package"
            return 1
        fi
        if (( attempt < RPM_QUERY_ATTEMPTS )); then
            "$SLEEP_COMMAND" "$RPM_QUERY_DELAY_SECONDS"
        fi
    done
    error "RPM database did not become safely queryable for $package"
    return 1
}

wait_for_expected_owner() {
    local path="$1"
    local expected_owner="$2"
    local expected_evr="$3"
    local attempt state

    for ((attempt = 1; attempt <= RPM_QUERY_ATTEMPTS; attempt++)); do
        if rpm_owner_state "$path"; then
            if [[ "$RPM_OWNER" == "$expected_owner" \
                && "$RPM_OWNER_EVR" == "$expected_evr" ]]; then
                return 0
            fi
            error "Unexpected RPM owner or EVR for $path: ${RPM_OWNER}-${RPM_OWNER_EVR} (expected ${expected_owner}-${expected_evr})"
            return 1
        else
            state=$?
        fi

        if (( state == 1 )); then
            error "Module payload is not owned by an installed RPM: $path"
            return 1
        fi

        if (( attempt < RPM_QUERY_ATTEMPTS )); then
            "$SLEEP_COMMAND" "$RPM_QUERY_DELAY_SECONDS"
        fi
    done

    error "RPM database did not become safely queryable for $path"
    return 1
}

find_module_payload() {
    local expected_dir="$1"
    local module_name="$2"
    local candidate
    local -a payloads=()

    for candidate in \
        "${expected_dir}/${module_name}.ko" \
        "${expected_dir}/${module_name}.ko.xz" \
        "${expected_dir}/${module_name}.ko.zst" \
        "${expected_dir}/${module_name}.ko.gz"; do
        if [[ -L "$candidate" ]]; then
            error "Refusing symlink module payload: $candidate"
            return 1
        fi
        [[ -f "$candidate" ]] && payloads+=("$candidate")
    done

    if (( ${#payloads[@]} != 1 )); then
        error "Expected exactly one regular $module_name payload in $expected_dir; found ${#payloads[@]}"
        return 1
    fi

    printf '%s\n' "${payloads[0]}"
}

validate_payload_vermagic() {
    local kernel="$1"
    local payload="$2"
    local vermagic vermagic_kernel

    if ! vermagic="$("$MODINFO_COMMAND" -F vermagic -- "$payload")"; then
        error "Could not read vermagic from $payload"
        return 1
    fi
    vermagic_kernel="${vermagic%% *}"
    if [[ "$vermagic_kernel" != "$kernel" ]]; then
        error "Invalid vermagic for $payload: ${vermagic_kernel:-missing} (expected $kernel)"
        return 1
    fi
}

marker_identity() {
    local marker="$1"

    stat -Lc '%d:%i' -- "$marker"
}

legacy_metadata() {
    local path="$1"
    local metadata device inode owner_uid owner_gid mode links size

    if [[ ! -f "$path" || -L "$path" ]]; then
        error "Legacy override is not a regular non-symlink file: $path"
        return 1
    fi
    metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h:%s' -- "$path")" || return 1
    IFS=: read -r device inode owner_uid owner_gid mode links size <<< "$metadata"
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ \
        && "$size" =~ ^[0-9]+$ ]] || return 1
    if [[ "$owner_uid:$owner_gid" != \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" \
        || ! "$mode" =~ ^[0-7]{3,4}$ \
        || "$links" != 1 ]] \
        || (( (8#$mode) & 8#022 )); then
        error "Legacy override has unsafe metadata: $path ($metadata)"
        return 1
    fi
    printf '%s\n' "$metadata"
}

validate_rpm_lock_path() {
    validate_absolute_path "$RPM_LOCK_PATH" 'RPM transaction lock'
}

rpm_lock_metadata_is_safe() {
    local metadata="$1"
    local device inode owner_uid owner_gid mode links

    IFS=: read -r device inode owner_uid owner_gid mode links <<< "$metadata"
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ \
        && "$owner_uid" =~ ^[0-9]+$ && "$owner_gid" =~ ^[0-9]+$ \
        && "$mode" =~ ^[0-7]{3,4}$ && "$links" =~ ^[0-9]+$ ]] || return 1
    [[ "$owner_uid:$owner_gid" == \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" ]] || return 1
    (( ! ((8#$mode) & 8#022) )) || return 1
    [[ "$links" == 1 ]]
}

validate_rpm_lock_file() {
    local metadata

    if [[ ! -f "$RPM_LOCK_PATH" || -L "$RPM_LOCK_PATH" ]]; then
        error "RPM transaction lock is not a regular file: $RPM_LOCK_PATH"
        return 1
    fi
    metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$RPM_LOCK_PATH")" || return 1
    if ! rpm_lock_metadata_is_safe "$metadata"; then
        error "RPM transaction lock has unsafe metadata: $RPM_LOCK_PATH ($metadata)"
        return 1
    fi
}

validate_open_rpm_lock() {
    local fd_path fd_metadata path_metadata

    [[ "$RPM_LOCK_FD" =~ ^[0-9]+$ ]] || return 1
    fd_path="/proc/${BASHPID}/fd/${RPM_LOCK_FD}"
    if [[ ! -f "$fd_path" ]]; then
        error "RPM transaction lock descriptor is not a regular file"
        return 1
    fi
    validate_rpm_lock_file || return 1
    fd_metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path")" || return 1
    path_metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$RPM_LOCK_PATH")" || return 1
    if [[ "$fd_metadata" != "$path_metadata" ]] \
        || ! rpm_lock_metadata_is_safe "$fd_metadata"; then
        error "Opened RPM lock no longer matches the safe validated path"
        return 1
    fi
}

close_rpm_read_lock() {
    if [[ "$RPM_LOCK_FD" =~ ^[0-9]+$ ]]; then
        exec {RPM_LOCK_FD}<&-
    fi
    RPM_LOCK_FD=""
}

acquire_rpm_read_lock() {
    local lock_parent

    validate_rpm_lock_path || return 1
    lock_parent="${RPM_LOCK_PATH%/*}"
    [[ -n "$lock_parent" ]] || lock_parent=/
    validate_secure_directory_ancestry "$lock_parent" \
        'RPM transaction lock' || return 1
    validate_rpm_lock_file || return 1
    if ! exec {RPM_LOCK_FD}<"$RPM_LOCK_PATH"; then
        error "Could not open the RPM transaction lock"
        return 1
    fi
    if ! validate_open_rpm_lock; then
        close_rpm_read_lock
        return 1
    fi
    if ! "$FLOCK_COMMAND" --fcntl --shared \
        --timeout "$RPM_LOCK_TIMEOUT_SECONDS" "$RPM_LOCK_FD"; then
        error "Timed out waiting for the RPM transaction read lock"
        close_rpm_read_lock
        return 1
    fi
    if ! validate_open_rpm_lock; then
        close_rpm_read_lock
        return 1
    fi
}

private_lock_metadata_is_safe() {
    local metadata="$1"
    local device inode owner_uid owner_gid mode links

    IFS=: read -r device inode owner_uid owner_gid mode links <<< "$metadata"
    [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ \
        && "$owner_uid" =~ ^[0-9]+$ && "$owner_gid" =~ ^[0-9]+$ \
        && "$mode" =~ ^[0-7]{3,4}$ && "$links" =~ ^[0-9]+$ ]] || return 1
    [[ "$owner_uid:$owner_gid:$mode:$links" == \
        "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:600:1" ]]
}

validate_private_lock_file() {
    local lock_file="$1"
    local metadata

    if [[ ! -f "$lock_file" || -L "$lock_file" ]]; then
        error "Finalization lock is not a regular file: $lock_file"
        return 1
    fi
    metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$lock_file")" || return 1
    if ! private_lock_metadata_is_safe "$metadata"; then
        error "Finalization lock has unsafe metadata: $lock_file ($metadata)"
        return 1
    fi
}

validate_open_private_lock() {
    local lock_file="$1"
    local lock_fd="$2"
    local fd_path fd_metadata path_metadata

    [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 1
    fd_path="/proc/${BASHPID}/fd/${lock_fd}"
    [[ -f "$fd_path" ]] || return 1
    validate_private_lock_file "$lock_file" || return 1
    fd_metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path")" || return 1
    path_metadata="$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$lock_file")" || return 1
    if [[ "$fd_metadata" != "$path_metadata" ]] \
        || ! private_lock_metadata_is_safe "$fd_metadata"; then
        error "Opened finalization lock no longer matches the safe validated path"
        return 1
    fi
}

ensure_private_lock_directory() {
    local metadata lock_parent

    validate_absolute_path "$LOCK_ROOT" 'Private lock directory' || return 1
    lock_parent="${LOCK_ROOT%/*}"
    [[ -n "$lock_parent" ]] || lock_parent=/
    validate_secure_directory_ancestry "$lock_parent" \
        'Private lock directory' || return 1
    if [[ -L "$LOCK_ROOT" || ( -e "$LOCK_ROOT" && ! -d "$LOCK_ROOT" ) ]]; then
        error "Refusing unsafe lock directory: $LOCK_ROOT"
        return 1
    fi
    if [[ ! -e "$LOCK_ROOT" ]]; then
        install -d -o "$EXPECTED_STATE_UID" -g "$EXPECTED_STATE_GID" \
            -m 0700 -- "$LOCK_ROOT"
        chmod 00700 -- "$LOCK_ROOT"
    fi
    if [[ ! -d "$LOCK_ROOT" || -L "$LOCK_ROOT" ]]; then
        error "Private lock directory changed while being secured: $LOCK_ROOT"
        return 1
    fi
    metadata="$(stat -Lc '%u:%g:%a' -- "$LOCK_ROOT")" || return 1
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:700" ]]; then
        error "Private lock directory has unsafe ownership or mode: $LOCK_ROOT ($metadata)"
        return 1
    fi
}

finalize_kernel() (
    local kernel="$1"
    local expected_owner expected_evr expected_dir lock_file lock_fd module_name payload
    local legacy_path extension state resolved_path marker identity current_identity
    local lock_existed=0
    local -a modules=("$CORE_MODULE" "$I2C_MODULE")
    local -a legacy_paths=()
    local -a markers=()
    declare -A payloads=()
    declare -A legacy_identities=()
    declare -A marker_identities=()

    validate_kernel_name "$kernel" || return 1
    if [[ ! -d "${MODULE_ROOT}/${kernel}" ]]; then
        error "Kernel module directory not found: ${MODULE_ROOT}/${kernel}"
        return 1
    fi

    # The global Galaxy Book lifecycle lock serializes depmod (and the dracut
    # work performed by sibling drivers) across independently triggered
    # workers. It must precede both the MAX98390-private lock and RPM's shared
    # OFD lock so every participant has one consistent lock hierarchy.
    if ! acquire_kmod_lifecycle_lock; then
        error "Could not acquire the global kernel-module lifecycle lock"
        return 1
    fi

    # The public --kernel API bypasses process_pending(), so authenticate the
    # durable state roots here before reading or acknowledging any marker.
    ensure_state_directories || return 1
    ensure_private_lock_directory || return 1
    lock_file="${LOCK_ROOT}/galaxybook-max98390-${kernel}.lock"
    if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]; then
        error "Refusing unsafe finalization lock: $lock_file"
        return 1
    fi
    if [[ -e "$lock_file" ]]; then
        lock_existed=1
        validate_private_lock_file "$lock_file" || return 1
    fi
    umask 077
    if ! exec {lock_fd}>>"$lock_file"; then
        error "Could not open finalization lock for $kernel"
        return 1
    fi
    if (( lock_existed == 0 )) \
        && { ! chown "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" -- "$lock_file" \
            || ! chmod 0600 -- "$lock_file"; }; then
        error "Could not secure finalization lock for $kernel"
        return 1
    fi
    validate_open_private_lock "$lock_file" "$lock_fd" || return 1
    if ! "$FLOCK_COMMAND" -x "$lock_fd"; then
        error "Could not acquire finalization lock for $kernel"
        return 1
    fi
    validate_open_private_lock "$lock_file" "$lock_fd" || return 1
    acquire_rpm_read_lock || return 1
    validate_kmod_lifecycle_lock || {
        error "Global kernel-module lifecycle lock changed before finalization"
        return 1
    }

    for marker in \
        "${PENDING_DIR}/${kernel}.pending" \
        "${DEFERRED_DIR}/${kernel}.pending"; do
        [[ -e "$marker" || -L "$marker" ]] || continue
        validate_pending_marker "$kernel" "$marker" || return 1
        identity="$(marker_identity "$marker")"
        markers+=("$marker")
        marker_identities["$marker"]="$identity"
    done

    expected_owner="kmod-galaxybook-max98390-${kernel}"
    wait_for_package_evr "$COMMON_PACKAGE" || return 1
    expected_evr="$RPM_PACKAGE_EVR"
    expected_dir="${MODULE_ROOT}/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs"

    # Validate the complete replacement set before examining any historical
    # override. Validation is exact for package owner, EVR and vermagic.
    for module_name in "${modules[@]}"; do
        payload="$(find_module_payload "$expected_dir" "$module_name")" || return 1
        payloads["$module_name"]="$payload"
    done
    for module_name in "${modules[@]}"; do
        payload="${payloads[$module_name]}"
        wait_for_expected_owner "$payload" "$expected_owner" "$expected_evr" || return 1
        validate_payload_vermagic "$kernel" "$payload" || return 1
    done

    # Never delete or adopt an override that is not owned by this package.
    # The packaged depmod override gives the validated family payload explicit
    # priority while retaining a local legacy copy as a non-destructive
    # fallback when the package payload is absent.
    for module_name in "${modules[@]}"; do
        for extension in ko ko.xz ko.zst ko.gz; do
            legacy_path="${MODULE_ROOT}/${kernel}/updates/sound/hda/codecs/side-codecs/${module_name}.${extension}"
            [[ -e "$legacy_path" || -L "$legacy_path" ]] || continue

            identity="$(legacy_metadata "$legacy_path")" || return 1
            legacy_paths+=("$legacy_path")
            legacy_identities["$legacy_path"]="$identity"

            if rpm_owner_state "$legacy_path"; then
                log "Preserving RPM-owned legacy path $legacy_path ($RPM_OWNER)"
                continue
            else
                state=$?
            fi

            if (( state == 1 )); then
                log "Preserving unmanaged legacy override $legacy_path; packaged depmod policy must select the RPM payload"
            else
                error "Could not safely determine RPM ownership of $legacy_path"
                return 1
            fi
        done
    done
    for legacy_path in "${legacy_paths[@]}"; do
        identity="$(legacy_metadata "$legacy_path")" || return 1
        if [[ "$identity" != "${legacy_identities[$legacy_path]}" ]]; then
            error "Legacy override changed during validation: $legacy_path"
            return 1
        fi
    done

    # kmod's system-wide indexes must also be readable by unprivileged clients.
    # Do not relax the private lock/state umask anywhere else in this worker.
    if ! (umask 022 && "$DEPMOD_COMMAND" -a "$kernel"); then
        error "depmod failed for $kernel"
        return 1
    fi

    for module_name in "${modules[@]}"; do
        if ! resolved_path="$("$MODINFO_COMMAND" -k "$kernel" -n "$module_name")"; then
            error "modinfo could not resolve $module_name for $kernel"
            return 1
        fi
        if [[ "$resolved_path" != "${payloads[$module_name]}" \
            || ! -f "$resolved_path" || -L "$resolved_path" ]]; then
            error "$module_name resolves outside its validated payload for $kernel: $resolved_path"
            return 1
        fi
    done

    # Only acknowledge markers observed before validation. If the RPM trigger
    # atomically publishes a replacement marker while this worker is active,
    # its inode changes and the new request remains queued for the path unit.
    for marker in "${markers[@]}"; do
        [[ -e "$marker" || -L "$marker" ]] || continue
        validate_pending_marker "$kernel" "$marker" || return 1
        current_identity="$(marker_identity "$marker")"
        if [[ "$current_identity" == "${marker_identities[$marker]}" ]]; then
            rm -f -- "$marker"
        else
            log "A newer finalization request remains queued for $kernel"
        fi
    done

    validate_kmod_lifecycle_lock || {
        error "Global kernel-module lifecycle lock changed before completion"
        return 1
    }

    log "MAX98390 kernel finalization completed for $kernel"
)

start_finalizer_async() {
    if ! command -v "$SYSTEMCTL_COMMAND" >/dev/null 2>&1; then
        log "systemctl unavailable; pending finalization will be retried at boot"
        return 0
    fi

    if ! "$SYSTEMCTL_COMMAND" start --no-block "$FINALIZER_PATH_UNIT" "$FINALIZER_UNIT"; then
        log "Could not start the finalizer units now; the durable queue will be retried at boot"
    fi
}

queue_from_rpm_trigger() {
    local path trigger_root relative kernel basename
    local queued=0
    declare -A kernels=()

    while IFS= read -r path; do
        case "$path" in
            /lib/modules/*/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/*)
                trigger_root="/lib/modules"
                ;;
            /usr/lib/modules/*/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/*)
                trigger_root="/usr/lib/modules"
                ;;
            *)
                continue
                ;;
        esac

        basename="${path##*/}"
        case "$basename" in
            "${CORE_MODULE}.ko"|"${CORE_MODULE}.ko.xz"|"${CORE_MODULE}.ko.zst"|"${CORE_MODULE}.ko.gz"|\
            "${I2C_MODULE}.ko"|"${I2C_MODULE}.ko.xz"|"${I2C_MODULE}.ko.zst"|"${I2C_MODULE}.ko.gz")
                relative="${path#"${trigger_root}/"}"
                kernel="${relative%%/*}"
                validate_kernel_name "$kernel" || return 1
                if [[ "$path" != "${trigger_root}/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs/${basename}" ]]; then
                    continue
                fi
                kernels["$kernel"]=1
                ;;
        esac
    done

    for kernel in "${!kernels[@]}"; do
        queue_kernel "$kernel" || return 1
        queued=1
    done

    if (( queued == 1 )); then
        start_finalizer_async
    fi
}

defer_pending_marker() {
    local kernel="$1"
    local marker="${PENDING_DIR}/${kernel}.pending"
    local expected_identity="$2"
    local current_identity destination

    [[ -e "$marker" || -L "$marker" ]] || return 0
    validate_pending_marker "$kernel" "$marker" || return 1
    current_identity="$(marker_identity "$marker")"
    if [[ "$current_identity" != "$expected_identity" ]]; then
        log "Keeping a newer pending request in place for $kernel"
        return 0
    fi

    destination="${DEFERRED_DIR}/${kernel}.pending"
    if [[ -L "$destination" || ( -e "$destination" && ! -f "$destination" ) ]]; then
        error "Refusing unsafe deferred marker: $destination"
        return 1
    fi
    if [[ -e "$destination" ]]; then
        validate_pending_marker "$kernel" "$destination" || return 1
    fi
    mv -fT -- "$marker" "$destination"
    log "Deferred MAX98390 finalization for $kernel until the next explicit or boot retry"
}

activate_running_deferred_marker() {
    local kernel="$1"
    local deferred="${DEFERRED_DIR}/${kernel}.pending"
    local pending="${PENDING_DIR}/${kernel}.pending"

    [[ -e "$deferred" || -L "$deferred" ]] || return 0
    validate_pending_marker "$kernel" "$deferred" || return 1
    if [[ -e "$pending" || -L "$pending" ]]; then
        validate_pending_marker "$kernel" "$pending" || return 1
        return 0
    fi

    mv -fT -- "$deferred" "$pending"
    log "Reactivated deferred finalization for the running kernel $kernel"
}

process_pending() {
    local running_kernel marker kernel identity attempted_key
    local made_attempt status=0 current_failed=0
    local -a markers=() ordered=()
    declare -A attempted=()

    ensure_state_directories || return 1
    running_kernel="$("$UNAME_COMMAND" -r)"
    validate_kernel_name "$running_kernel" || return 1
    activate_running_deferred_marker "$running_kernel" || return 1

    while true; do
        made_attempt=0
        markers=()
        ordered=()
        shopt -s nullglob
        markers=("$PENDING_DIR"/*)
        shopt -u nullglob

        for marker in "${markers[@]}"; do
            kernel="${marker##*/}"
            kernel="${kernel%.pending}"
            validate_pending_marker "$kernel" "$marker" || return 1
            identity="$(marker_identity "$marker")"
            attempted_key="${marker}|${identity}"
            [[ -n "${attempted[$attempted_key]:-}" ]] && continue
            [[ "$kernel" == "$running_kernel" ]] \
                && ordered=("$marker" "${ordered[@]}") \
                || ordered+=("$marker")
        done

        for marker in "${ordered[@]}"; do
            kernel="${marker##*/}"
            kernel="${kernel%.pending}"
            identity="$(marker_identity "$marker")"
            attempted_key="${marker}|${identity}"
            attempted["$attempted_key"]=1
            made_attempt=1
            if ! finalize_kernel "$kernel"; then
                status=1
                if [[ "$kernel" == "$running_kernel" ]]; then
                    current_failed=1
                    error "Keeping the running kernel request pending after a failed finalization"
                else
                    defer_pending_marker "$kernel" "$identity" || return 1
                fi
            fi
        done

        (( made_attempt == 1 )) || break
    done

    # A stale or not-yet-buildable non-running kernel must not suppress sound
    # for the current kernel. Its marker remains durable and becomes mandatory
    # when that kernel is booted. Public --kernel callers still fail strictly.
    if (( current_failed == 1 )) \
        && [[ -e "${PENDING_DIR}/${running_kernel}.pending" \
            || -L "${PENDING_DIR}/${running_kernel}.pending" \
            || -e "${DEFERRED_DIR}/${running_kernel}.pending" \
            || -L "${DEFERRED_DIR}/${running_kernel}.pending" ]]; then
        return 1
    fi
    (( status == 0 )) || log "Some non-running kernels remain queued for a later retry"
}

main() {
    local mode=""
    local -a kernels=()

    while (( $# > 0 )); do
        case "$1" in
            --kernel)
                (( $# >= 2 )) || {
                    error "Missing value for --kernel"
                    usage >&2
                    return 2
                }
                kernels+=("$2")
                shift 2
                ;;
            --pending|--from-rpm-trigger)
                [[ -z "$mode" ]] || {
                    error "Finalizer modes cannot be combined"
                    return 2
                }
                mode="$1"
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                error "Unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done

    validate_configuration || return $?
    if [[ "${MAX98390_ALLOW_NON_ROOT:-0}" != 1 && "$EUID" -ne 0 ]]; then
        error "Kernel finalization must run as root"
        return 1
    fi

    if [[ "$mode" == --from-rpm-trigger ]]; then
        (( ${#kernels[@]} == 0 )) || {
            error "--from-rpm-trigger cannot be combined with --kernel"
            return 2
        }
        queue_from_rpm_trigger
        return
    fi
    if [[ "$mode" == --pending ]]; then
        (( ${#kernels[@]} == 0 )) || {
            error "--pending cannot be combined with --kernel"
            return 2
        }
        process_pending
        return
    fi
    if (( ${#kernels[@]} == 0 )); then
        error "At least one --kernel argument is required"
        usage >&2
        return 2
    fi

    local kernel
    for kernel in "${kernels[@]}"; do
        finalize_kernel "$kernel" || return 1
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
