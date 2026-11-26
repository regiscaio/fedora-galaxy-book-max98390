#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0
"""Exercise the compiled driver without firmware redistribution or an I2C bus."""

import ctypes as C
import errno
import hashlib
from pathlib import Path
import struct
import sys


PIN = bytes.fromhex("a704dcca7fb740779616826dcad3f4e195fbc51af0b59bc943dfb5a00bad7e68")
ADDR = (0x38, 0x39, 0x3C, 0x3D)
U8P = C.POINTER(C.c_uint8)
HASH = C.CFUNCTYPE(None, U8P, C.c_size_t, U8P)
WRITE = C.CFUNCTYPE(C.c_int, C.c_uint, C.c_uint, C.c_uint)
bench = C.CDLL(sys.argv[1])
bench.bench_prepare.argtypes = [U8P, C.c_size_t, C.c_int, C.c_int, C.c_int, HASH, WRITE]
for name in ("bench_program", "bench_cleanup", "bench_requests", "bench_is_oem"):
    getattr(bench, name).argtypes = []
bench.bench_cleanup.restype = None


def synthetic_profile():
    # These generated values are deliberately not hardware calibration.
    data = bytearray(struct.pack("<4sHH", b"M98W", 1, 4))
    for amp, count in enumerate((35, 35, 17, 17)):
        data += struct.pack("<H", count)
        for i in range(count):
            entry = (0x23E1, 1) if i == count-1 else (0x201B, (i + 31 * amp) & 255)
            data += struct.pack("<HH", *entry)
    data += struct.pack("<H", 2)
    for group, count in enumerate((95, 40)):
        data += struct.pack("<H", count)
        for i in range(count):
            reg = (0x2100 if group == 0 else 0x2128) + 4*i
            data += struct.pack("<HHI", reg, 0, 0x10203040 + i + (group << 20))
    data += bytes((0, 0, 1, 1))
    assert len(data) == 1522 and hashlib.sha256(data).digest() != PIN
    return bytes(data)


def selected(data, amp):
    offset = 8
    regs = []
    for _ in ADDR:
        n, = struct.unpack_from("<H", data, offset)
        offset += 2
        regs.append([(r, v, 1) for r, v in struct.iter_unpack("<HH", data[offset:offset+4*n])])
        offset += 4*n
    groups, = struct.unpack_from("<H", data, offset)
    offset += 2
    dsm = []
    for _ in range(groups):
        n, = struct.unpack_from("<H", data, offset)
        offset += 2
        dsm.append([(r, v, 4) for r, _, v in struct.iter_unpack("<HHI", data[offset:offset+8*n])])
        offset += 8*n
    assert len(data) - offset == len(ADDR)
    return regs[amp], dsm[data[offset+amp]]


def run_case(data, *, index=0, addr=None, board=0, structure_only=False,
             program=False, fail_at=None):
    requests = []
    writes = []
    storage = (C.c_uint8 * len(data)).from_buffer_copy(data) if data is not None else None

    @HASH
    def digest(buf, n, dst):
        # Every genuine acceptance test uses real SHA-256. The controlled
        # digest stub below isolates parser errors behind the authenticity gate.
        requests.append(C.string_at(buf, n))
        value = PIN if structure_only else hashlib.sha256(requests[-1]).digest()
        C.memmove(dst, value, len(value))

    @WRITE
    def write(reg, value, width):
        writes.append((reg, value, width))
        return -errno.EIO if len(writes) == fail_at else 0

    try:
        rc = bench.bench_prepare(storage, len(data or b""), index,
                                 ADDR[index] if addr is None else addr, board,
                                 digest, write)
        assert not writes, "Preparing firmware must never write an I2C register"
        calls = bench.bench_requests()
        if rc or board == 7:
            assert not bench.bench_is_oem() and bench.bench_program() < 0 and not writes
        elif program:
            assert bench.bench_is_oem()
            rc = bench.bench_program()
        return rc, writes, requests, calls
    finally:
        bench.bench_cleanup()


def assert_program(profile, fake_digest):
    for amp in range(len(ADDR)):
        kwargs = dict(index=amp, structure_only=fake_digest, program=True)
        rc, trace, hashed, requested = run_case(profile, **kwargs)
        assert (rc, requested) == (0, 1) and hashed == [profile], (amp, rc)
        regs, dsm = selected(profile, amp)
        # All register/value pairs must reach the wire in their source order;
        # 32-bit DSM coefficients are checked including the wire endianness.
        # DSP enable is intentionally deferred until *after* the last DSM word.
        assert regs[-1][0] == 0x23E1 and trace == (
            regs[:-1] + dsm + [(0x23E1, 1, 1), (0x203A, 0x81, 1), (0x23FF, 1, 1)]
        )
        for j in range(1, len(trace) + 1):
            rc, observed, _, _ = run_case(profile, fail_at=j, **kwargs)
            assert rc == -errno.EIO and observed == trace[:j], (amp, j, rc)


p = synthetic_profile()
assert_program(p, True)
assert run_case(p)[0] != 0, "Valid shape alone must not authorize programming"
for bad in (None, b"", p[:8], p[:-1], p+b"\0"):
    assert run_case(bad, structure_only=True)[0] < 0
for pos in (0, 4, 6, 8, 150, 292, 362, 432, 434, 1196, 1518, 1521):
    changed = bytearray(p)
    changed[pos] ^= 0x02
    assert run_case(changed, structure_only=True)[0] < 0, ("M98W structure", pos)
for amp in range(4):
    for wrong in set(ADDR + (0x3A,)) - {ADDR[amp]}:
        assert run_case(p, structure_only=True, index=amp, addr=wrong)[0] < 0
for amp in (-1, 4):
    assert run_case(p, structure_only=True, index=amp, addr=0x38)[0] < 0
for board in range(1, 7):
    rc, writes, hashes, requests = run_case(p, board=board, structure_only=True)
    assert rc < 0 and not writes and not hashes and not requests
assert run_case(p, board=7, structure_only=True) == (0, [], [], 0)
rc, writes, _, requested = run_case(p, board=8, structure_only=True)
assert rc == -errno.ENOMEM and not writes and requested == 1
for offset, value in (
    (10, 0x2011), (10, 0x203A), (10, 0x23FF), (10, 0x23E1),
    (12, 256), (146, 0x201B), (436, 0x20FC), (436, 0x22E0),
    (436, 0x2101), (438, 1),
):
    bad_reg = bytearray(p)
    struct.pack_into("<H", bad_reg, offset, value)
    assert run_case(bad_reg, structure_only=True)[0] < 0, ("unsafe register", offset, value)

if len(sys.argv) > 2:
    assert len(sys.argv) == 3
    native = Path(sys.argv[2]).read_bytes()
    if hashlib.sha256(native).digest() != PIN:
        raise SystemExit("Optional input is not the authorized Samsung M98W profile")
    assert_program(native, False)
    tampered = bytearray(native)
    tampered[24] ^= 1
    assert run_case(tampered)[0] < 0
    print("OEM profile: genuine digest, four amp/pair mappings and write failures passed.")
print("OEM bench: synthetic tables, wrong digest/structure/address and I/O failures passed.")
