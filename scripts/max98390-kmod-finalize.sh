#!/usr/bin/bash

set -euo pipefail
export LC_ALL=C

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
FINALIZER_UNIT="max98390-kmod-finalize.service"
FINALIZER_PATH_UNIT="max98390-kmod-finalize.path"

RPM_OWNER=""
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

validate_state_directory() {
    local directory="$1"
    local metadata

    if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
        error "Refusing unsafe state directory: $directory"
        return 1
    fi

    install -d -m 0755 -- "$directory"
    metadata="$(stat -Lc '%u:%g:%a' -- "$directory")"
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:755" ]]; then
        error "State directory has unsafe ownership or mode: $directory ($metadata)"
        return 1
    fi
}

ensure_state_directories() {
    validate_state_directory "$STATE_ROOT"
    validate_state_directory "$PENDING_DIR"
    validate_state_directory "$DEFERRED_DIR"
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

    metadata="$(stat -Lc '%u:%g:%a' -- "$marker")"
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:644" ]]; then
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
    local output status

    RPM_OWNER=""
    if [[ -n "$RPM_LOCK_FD" ]]; then
        # Reassert the compatible OFD read lock before every RPM query. This is
        # idempotent on the same open-file-description and authenticates that
        # the full critical section is still serialized against RPM writers.
        if ! "$FLOCK_COMMAND" --fcntl --shared --nonblock "$RPM_LOCK_FD"; then
            return 2
        fi
    fi
    set +e
    output="$("$RPM_COMMAND" -qf --qf '%{NAME}\n' -- "$path" 2>&1)"
    status=$?
    set -e

    if (( status == 0 )) \
        && [[ "$output" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        RPM_OWNER="$output"
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

wait_for_expected_owner() {
    local path="$1"
    local expected_owner="$2"
    local attempt state

    for ((attempt = 1; attempt <= RPM_QUERY_ATTEMPTS; attempt++)); do
        if rpm_owner_state "$path"; then
            if [[ "$RPM_OWNER" == "$expected_owner" ]]; then
                return 0
            fi
            error "Unexpected RPM owner for $path: $RPM_OWNER (expected $expected_owner)"
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

validate_rpm_lock_path() {
    if [[ ! "$RPM_LOCK_PATH" =~ ^/[A-Za-z0-9/._+-]+$ ]]; then
        error "RPM transaction lock path is unsafe"
        return 1
    fi
}

acquire_rpm_read_lock() {
    local metadata writable lock_parent path_identity fd_identity
    local parent_parent current_component

    validate_rpm_lock_path || return 1
    lock_parent="${RPM_LOCK_PATH%/*}"
    if [[ ! -d "$lock_parent" || -L "$lock_parent" ]]; then
        error "RPM transaction lock parent is unsafe: $lock_parent"
        return 1
    fi
    parent_parent="${lock_parent%/*}"
    current_component="${parent_parent}/${lock_parent##*/}"
    if [[ ! -d "$parent_parent" || -L "$parent_parent" \
        || ! -d "$current_component" || -L "$current_component" ]]; then
        error "RPM transaction lock ancestry is unsafe"
        return 1
    fi
    metadata="$(stat -Lc '%u:%g' -- "$lock_parent")"
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" ]]; then
        error "RPM transaction lock parent has unsafe ownership: $lock_parent ($metadata)"
        return 1
    fi
    writable="$(find "$lock_parent" -maxdepth 0 -perm /022 -print -quit)"
    if [[ -n "$writable" ]]; then
        error "RPM transaction lock parent is writable by group or others: $lock_parent"
        return 1
    fi
    if [[ ! -f "$RPM_LOCK_PATH" || -L "$RPM_LOCK_PATH" ]]; then
        error "RPM transaction lock is not a regular file: $RPM_LOCK_PATH"
        return 1
    fi
    metadata="$(stat -Lc '%u:%g' -- "$RPM_LOCK_PATH")"
    if [[ "$metadata" != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" ]]; then
        error "RPM transaction lock has unsafe ownership: $RPM_LOCK_PATH ($metadata)"
        return 1
    fi
    writable="$(find "$RPM_LOCK_PATH" -maxdepth 0 -perm /022 -print -quit)"
    if [[ -n "$writable" ]]; then
        error "RPM transaction lock is writable by group or others: $RPM_LOCK_PATH"
        return 1
    fi

    path_identity="$(stat -Lc '%d:%i' -- "$RPM_LOCK_PATH")"
    if ! exec {RPM_LOCK_FD}<"$RPM_LOCK_PATH"; then
        error "Could not open the RPM transaction lock"
        return 1
    fi
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${RPM_LOCK_FD}")"
    if [[ "$fd_identity" != "$path_identity" ]]; then
        error "Opened RPM lock does not match the validated path"
        return 1
    fi
    if ! "$FLOCK_COMMAND" --fcntl --shared \
        --timeout "$RPM_LOCK_TIMEOUT_SECONDS" "$RPM_LOCK_FD"; then
        error "Timed out waiting for the RPM transaction read lock"
        return 1
    fi
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${RPM_LOCK_FD}")"
    path_identity="$(stat -Lc '%d:%i' -- "$RPM_LOCK_PATH")"
    if [[ "$fd_identity" != "$path_identity" ]]; then
        error "RPM lock path changed while acquiring the read lock"
        return 1
    fi
}

finalize_kernel() (
    local kernel="$1"
    local expected_owner expected_dir lock_file lock_fd module_name payload
    local legacy_path extension state resolved_path marker identity current_identity
    local -a modules=("$CORE_MODULE" "$I2C_MODULE")
    local -a legacy_to_remove=()
    local -a markers=()
    declare -A payloads=()
    declare -A marker_identities=()

    validate_kernel_name "$kernel" || return 1
    if [[ ! -d "${MODULE_ROOT}/${kernel}" ]]; then
        error "Kernel module directory not found: ${MODULE_ROOT}/${kernel}"
        return 1
    fi

    if [[ ! -d "${LOCK_ROOT%/*}" || -L "${LOCK_ROOT%/*}" ]]; then
        error "Private lock parent is unavailable or unsafe: ${LOCK_ROOT%/*}"
        return 1
    fi
    if [[ -L "$LOCK_ROOT" || ( -e "$LOCK_ROOT" && ! -d "$LOCK_ROOT" ) ]]; then
        error "Refusing unsafe lock directory: $LOCK_ROOT"
        return 1
    fi
    install -d -m 0700 -- "$LOCK_ROOT"
    if [[ "$(stat -Lc '%u:%g:%a' -- "$LOCK_ROOT")" \
        != "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}:700" ]]; then
        error "Private lock directory has unsafe ownership or mode: $LOCK_ROOT"
        return 1
    fi
    lock_file="${LOCK_ROOT}/galaxybook-max98390-${kernel}.lock"
    if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]; then
        error "Refusing unsafe finalization lock: $lock_file"
        return 1
    fi
    if ! exec {lock_fd}>>"$lock_file"; then
        error "Could not open finalization lock for $kernel"
        return 1
    fi
    if ! chown "${EXPECTED_STATE_UID}:${EXPECTED_STATE_GID}" -- "$lock_file" \
        || ! chmod 0600 -- "$lock_file"; then
        error "Could not secure finalization lock for $kernel"
        return 1
    fi
    if ! "$FLOCK_COMMAND" -x "$lock_fd"; then
        error "Could not acquire finalization lock for $kernel"
        return 1
    fi
    acquire_rpm_read_lock || return 1

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
    expected_dir="${MODULE_ROOT}/${kernel}/extra/galaxybook-max98390/sound/hda/codecs/side-codecs"

    # Validate the complete replacement set before querying or removing any
    # historical override. Validation is exact for package owner and vermagic.
    for module_name in "${modules[@]}"; do
        payload="$(find_module_payload "$expected_dir" "$module_name")" || return 1
        payloads["$module_name"]="$payload"
    done
    for module_name in "${modules[@]}"; do
        payload="${payloads[$module_name]}"
        wait_for_expected_owner "$payload" "$expected_owner" || return 1
        validate_payload_vermagic "$kernel" "$payload" || return 1
    done

    # Resolve ownership for every legacy candidate before deleting the first
    # one, so an RPM database error cannot result in a partial cleanup.
    for module_name in "${modules[@]}"; do
        for extension in ko ko.xz ko.zst ko.gz; do
            legacy_path="${MODULE_ROOT}/${kernel}/updates/sound/hda/codecs/side-codecs/${module_name}.${extension}"
            [[ -e "$legacy_path" || -L "$legacy_path" ]] || continue

            if rpm_owner_state "$legacy_path"; then
                log "Preserving RPM-owned legacy path $legacy_path ($RPM_OWNER)"
                continue
            else
                state=$?
            fi

            if (( state == 1 )); then
                legacy_to_remove+=("$legacy_path")
            else
                error "Could not safely determine RPM ownership of $legacy_path"
                return 1
            fi
        done
    done

    for legacy_path in "${legacy_to_remove[@]}"; do
        log "Removing unmanaged legacy override $legacy_path"
        rm -f -- "$legacy_path"
    done

    if ! "$DEPMOD_COMMAND" -a "$kernel"; then
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
