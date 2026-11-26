#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Compile the production driver against an in-memory I2C/firmware bench.
set -euo pipefail
umask 077
here="$(cd -- "$(dirname -- "$0")" && pwd)"
module="$here/../module"
work="$(mktemp -d "${TMPDIR:-/tmp}/max98390-oem-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work"/{crypto,linux,sound}
# Provide only the headers consumed in this translation unit. API stubs live in
# the bench, not in the kernel module. System headers retain their usual meaning.
for hdr in crypto/sha2 linux/{delay,device,dmi,err,firmware,kernel,module,pci,regmap,string,types,unaligned} sound/{hda_codec,hdaudio}; do
    touch "$work/$hdr.h"
done
${CC:-cc} -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
    -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
    -fPIC -shared -I"$work" -I"$module" "$here/oem-driver-bench.c" -o "$work/bench.so"
python3 "$here/oem-driver-check.py" "$work/bench.so" "$@"
