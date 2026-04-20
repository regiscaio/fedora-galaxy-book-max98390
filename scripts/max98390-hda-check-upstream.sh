#!/bin/bash
set -euo pipefail

# Check if the running kernel has native MAX98390 HDA support. In the RPM flow
# we do not mutate the installation automatically from a systemd service; the
# goal is only to surface when the workaround may no longer be needed.

UPSTREAM_READY=true

log() { echo "max98390-hda-check: $*"; }

read_module_strings() {
    case "$1" in
        *.xz) xzcat "$1" ;;
        *.gz) gzip -dc "$1" ;;
        *.zst) zstdcat "$1" ;;
        *) cat "$1" ;;
    esac
}

# Check 1: Does serial-multi-instantiate know about MAX98390?
SMI_MODULE=$(find "/lib/modules/$(uname -r)/kernel/drivers/platform/x86" -name "serial-multi-instantiate*" 2>/dev/null | head -1)
if [ -n "$SMI_MODULE" ]; then
    if ! modinfo "$SMI_MODULE" 2>/dev/null | grep -q "alias.*MAX98390"; then
        UPSTREAM_READY=false
        log "serial-multi-instantiate: missing MAX98390 support"
    fi
else
    UPSTREAM_READY=false
    log "serial-multi-instantiate: module not found"
fi

# Check 2: Does snd_hda_codec_alc269 have the max98390 fixup?
ALC_MODULE=$(find "/lib/modules/$(uname -r)/kernel/sound" -name "snd-hda-codec-alc269*" 2>/dev/null | head -1)
if [ -n "$ALC_MODULE" ]; then
    if ! read_module_strings "$ALC_MODULE" 2>/dev/null | strings | grep -q "alc298-samsung-max98390"; then
        UPSTREAM_READY=false
        log "snd_hda_codec_alc269: missing MAX98390 quirk entries"
    fi
else
    UPSTREAM_READY=false
    log "snd_hda_codec_alc269: module not found"
fi

# Check 3: Is there a native snd-hda-scodec-max98390 in the kernel tree?
NATIVE_MODULE=$(find "/lib/modules/$(uname -r)/kernel/sound" -name "snd-hda-scodec-max98390*" 2>/dev/null | head -1)
if [ -z "$NATIVE_MODULE" ]; then
    UPSTREAM_READY=false
    log "snd-hda-scodec-max98390: not in kernel tree"
fi

if ! $UPSTREAM_READY; then
    log "upstream not available yet in $(uname -r) — akmod workaround still needed"
    exit 0
fi

log "=== NATIVE SUPPORT DETECTED in $(uname -r) ==="
log "The external MAX98390 package may no longer be needed on this kernel."
log "If speakers already work without the override, consider removing:"
log "  sudo dnf remove akmod-galaxybook-max98390 galaxybook-max98390-kmod-common"
