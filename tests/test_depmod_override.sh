#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
DEPMOD_CONFIG="$REPO_ROOT/data/depmod.d/galaxybook-max98390.conf"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/max98390-depmod-override-tests.XXXXXX")"
KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"
CORE_FIXTURE="${MAX98390_CORE_FIXTURE:-}"
I2C_FIXTURE="${MAX98390_I2C_FIXTURE:-}"

# shellcheck source=lib/harness.sh
source "$TEST_DIR/lib/harness.sh"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/max98390-depmod-override-tests.*)
            rm -rf -- "$TEST_ROOT"
            ;;
        *)
            printf 'refusing to remove unexpected fixture path: %s\n' "$TEST_ROOT" >&2
            ;;
    esac
}
trap cleanup EXIT

test_exact_overrides_preserve_legacy_and_retain_fallback() {
    local module source_path basename suffix resolved expected
    local module_root="$TEST_ROOT/lib/modules/$KERNEL_VERSION"
    local legacy_dir="$module_root/updates/sound/hda/codecs/side-codecs"
    local extra_dir="$module_root/extra/galaxybook-max98390/sound/hda/codecs/side-codecs"
    local before_hashes="$TEST_ROOT/legacy.before"
    local after_hashes="$TEST_ROOT/legacy.after"
    local -a modules=(snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c)
    declare -A legacy_path=()
    declare -A extra_path=()

    command -v depmod >/dev/null 2>&1 || skip 'depmod is not installed'
    command -v modinfo >/dev/null 2>&1 || skip 'modinfo is not installed'
    [[ "$KERNEL_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || \
        fail "unsafe KERNEL_VERSION: $KERNEL_VERSION"

    mkdir -p -- "$legacy_dir" "$extra_dir"
    : > "$module_root/modules.order"
    : > "$module_root/modules.builtin"
    : > "$module_root/modules.builtin.modinfo"

    for module in "${modules[@]}"; do
        case "$module" in
            snd-hda-scodec-max98390) source_path="$CORE_FIXTURE" ;;
            snd-hda-scodec-max98390-i2c) source_path="$I2C_FIXTURE" ;;
        esac
        if [[ -z "$source_path" ]] \
            && ! source_path="$(modinfo -k "$KERNEL_VERSION" -n "$module" 2>/dev/null)"; then
            skip "provide a $module fixture payload or install it for host kernel $KERNEL_VERSION"
        fi
        [[ -f "$source_path" && ! -L "$source_path" ]] || \
            skip "host fixture payload is not a regular file: $source_path"
        basename="${source_path##*/}"
        case "$basename" in
            "$module.ko"|"$module.ko.xz"|"$module.ko.zst"|"$module.ko.gz")
                suffix="${basename#"$module"}"
                ;;
            *)
                fail "unexpected module payload name: $basename"
                ;;
        esac
        legacy_path["$module"]="$legacy_dir/${module}${suffix}"
        extra_path["$module"]="$extra_dir/${module}${suffix}"
        install -m 0644 -- "$source_path" "${legacy_path[$module]}"
        install -m 0644 -- "$source_path" "${extra_path[$module]}"
    done

    sha256sum "${legacy_path[@]}" > "$before_hashes"
    depmod -b "$TEST_ROOT" -C "$DEPMOD_CONFIG" -a "$KERNEL_VERSION" \
        2> "$TEST_ROOT/depmod-with-extra.stderr"
    for module in "${modules[@]}"; do
        resolved="$(modinfo -b "$TEST_ROOT" -k "$KERNEL_VERSION" -n "$module")"
        expected="${extra_path[$module]}"
        assert_eq "$expected" "$resolved" \
            "depmod did not prioritize the RPM-owned $module payload"
    done

    for module in "${modules[@]}"; do
        rm -f -- "${extra_path[$module]}"
    done
    depmod -b "$TEST_ROOT" -C "$DEPMOD_CONFIG" -a "$KERNEL_VERSION" \
        2> "$TEST_ROOT/depmod-without-extra.stderr"
    for module in "${modules[@]}"; do
        resolved="$(modinfo -b "$TEST_ROOT" -k "$KERNEL_VERSION" -n "$module")"
        expected="${legacy_path[$module]}"
        assert_eq "$expected" "$resolved" \
            "depmod did not retain the preserved $module fallback"
    done

    sha256sum "${legacy_path[@]}" > "$after_hashes"
    cmp -s "$before_hashes" "$after_hashes" || \
        fail 'legacy module content changed while applying depmod priority'
}

run_test_cases \
    "$0" \
    "${1:-}" \
    "${2:-}" \
    exact_overrides_preserve_legacy_and_retain_fallback
