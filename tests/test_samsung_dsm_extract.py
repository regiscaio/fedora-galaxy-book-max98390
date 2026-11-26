#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regression tests using synthetic bytes only, never vendor coefficients."""
import hashlib
import importlib.util
from pathlib import Path
import os
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "scripts/prepare-samsung-dsm.py"
spec = importlib.util.spec_from_file_location("samsung_dsm", SCRIPT)
extract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extract)


class ProfileTests(unittest.TestCase):
    def test_pinned_source_and_output_reject_unrecognized_data(self):
        for data in (b"", bytes(86551), bytes(86552), bytes(86553), bytes(50091)):
            with self.subTest(size=len(data)):
                with self.assertRaisesRegex(ValueError, "Unrecognized"):
                    extract.build_profile(data)
        data = bytes(86552)
        with patch.object(extract, "SYS_SHA", hashlib.sha256(data).hexdigest()):
            with self.assertRaisesRegex(ValueError, "model-specific"):
                extract.build_profile(data)

    def test_four_amps_two_dsm_sets_in_wire_order(self):
        # Each synthetic table is a unique pattern; vendor data are unnecessary.
        src = bytearray(86552)
        amp = [bytes([idx]) * size for idx, size in enumerate((140, 140, 68, 68), 1)]
        dsm = [bytes([v]) * size for v, size in ((5, 760), (6, 320))]
        for start, table in zip((0x9B10, 0x9BF0, 0x9BA0, 0x9C80, 0x9CD0, 0x9FD0), amp + dsm):
            src[start:start + len(table)] = table
        expected = b"M98W\x01\x00\x04\x00"
        for count, buf in zip((35, 35, 17, 17), amp):
            expected += struct.pack("<H", count) + buf
        expected += b"\x02\x00" + b"_\x00" + dsm[0] + b"(\x00" + dsm[1] + b"\x00\x00\x01\x01"
        self.assertEqual(len(expected), 1522)
        with patch.object(extract, "SYS_SHA", hashlib.sha256(src).hexdigest()), \
             patch.object(extract, "PROFILE_SHA", hashlib.sha256(expected).hexdigest()):
            self.assertEqual(extract.build_profile(src), expected)

    def test_checks_vendor_model_and_codec_together(self):
        with tempfile.TemporaryDirectory() as tmp:
            dmi = Path(tmp) / "dmi"
            dmi.mkdir()
            (dmi / "sys_vendor").write_text("SAMSUNG ELECTRONICS CO., LTD.\n")
            (dmi / "product_name").write_text("960XGL\n")
            card = Path(tmp) / "card0"
            card.mkdir()
            codec = card / "codec#0"
            codec.write_text("Codec: Realtek ALC298\nSubsystem Id: 0x12340000\n")
            (card / "codec#2").write_text("Codec: Other codec\nSubsystem Id: 0x144dc1d8\n")
            with self.assertRaisesRegex(ValueError, "ALC298"):
                extract.check_target(dmi, Path(tmp))
            codec.write_text("Codec: Realtek ALC298\nSubsystem Id: 0x144dc1d8\n")
            extract.check_target(dmi, Path(tmp))
            (dmi / "product_name").write_text("different")
            with self.assertRaisesRegex(ValueError, "960XGL"):
                extract.check_target(dmi, Path(tmp))

    def test_input_types_and_output_collision(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "source"
            src.write_bytes(bytes(8))
            with self.assertRaisesRegex(ValueError, "known"):
                extract.read_input(src)
            pipe = Path(tmp) / "pipe"
            os.mkfifo(pipe)
            with self.assertRaises(ValueError):
                extract.read_input(pipe)
            link = Path(tmp) / "link"
            link.symlink_to(src)
            with self.assertRaises(OSError):
                extract.read_input(link)
            out = Path(tmp) / "result"
            extract.save_new(out, b"actual test bytes")
            self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                extract.save_new(out, b"replacement")
            with self.assertRaises(FileExistsError):
                extract.save_new(link, b"replacement via link")
            self.assertEqual(src.read_bytes(), bytes(8))
            self.assertEqual(out.read_bytes(), b"actual test bytes")


if __name__ == "__main__":
    unittest.main()
