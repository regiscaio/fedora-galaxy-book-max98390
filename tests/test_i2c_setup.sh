#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/max98390-hda-i2c-setup.sh"
UNIT="$REPO_ROOT/data/systemd/max98390-hda-i2c-setup.service"
FIXTURE_BIN="$TEST_DIR/fixtures/bin"

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"

cleanup_fixture() {
    [[ -n "${TEST_TMPDIR:-}" ]] || return 0
    case "$TEST_TMPDIR" in
        "${TMPDIR:-/tmp}"/max98390-tests.*)
            rm -rf -- "$TEST_TMPDIR"
            ;;
        *)
            printf 'refusing to remove unexpected fixture path: %s\n' "$TEST_TMPDIR" >&2
            ;;
    esac
}

new_fixture() {
    local bus="${1:-2}"
    local acpi_id="${2:-MAX98390}"
    local acpi_device physical_client driver_dir

    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/max98390-tests.XXXXXX")"
    trap cleanup_fixture EXIT

    export FAKE_STATE_DIR="$TEST_TMPDIR/fake-state"
    export MAX98390_SYSFS_ROOT="$TEST_TMPDIR/sys"
    export MAX98390_STATE_DIR="$TEST_TMPDIR/run/galaxybook-max98390"
    export MAX98390_I2CGET="$FIXTURE_BIN/i2cget"
    export MAX98390_MODPROBE="$FIXTURE_BIN/modprobe"
    export MAX98390_SLEEP="$FIXTURE_BIN/sleep"
    export MAX98390_SYSFS_WRITE="$FIXTURE_BIN/sysfs-write"
    export MAX98390_MAX_ATTEMPTS=3
    export MAX98390_RETRY_DELAY_SECONDS=0
    unset FAKE_BIND_FAIL_IDS FAKE_DELETE_FAIL_ADDRS FAKE_MODPROBE_FAIL_MODULES
    unset FAKE_WRITE_FAIL_ADDRS FAKE_UNBOUND_ADDRS

    mkdir -p -- \
        "$FAKE_STATE_DIR" \
        "$MAX98390_STATE_DIR" \
        "$MAX98390_SYSFS_ROOT/bus/i2c/devices/i2c-$bus" \
        "$MAX98390_SYSFS_ROOT/bus/i2c/drivers/max98390-hda" \
        "$MAX98390_SYSFS_ROOT/devices/platform/mock-controller/i2c-$bus/i2c-${acpi_id}:00"
    : > "$FAKE_STATE_DIR/commands.log"
    : > "$FAKE_STATE_DIR/i2c-responses"
    : > "$MAX98390_SYSFS_ROOT/bus/i2c/devices/i2c-$bus/new_device"
    : > "$MAX98390_SYSFS_ROOT/bus/i2c/devices/i2c-$bus/delete_device"
    : > "$MAX98390_SYSFS_ROOT/bus/i2c/drivers/max98390-hda/bind"

    physical_client="$MAX98390_SYSFS_ROOT/devices/platform/mock-controller/i2c-$bus/i2c-${acpi_id}:00"
    acpi_device="$MAX98390_SYSFS_ROOT/bus/i2c/devices/i2c-${acpi_id}:00"
    driver_dir="$MAX98390_SYSFS_ROOT/bus/i2c/drivers/max98390-hda"

    printf 'max98390-hda\n' > "$physical_client/name"
    printf 'i2c:max98390-hda\n' > "$physical_client/modalias"
    ln -s -- "$driver_dir" "$physical_client/driver"
    ln -s -- "$physical_client" "$acpi_device"

    FIXTURE_BUS="$bus"
    ACPI_CLIENT_PATH="$acpi_device"
    ACPI_DEVICE_ID="i2c-${acpi_id}:00"
    COMMAND_LOG="$FAKE_STATE_DIR/commands.log"
}

configure_i2c_response() {
    local address="$1"
    local successful_attempt="$2"

    printf '%s %s\n' "$address" "$successful_attempt" >> "$FAKE_STATE_DIR/i2c-responses"
}

make_bound_client() {
    local address="$1"
    local device="$MAX98390_SYSFS_ROOT/bus/i2c/devices/${FIXTURE_BUS}-00${address#0x}"

    mkdir -p -- "$device"
    printf 'max98390-hda\n' > "$device/name"
    printf 'i2c:max98390-hda\n' > "$device/modalias"
    ln -s -- \
        "$MAX98390_SYSFS_ROOT/bus/i2c/drivers/max98390-hda" \
        "$device/driver"
}

