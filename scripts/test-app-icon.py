#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONSET_SOURCE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build/AppIcon.iconset"
RESOURCES_SOURCE = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else ROOT / "Resources"
VERIFIER = ROOT / "scripts/verify-app-icon.swift"


def png_bytes(width, height, pixel):
    raw = b"".join(b"\0" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


class AppIconVerifierTests(unittest.TestCase):
    def setUp(self):
        build_dir = ROOT / ".build"
        build_dir.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="app-icon-", dir=build_dir)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.iconset = self.root / "AppIcon.iconset"
        self.resources = self.root / "Resources"
        shutil.copytree(ICONSET_SOURCE, self.iconset)
        shutil.copytree(RESOURCES_SOURCE, self.resources)

    def run_verifier(self):
        return subprocess.run(
            ["swift", str(VERIFIER), str(self.iconset), str(self.resources)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_existing_icons_pass(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_empty_alpha_reports_the_png_filename(self):
        target = self.iconset / "icon_512x512@2x.png"
        target.write_bytes(png_bytes(1024, 1024, lambda _x, _y: (0, 0, 0, 0)))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(target.name, result.stderr)

    def test_bad_dimensions_name_the_slice(self):
        target = self.iconset / "icon_512x512@2x.png"
        target.write_bytes(png_bytes(512, 512, lambda _x, _y: (0, 0, 0, 255)))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dimensions 512x512", result.stderr)

    def test_wrong_opaque_bounds_are_rejected(self):
        target = self.iconset / "icon_512x512@2x.png"
        target.write_bytes(png_bytes(1024, 1024, lambda _x, _y: (0, 0, 0, 255)))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("opaque bounds", result.stderr)

    def test_menu_bar_transparent_corners_are_enforced(self):
        target = self.resources / "MenuBarIcon.png"
        target.write_bytes(png_bytes(18, 18, lambda _x, _y: (0, 0, 0, 255)))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("corner", result.stderr)

    def test_menu_bar_coverage_is_enforced(self):
        target = self.resources / "MenuBarIcon.png"
        target.write_bytes(png_bytes(18, 18, lambda _x, _y: (0, 0, 0, 0)))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stroke coverage", result.stderr)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
