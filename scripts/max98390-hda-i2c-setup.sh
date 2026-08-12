#!/usr/bin/bash

set -euo pipefail

# Discover the MAX98390 I2C adapter, instantiate the amplifiers which ACPI did
# not create, and verify that every discovered client is bound to our driver.
#
# The MAX98390_* overrides make the hardware-facing operations testable against
# a synthetic sysfs tree. Production uses the defaults below.

ACTION="${1:-start}"
SYSFS_ROOT="${MAX98390_SYSFS_ROOT:-/sys}"
I2CGET="${MAX98390_I2CGET:-i2cget}"
MODPROBE="${MAX98390_MODPROBE:-modprobe}"
SLEEP="${MAX98390_SLEEP:-sleep}"
SYSFS_WRITE="${MAX98390_SYSFS_WRITE:-}"
STATE_DIR="${MAX98390_STATE_DIR:-/run/galaxybook-max98390}"
MAX_ATTEMPTS="${MAX98390_MAX_ATTEMPTS:-10}"
RETRY_DELAY_SECONDS="${MAX98390_RETRY_DELAY_SECONDS:-1}"

I2C_DEVICES="${SYSFS_ROOT}/bus/i2c/devices"
I2C_DRIVER="${SYSFS_ROOT}/bus/i2c/drivers/max98390-hda"
CREATED_DEVICES_FILE="${STATE_DIR}/created-i2c-devices"
ALL_ADDRS=(0x39 0x3c 0x3d)
EXPECTED_DRIVER="max98390-hda"

log() {
    printf 'max98390-hda: %s\n' "$*"
}

error() {
    printf 'max98390-hda: %s\n' "$*" >&2
}

