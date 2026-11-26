#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Verify the legacy Redrix register images offline. Never accesses hardware."""

import hashlib
import re
import subprocess
import unittest
from pathlib import Path


MODULE = Path(__file__).resolve().parents[1] / "module"
FILTERS = (MODULE / "max98390_hda_filters.c").read_text(encoding="utf-8")
REGS = (MODULE / "max98390_regs.h").read_text(encoding="utf-8")
# From the two C arrays at BreadJS/linux@bfa17b7c1a43a2c474ed8d803fd88f5108ecff11.
DIGESTS = {
    "woofer": "3ec624d9ad7207bb5aa2b3adab840226937d79d49d22ee5857d5fdb300a9a695",
    "tweeter": "92809837a24341a943a4756c4998ee66d7007ecf6facf1d69608cbcf9ffe0234",
}


def table(role, source=FILTERS):
    match = re.search(
        rf"static const u8 max98390_dsm_firmware_{role}\[\]\s*=\s*\{{([^}}]+)\}};",
        source,
    )
    if match is None:
        raise AssertionError(f"missing unsized {role} register image")
    values = match[1].strip().removesuffix(",").split(",")
    return match, bytes(int(value.strip(), 16) for value in values)


def compile_guards(source):
    """Use the production arrays and assertions themselves, not Python size checks."""
    control = re.search(r"^#define MAX98390_R23E1_DSP_GLOBAL_EN\s+0x[0-9a-fA-F]+$", REGS, re.M)
    if control is None:
        raise AssertionError("missing DSP global-enable register")
    start = source.index("#define MAX98390_DSM_START_ADDR")
    end = source.index("static int max98390_load_dsm_firmware", start)
    c_source = (
        "#include <assert.h>\ntypedef unsigned char u8;\n"
        "#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))\n"
        + control[0] + "\n" + source[start:end]
    )
    return subprocess.run(
        ["cc", "-std=c11", "-fsyntax-only", "-x", "c", "-"],
        input=c_source, text=True, capture_output=True, check=False,
    )


class RedrixProfiles(unittest.TestCase):
    def test_reference_payloads_and_register_window(self):
        for role, expected in DIGESTS.items():
            with self.subTest(role=role):
                _, profile = table(role)
                self.assertEqual(len(profile), 0x23E1 - 0x2050)
                self.assertEqual(hashlib.sha256(profile).hexdigest(), expected)
        result = compile_guards(FILTERS)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_padding_fails_to_compile(self):
        # Reproduce both sizes that made the installed .14 driver reject all four amps.
        for role, padding in (("woofer", 16), ("tweeter", -80)):
            with self.subTest(role=role):
                match, payload = table(role)
                if padding > 0:
                    broken = payload[:816] + bytes(padding) + payload[816:]
                else:
                    self.assertEqual(payload[736:816], bytes(80))
                    broken = payload[:736] + payload[816:]
                new_bytes = ", ".join(f"0x{b:02x}" for b in broken)
                source = FILTERS[:match.start(1)] + new_bytes + FILTERS[match.end(1):]
                result = compile_guards(source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"invalid Redrix {role} DSM size", result.stderr)

    def test_window_overrun_fails_to_compile(self):
        source, count = re.subn(r"(#define MAX98390_DSM_START_ADDR\s+)0x2050\b",
                                r"\g<1>0x2051", FILTERS)
        self.assertEqual(count, 1)
        result = compile_guards(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Redrix DSM register window", result.stderr)


if __name__ == "__main__":
    unittest.main()