client_path() {
    local address="$1"

    if [[ "$address" == 0x38 ]]; then
        printf '%s\n' "$ACPI_CLIENT_PATH"
        return
    fi
    printf '%s\n' "$MAX98390_SYSFS_ROOT/bus/i2c/devices/${FIXTURE_BUS}-00${address#0x}"
}

assert_bound() {
    local address="$1"
    local device driver_basename

    device="$(client_path "$address")"
    [[ -e "$device" || -L "$device" ]] || fail "client $address was not created"
    [[ -L "$device/driver" ]] || fail "client $address is not bound"
    driver_basename="$(basename -- "$(readlink -f -- "$device/driver")")"
    assert_eq 'max98390-hda' "$driver_basename" "client $address bound to wrong driver"
}

run_helper() {
    local action="${1:-start}"

    set +e
    HELPER_OUTPUT="$("$HELPER" "$action" 2>&1)"
    HELPER_STATUS=$?
    set -e
}

test_unit_skips_hosts_without_max98390_acpi() {
    assert_file_contains_fixed "$UNIT" \
        'ConditionPathExistsGlob=/sys/bus/acpi/devices/M*X98390:*' \
        'systemd unit would run on a host without MAX98390 ACPI hardware'
}

test_mx98390_acpi_alias_is_supported() {
    local address

    new_fixture 2 MX98390
    for address in 0x39 0x3c 0x3d; do
        configure_i2c_response "$address" 1
    done

    run_helper start

    assert_eq 0 "$HELPER_STATUS" "helper rejected the supported MX98390 ACPI alias: $HELPER_OUTPUT"
    assert_bound 0x38
}

test_retry_creates_and_binds_four_amplifiers() {
    local address

    new_fixture
    for address in 0x39 0x3c 0x3d; do
        configure_i2c_response "$address" 2
    done

    run_helper start

    assert_eq 0 "$HELPER_STATUS" "helper failed after a recoverable probe miss: $HELPER_OUTPUT"
    for address in 0x38 0x39 0x3c 0x3d; do
        assert_bound "$address"
    done
    assert_prefix_count "$COMMAND_LOG" 'write|new_device|max98390-hda ' 3 \
        'helper did not create exactly the three non-ACPI clients'
    assert_prefix_min_count "$COMMAND_LOG" 'sleep|' 1 'helper did not retry'
    assert_file_contains_fixed "$COMMAND_LOG" 'modprobe|snd-hda-scodec-max98390' \
        'core side-codec module was not requested'
    assert_file_contains_fixed "$COMMAND_LOG" 'modprobe|snd-hda-scodec-max98390-i2c' \
        'I2C side-codec module was not requested'
}

test_existing_clients_are_validated_without_recreation() {
    local address

    new_fixture
    for address in 0x39 0x3c 0x3d; do
        make_bound_client "$address"
    done

    run_helper start

    assert_eq 0 "$HELPER_STATUS" "helper rejected already-bound clients: $HELPER_OUTPUT"
    for address in 0x38 0x39 0x3c 0x3d; do
        assert_bound "$address"
    done
    assert_prefix_count "$COMMAND_LOG" 'write|new_device|' 0 \
        'helper attempted to recreate an existing client'
}

test_new_device_failure_is_fatal() {
    local address

    new_fixture
    for address in 0x39 0x3c 0x3d; do
        configure_i2c_response "$address" 1
    done
    export FAKE_WRITE_FAIL_ADDRS='0x3c'
    export MAX98390_MAX_ATTEMPTS=2

    run_helper start

    [[ "$HELPER_STATUS" -ne 0 ]] || fail 'new_device failure was incorrectly reported as success'
    assert_prefix_min_count "$COMMAND_LOG" 'write|new_device|max98390-hda 0x3c' 1 \
        'failing new_device write was not attempted'
    assert_path_missing "$(client_path 0x3c)" 'failed new_device write unexpectedly created a client'
}

test_stable_partial_topology_is_rejected() {
    new_fixture
    configure_i2c_response 0x39 1
    configure_i2c_response 0x3c 1
    export MAX98390_MAX_ATTEMPTS=2

    run_helper start

    [[ "$HELPER_STATUS" -ne 0 ]] || fail 'stable partial amplifier topology was reported as ready'
    assert_path_missing "$(client_path 0x3d)" 'missing amplifier unexpectedly appeared'
}