validate_configuration() {
    if ! [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
        error "MAX98390_MAX_ATTEMPTS must be a positive integer"
        return 2
    fi

    if ! [[ "$RETRY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "MAX98390_RETRY_DELAY_SECONDS must be a non-negative number"
        return 2
    fi
}

write_sysfs() {
    local path="$1"
    local value="$2"

    if [[ -n "$SYSFS_WRITE" ]]; then
        "$SYSFS_WRITE" "$path" "$value"
    else
        printf '%s\n' "$value" > "$path"
    fi
}

device_path_for_addr() {
    local bus="$1"
    local addr="$2"

    printf '%s/%s-00%s\n' "$I2C_DEVICES" "$bus" "${addr#0x}"
}

device_is_bound() {
    local device_path="$1"
    local driver_path

    [[ -L "$device_path/driver" ]] || return 1
    driver_path="$(readlink -f "$device_path/driver")"
    [[ "${driver_path##*/}" == "$EXPECTED_DRIVER" ]]
}

find_acpi_device() {
    local device

    for device in "$I2C_DEVICES"/*M*X98390*; do
        [[ -e "$device" ]] || continue
        printf '%s\n' "$device"
        return 0
    done

    return 1
}

find_i2c_bus() {
    local device dev_path parent_name bus_num acpi

    while IFS= read -r device; do
        dev_path="$(readlink -f "$device")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(sed -n 's/^i2c-\([0-9]\+\)$/\1/p' <<< "$parent_name")"
        if [[ -n "$bus_num" ]]; then
            printf '%s\n' "$bus_num"
            return 0
        fi

        bus_num="$(sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p' <<< "$dev_path")"
        if [[ -n "$bus_num" ]]; then
            printf '%s\n' "$bus_num"
            return 0
        fi
    done < <(find_acpi_device || true)

    for acpi in "$SYSFS_ROOT"/bus/acpi/devices/M*X98390:*; do
        [[ -e "$acpi/physical_node" ]] || continue
        dev_path="$(readlink -f "$acpi/physical_node")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(sed -n 's/^i2c-\([0-9]\+\)$/\1/p' <<< "$parent_name")"
        if [[ -n "$bus_num" ]]; then
            printf '%s\n' "$bus_num"
            return 0
        fi

        bus_num="$(sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p' <<< "$dev_path")"
        if [[ -n "$bus_num" ]]; then
            printf '%s\n' "$bus_num"
            return 0
        fi
    done

    return 1
}

record_created_device() {
    local bus="$1"
    local addr="$2"

    mkdir -p "$STATE_DIR"
    printf '%s %s\n' "$bus" "$addr" >> "$CREATED_DEVICES_FILE"
}

create_device() {
    local bus="$1"
    local addr="$2"
    local adapter="$I2C_DEVICES/i2c-${bus}"
    local device_path

    device_path="$(device_path_for_addr "$bus" "$addr")"
    [[ -e "$device_path" ]] && return 0

    if ! write_sysfs "$adapter/new_device" "max98390-hda $addr"; then
        # Another actor may have won the check/create race. Only accept the
        # failed write if the requested client now exists.
        if [[ -e "$device_path" ]]; then
            log "I2C client $bus-$addr appeared concurrently" >&2
            return 0
        fi

        error "Failed to instantiate MAX98390 at $addr on I2C bus $bus"
        return 1
    fi

    if [[ ! -e "$device_path" ]]; then
        error "new_device accepted $addr on bus $bus but no client appeared"
        return 1
    fi

    if ! record_created_device "$bus" "$addr"; then
        error "Failed to record ownership of MAX98390 at $addr on I2C bus $bus"
        if ! write_sysfs "$adapter/delete_device" "$addr"; then
            error "Failed to roll back untracked MAX98390 at $addr on I2C bus $bus"
        fi
        return 1
    fi
    return 0
}

discover_additional_devices() {
    local bus="$1"
    local addr device_path
    local -a discovered=()
    local status=0

    for addr in "${ALL_ADDRS[@]}"; do
        device_path="$(device_path_for_addr "$bus" "$addr")"
        if [[ -e "$device_path" ]]; then
            discovered+=("$addr")
            continue
        fi

        if "$I2CGET" -y "$bus" "$addr" 0x00 b >/dev/null 2>&1; then
            if create_device "$bus" "$addr"; then
                discovered+=("$addr")
            else
                status=1
            fi
        fi
    done

    printf '%s\n' "${discovered[*]}"
    return "$status"
}

validate_bindings() {
    local acpi_device="$1"
    local bus="$2"
    shift 2
    local addr device_path

    if ! device_is_bound "$acpi_device"; then
        error "ACPI MAX98390 client is not bound to $EXPECTED_DRIVER"
        return 1
    fi

    for addr in "$@"; do
        device_path="$(device_path_for_addr "$bus" "$addr")"
        if ! device_is_bound "$device_path"; then
            error "MAX98390 client at $addr on bus $bus is not bound to $EXPECTED_DRIVER"
            return 1
        fi
    done

    return 0
}

retry_device_binding() {
    local device_path="$1"
    local resolved_path device_id

    resolved_path="$(readlink -f "$device_path")"
    device_id="${resolved_path##*/}"
    if ! [[ "$device_id" =~ ^[0-9]+-[[:xdigit:]]{4}$ ||
            "$device_id" =~ ^i2c-MA?X98390:[[:xdigit:]]{2}$ ]]; then
        error "Cannot derive an I2C device ID from $device_path"
        return 1
    fi

    log "Retrying $EXPECTED_DRIVER binding for I2C client $device_id"
    if write_sysfs "$I2C_DRIVER/bind" "$device_id"; then
        return 0
    fi

    # A successful asynchronous probe may race with the explicit bind.
    if device_is_bound "$device_path"; then
        return 0
    fi

    error "Failed to bind I2C client $device_id to $EXPECTED_DRIVER"
    return 1
}

retry_unbound_devices() {
    local acpi_device="$1"
    local bus="$2"
    shift 2
    local addr device_path
    local status=0

    if ! device_is_bound "$acpi_device"; then
        retry_device_binding "$acpi_device" || status=1
    fi

    for addr in "$@"; do
        device_path="$(device_path_for_addr "$bus" "$addr")"
        if ! device_is_bound "$device_path"; then
            retry_device_binding "$device_path" || status=1
        fi
    done

    return "$status"
}

remove_created_devices() {
    local bus addr adapter device_path remaining_file
    local status=0

    [[ -f "$CREATED_DEVICES_FILE" ]] || return 0
    if ! remaining_file="$(mktemp "$STATE_DIR/.created-i2c-devices.XXXXXX")"; then
        error "Failed to create temporary MAX98390 ownership state"
        return 1
    fi

    while read -r bus addr; do
        [[ -n "${bus:-}" && -n "${addr:-}" ]] || continue
        adapter="$I2C_DEVICES/i2c-${bus}"
        device_path="$(device_path_for_addr "$bus" "$addr")"
        [[ -e "$device_path" ]] || continue

        if ! write_sysfs "$adapter/delete_device" "$addr"; then
            error "Failed to remove MAX98390 at $addr from I2C bus $bus"
            if ! printf '%s %s\n' "$bus" "$addr" >> "$remaining_file"; then
                error "Failed to preserve MAX98390 ownership state"
                rm -f "$remaining_file"
                return 1
            fi
            status=1
        fi
    done < "$CREATED_DEVICES_FILE"

    if [[ -s "$remaining_file" ]]; then
        if ! mv -f "$remaining_file" "$CREATED_DEVICES_FILE"; then
            error "Failed to replace MAX98390 ownership state"
            rm -f "$remaining_file"
            return 1
        fi
    else
        if ! rm -f "$remaining_file" "$CREATED_DEVICES_FILE"; then
            error "Failed to remove empty MAX98390 ownership state"
            return 1
        fi
    fi
    return "$status"
}

start_devices() {
    local attempt bus acpi_device discovered_text signature last_signature=""
    local stable_scans=0
    local -a discovered=()

    mkdir -p "$STATE_DIR"
    : > "$CREATED_DEVICES_FILE"

    "$MODPROBE" snd-hda-scodec-max98390
    "$MODPROBE" snd-hda-scodec-max98390-i2c

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        bus="$(find_i2c_bus || true)"
        acpi_device="$(find_acpi_device || true)"
        if [[ -z "$bus" || -z "$acpi_device" ]]; then
            log "Waiting for MAX98390 ACPI/I2C device (attempt $attempt/$MAX_ATTEMPTS)"
            "$SLEEP" "$RETRY_DELAY_SECONDS"
            continue
        fi

        if [[ ! -d "$I2C_DRIVER" ]]; then
            log "Waiting for the $EXPECTED_DRIVER I2C driver (attempt $attempt/$MAX_ATTEMPTS)"
            "$SLEEP" "$RETRY_DELAY_SECONDS"
            continue
        fi

        if ! discovered_text="$(discover_additional_devices "$bus")"; then
            stable_scans=0
            "$SLEEP" "$RETRY_DELAY_SECONDS"
            continue
        fi
        read -r -a discovered <<< "$discovered_text"
        if (( ${#discovered[@]} != ${#ALL_ADDRS[@]} )); then
            log "Waiting for all ${#ALL_ADDRS[@]} additional MAX98390 amplifiers on bus $bus (found ${#discovered[@]}, attempt $attempt/$MAX_ATTEMPTS)"
            last_signature=""
            stable_scans=0
            "$SLEEP" "$RETRY_DELAY_SECONDS"
            continue
        fi

        if ! validate_bindings "$acpi_device" "$bus" "${discovered[@]}"; then
            stable_scans=0
            retry_unbound_devices "$acpi_device" "$bus" "${discovered[@]}" || true
            if ! validate_bindings "$acpi_device" "$bus" "${discovered[@]}"; then
                "$SLEEP" "$RETRY_DELAY_SECONDS"
                continue
            fi
        fi

        signature="${discovered[*]}"
        if [[ "$signature" == "$last_signature" ]]; then
            stable_scans=$((stable_scans + 1))
        else
            last_signature="$signature"
            stable_scans=1
        fi

        # Two identical, fully-bound scans avoid declaring success while the
        # remaining amplifiers are still waking up on the I2C bus.
        if (( stable_scans >= 2 )); then
            log "Validated ACPI amplifier and ${#discovered[@]} additional amplifier(s) on bus $bus: $signature"
            return 0
        fi

        "$SLEEP" "$RETRY_DELAY_SECONDS"
    done

    error "MAX98390 devices did not become ready after $MAX_ATTEMPTS attempts"
    return 1
}

validate_configuration

case "$ACTION" in
    start)
        trap 'status=$?; if (( status != 0 )); then remove_created_devices || true; fi' EXIT
        start_devices
        trap - EXIT
        ;;
    stop)
        remove_created_devices
        ;;
    *)
        error "Unsupported action: $ACTION"
        exit 2
        ;;
esac
