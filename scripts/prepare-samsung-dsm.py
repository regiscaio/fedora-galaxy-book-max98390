#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build a private MAX98390 tuning file from a local, licensed OEM driver.

No downloads, device writes, or vendor coefficients are included. Format and
table locations: Andycodeman/samsung-galaxy-book-linux-fixes, speaker-fix/
extract_adi_tables.py, commit c04a8bb58500792117eec20f619e4c4b2de484f5.
"""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile


# Analog Devices Inc. - MEDIA - 1.0.0.44 (Microsoft Update Catalog entry
# 9cd3303f-03c3-4f72-8631-ffc3383f6393, ACPI\MAX98390). The driver and
# generated profile are not redistributable under this script's license.
SYS_SIZE = 86552
SYS_SHA = "b24fa0920808d3aa846a5afd973663242fce81d84d13f4836aff95f23ddb8b8e"
CAB_SIZE = 50091
CAB_SHA = "8e8741fe7a0f8e910433037b7b1018c2846c27c785c4554eaa5de9260aa0fd82"
PROFILE_SIZE = 1522
PROFILE_SHA = "a704dcca7fb740779616826dcad3f4e195fbc51af0b59bc943dfb5a00bad7e68"
# Each register entry is 4 bytes, and each DSM entry is 8 (little endian).
# Keep little-endian values in M98W; the kernel serializes DSM words
# most-significant byte first for the amplifier's I2C interface.
# Tables are ordered by I2C address (0x38, 0x39, 0x3c, 0x3d), not file offset.
AMP_TABLES = ((0x9B10, 35), (0x9BF0, 35), (0x9BA0, 17), (0x9C80, 17))
DSM_TABLES = ((0x9CD0, 95), (0x9FD0, 40))


def check_target(dmi=Path("/sys/class/dmi/id"), cards=Path("/proc/asound")):
    vendor = (dmi / "sys_vendor").read_text().strip()
    model = (dmi / "product_name").read_text().strip()
    if vendor != "SAMSUNG ELECTRONICS CO., LTD." or model != "960XGL":
        raise ValueError("This profile is only for the Samsung Galaxy Book4 Ultra 960XGL.")
    for codec in cards.glob("card[0-9]*/codec#*"):
        # The two properties must come from the same physical codec.
        lines = set(codec.read_text(errors="replace").splitlines())
        if {"Codec: Realtek ALC298", "Subsystem Id: 0x144dc1d8"} <= lines:
            return
    raise ValueError("Expected Realtek ALC298 codec subsystem 0x144dc1d8 not found.")


def read_input(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size not in (SYS_SIZE, CAB_SIZE):
            raise ValueError("Expected the known ADIAmpDriver.sys 1.0.0.44 or its Microsoft CAB.")
        data = source.read(SYS_SIZE + 1)
    if len(data) == CAB_SIZE and hashlib.sha256(data).hexdigest() == CAB_SHA:
        # Parse verified bytes, not a second open of the user's pathname.
        with os.fdopen(os.memfd_create("verified-adi-cab"), "w+b") as cab:
            cab.write(data)
            cab.seek(0)
            try:
                proc = subprocess.run(
                    ["/usr/bin/cabextract", "-s", "-F", "ADIAmpDriver.sys", "-p",
                     f"/proc/self/fd/{cab.fileno()}"],
                    pass_fds=(cab.fileno(),), capture_output=True, timeout=15, check=True,
                )
            except FileNotFoundError as exc:
                raise ValueError("Reading a CAB requires cabextract, or supply ADIAmpDriver.sys directly.") from exc
            data = proc.stdout
    return data


def build_profile(data):
    if len(data) != SYS_SIZE or hashlib.sha256(data).hexdigest() != SYS_SHA:
        raise ValueError("Unrecognized OEM driver; expected the exact Analog Devices 1.0.0.44 release.")
    profile = bytearray(struct.pack("<4sHH", b"M98W", 1, 4))
    for start, count in AMP_TABLES:
        profile.extend(struct.pack("<H", count))
        profile.extend(data[start:start + 4 * count])
    profile.extend(struct.pack("<H", len(DSM_TABLES)))
    for start, count in DSM_TABLES:
        profile.extend(struct.pack("<H", count))
        profile.extend(data[start:start + 8 * count])
    profile.extend((0, 0, 1, 1))
    if len(profile) != PROFILE_SIZE or hashlib.sha256(profile).hexdigest() != PROFILE_SHA:
        raise ValueError("Extracted profile does not match the model-specific reference.")
    return bytes(profile)


def save_new(path, data):
    # Do not follow or replace an existing destination. Publish only a complete
    # local file; interruption before link() leaves the requested path alone.
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".samsung-dsm-") as tmp:
        tmp.write(data)
        tmp.flush()
        os.link(tmp.name, path)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("source", type=Path, help="Local ADIAmpDriver.sys 1.0.0.44 or its Microsoft Update CAB")
    dest = p.add_mutually_exclusive_group(required=True)
    dest.add_argument("-o", "--output", type=Path, help="New personal output file; never overwrites")
    dest.add_argument("--check-only", action="store_true", help="Validate without writing any file")
    args = p.parse_args()
    try:
        check_target()
        profile = build_profile(read_input(args.source))
        if args.output is not None:
            save_new(args.output, profile)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        p.exit(1, f"error: {exc}\n")
    print(f"Verified Samsung 960XGL / C1D8 DSM: {len(profile)} bytes, SHA-256 {PROFILE_SHA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