test_unbound_client_fails_postcondition_validation() {
    local address

    new_fixture
    for address in 0x39 0x3c 0x3d; do
        configure_i2c_response "$address" 1
    done
    export FAKE_UNBOUND_ADDRS='0x3c'
    export FAKE_BIND_FAIL_IDS="${FIXTURE_BUS}-003c"
    export MAX98390_MAX_ATTEMPTS=2

    run_helper start

    [[ "$HELPER_STATUS" -ne 0 ]] || fail 'unbound client was incorrectly reported as ready'
    assert_prefix_min_count "$COMMAND_LOG" 'write|new_device|max98390-hda 0x3c' 1 \
        'writer did not create the unbound validation fixture'
    assert_prefix_min_count "$COMMAND_LOG" 'sleep|' 1 \
        'binding validation did not perform a bounded retry'
}

test_explicit_bind_recovers_transient_probe_failure() {
    local address

    new_fixture
    for address in 0x39 0x3c 0x3d; do
        configure_i2c_response "$address" 1
    done
    export FAKE_UNBOUND_ADDRS='0x3c'

    run_helper start

    assert_eq 0 "$HELPER_STATUS" "explicit bind did not recover the unbound client: $HELPER_OUTPUT"
    assert_bound 0x3c
    assert_file_contains_fixed "$COMMAND_LOG" "write|bind|${FIXTURE_BUS}-003c" \
        'helper did not explicitly retry the failed driver probe'
}

test_explicit_bind_recovers_acpi_client() {
    local address

    new_fixture
    for address in 0x39 0x3c 0x3d; do
        configure_i2c_response "$address" 1
    done
    rm -f "$ACPI_CLIENT_PATH/driver"

    run_helper start

    assert_eq 0 "$HELPER_STATUS" "explicit bind did not recover the ACPI client: $HELPER_OUTPUT"
    assert_bound 0x38
    assert_file_contains_fixed "$COMMAND_LOG" "write|bind|$ACPI_DEVICE_ID" \
        'helper did not explicitly retry the ACPI client probe'
}

test_stop_removes_only_clients_created_by_helper() {
    new_fixture
    make_bound_client 0x39
    configure_i2c_response 0x3c 1
    configure_i2c_response 0x3d 1

    run_helper start
    assert_eq 0 "$HELPER_STATUS" "helper could not establish ownership fixture: $HELPER_OUTPUT"
    assert_bound 0x39
    assert_bound 0x3c
    assert_bound 0x3d

    run_helper stop
    assert_eq 0 "$HELPER_STATUS" "helper stop failed: $HELPER_OUTPUT"
    assert_bound 0x39
    assert_path_missing "$(client_path 0x3c)" 'helper-owned client 0x3c was not removed'
    assert_path_missing "$(client_path 0x3d)" 'helper-owned client 0x3d was not removed'
    assert_file_not_contains_fixed "$COMMAND_LOG" 'write|delete_device|0x39' \
        'helper removed a pre-existing client it did not own'
}

test_stop_preserves_ownership_after_delete_failure() {
    new_fixture
    configure_i2c_response 0x39 1
    configure_i2c_response 0x3c 1
    configure_i2c_response 0x3d 1

    run_helper start
    assert_eq 0 "$HELPER_STATUS" "helper could not establish delete retry fixture: $HELPER_OUTPUT"

    export FAKE_DELETE_FAIL_ADDRS='0x3c'
    run_helper stop
    [[ "$HELPER_STATUS" -ne 0 ]] || fail 'delete_device failure was incorrectly reported as success'
    assert_bound 0x3c
    assert_path_missing "$(client_path 0x3d)" 'successfully deleted client remained present'
    assert_file_contains_fixed "$MAX98390_STATE_DIR/created-i2c-devices" "${FIXTURE_BUS} 0x3c" \
        'failed delete lost its ownership record'
    assert_file_not_contains_fixed "$MAX98390_STATE_DIR/created-i2c-devices" "${FIXTURE_BUS} 0x3d" \
        'successfully deleted client remained in the ownership record'

    unset FAKE_DELETE_FAIL_ADDRS
    run_helper stop
    assert_eq 0 "$HELPER_STATUS" "second stop did not retry the retained client: $HELPER_OUTPUT"
    assert_path_missing "$(client_path 0x3c)" 'retained client was not removed on retry'
    assert_path_missing "$MAX98390_STATE_DIR/created-i2c-devices" \
        'ownership state remained after all clients were removed'
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    unit_skips_hosts_without_max98390_acpi \
    mx98390_acpi_alias_is_supported \
    retry_creates_and_binds_four_amplifiers \
    existing_clients_are_validated_without_recreation \
    new_device_failure_is_fatal \
    stable_partial_topology_is_rejected \
    unbound_client_fails_postcondition_validation \
    explicit_bind_recovers_transient_probe_failure \
    explicit_bind_recovers_acpi_client \
    stop_removes_only_clients_created_by_helper \
    stop_preserves_ownership_after_delete_failure
