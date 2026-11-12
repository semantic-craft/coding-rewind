#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class MemosOpLauncherTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix="op-launcher-test.", dir=ROOT / ".build")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.contents = self.root / "App With Spaces.app" / "Contents"
        self.macos = self.contents / "MacOS"
        self.resources = self.contents / "Resources"
        self.macos.mkdir(parents=True)
        self.resources.mkdir()
        self.launcher = self.macos / "CodingRewindApp"
        shutil.copyfile(ROOT / "scripts" / "memos-op-launcher.sh", self.launcher)
        self.launcher.chmod(0o755)
        self.output = self.root / "started.json"
        self.fake_op = self.root / "fake op"
        self.write_executable(self.fake_op, '''
import os
import sys
assert sys.argv[1:3] == ["run", "--"]
mode = os.environ["FAKE_OP_MODE"]
if mode == "fail":
    sys.exit(23)
environment = dict(os.environ)
if mode == "success":
    environment["CODING_REWIND_MEMOS_TOKEN"] = "fixture-token-only"
elif mode == "empty":
    environment["CODING_REWIND_MEMOS_TOKEN"] = ""
elif mode == "whitespace":
    environment["CODING_REWIND_MEMOS_TOKEN"] = " \\t\\r\\n "
elif mode == "padded-reference":
    environment["CODING_REWIND_MEMOS_TOKEN"] = " \\nop://fixture-vault/fixture-item/password"
os.execvpe(sys.argv[3], sys.argv[3:], environment)
''')
        self.write_executable(self.macos / "CodingRewindApp-native", '''
import json
import os
import sys
from pathlib import Path
Path(os.environ["TEST_OUTPUT"]).write_text(json.dumps({
    "token": os.environ.get("CODING_REWIND_MEMOS_TOKEN"),
    "arguments": sys.argv[1:]
}))
''')
        self.write_config("op://fixture-vault/fixture-item/password")

    def write_executable(self, path, body):
        path.write_text(f"#!{sys.executable}\n{body}")
        path.chmod(0o755)

    def write_config(self, reference):
        with (self.resources / "DeveloperCredentials.plist").open("wb") as config:
            plistlib.dump({"token_reference": reference, "op_executable": str(self.fake_op)}, config)

    def run_launcher(self, mode):
        return subprocess.run(
            [str(self.launcher), "--background", "argument with spaces"],
            env={"PATH": "/usr/bin:/bin", "FAKE_OP_MODE": mode, "TEST_OUTPUT": str(self.output)},
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_injects_only_into_the_started_application_and_preserves_arguments(self):
        result = self.run_launcher("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), {
            "token": "fixture-token-only",
            "arguments": ["--background", "argument with spaces"],
        })
        self.assertNotIn("fixture-token-only", result.stdout + result.stderr)
        self.assertNotIn("fixture-token-only", (self.resources / "DeveloperCredentials.plist").read_text())

    def test_authentication_failure_does_not_start_application(self):
        result = self.run_launcher("fail")
        self.assertEqual(result.returncode, 23)
        self.assertFalse(self.output.exists())

    def test_empty_whitespace_or_unresolved_credentials_do_not_start_application(self):
        for mode in ["empty", "whitespace", "unresolved", "padded-reference"]:
            with self.subTest(mode=mode):
                result = self.run_launcher(mode)
                self.assertEqual(result.returncode, 78)
                self.assertFalse(self.output.exists())

    def test_invalid_reference_does_not_start_application(self):
        self.write_config("not-a-secret-reference")
        result = self.run_launcher("success")
        self.assertEqual(result.returncode, 78)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
