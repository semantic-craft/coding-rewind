#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parent.parent
LINT_SCRIPT = REPO_ROOT / "scripts" / "lint_invariants.py"
COPY_ITEMS = (
    "Sources",
    "Tests",
    "deploy",
    "extensions",
    "dsh-plugin",
    "scripts",
    "contracts",
    ".comment-ratchet.json",
)
IGNORE_NAMES = shutil.ignore_patterns(
    ".git",
    ".build",
    "Vendor",
    "node_modules",
    "__pycache__",
    "*.pyc",
    "dist",
    ".test-data",
)


def run_linter(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-B", str(LINT_SCRIPT), "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


def copy_repo_subset(dest: Path) -> None:
    for item in COPY_ITEMS:
        src = REPO_ROOT / item
        dst = dest / item
        if src.is_dir():
            shutil.copytree(src, dst, symlinks=False, ignore=IGNORE_NAMES)
        elif src.is_file():
            shutil.copy2(src, dst)


class LintInvariantsTest(unittest.TestCase):
    def _make_temp_repo(self) -> tempfile.TemporaryDirectory[str]:
        build_dir = REPO_ROOT / ".build"
        build_dir.mkdir(parents=True, exist_ok=True)
        temp_dir = tempfile.TemporaryDirectory(dir=build_dir, prefix="lint-invariants-test-")
        copy_repo_subset(Path(temp_dir.name))
        return temp_dir

    def test_clean_repo_passes(self) -> None:
        proc = run_linter(REPO_ROOT)
        self.assertEqual(proc.returncode, 0, msg=f"unexpected stderr:\n{proc.stderr}")
        self.assertEqual(proc.stderr.strip(), "")

    def test_a_rejects_ordinary_comments_and_nonzero_ratchet(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)

            swift_file = root / "Sources/CodingRewindCore/Places.swift"
            swift_file.write_text(
                swift_file.read_text(encoding="utf-8") + "\n// leaked swift comment\n",
                encoding="utf-8",
            )

            py_file = root / "deploy/vps/enricher/enricher.py"
            py_file.write_text(
                py_file.read_text(encoding="utf-8") + "\n# leaked python comment\n",
                encoding="utf-8",
            )

            js_file = root / "extensions/web-clipper/memos_payload.mjs"
            js_file.write_text(
                js_file.read_text(encoding="utf-8") + "\n/* leaked js comment */\n",
                encoding="utf-8",
            )

            ratchet = root / ".comment-ratchet.json"
            data = json.loads(ratchet.read_text(encoding="utf-8"))
            data["max_total"] = 1
            ratchet.write_text(json.dumps(data), encoding="utf-8")

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: .comment-ratchet.json:1:", proc.stderr)
            self.assertIn("FAIL: Sources/CodingRewindCore/Places.swift:", proc.stderr)
            self.assertIn("FAIL: deploy/vps/enricher/enricher.py:", proc.stderr)
            self.assertIn("FAIL: extensions/web-clipper/memos_payload.mjs:", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_b_rejects_tooltip_assignment_in_app(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)
            target = root / "Sources/CodingRewindApp/SystemURLOpener.swift"
            target.write_text(
                target.read_text(encoding="utf-8")
                + '\nfunc badTooltip(_ button: NSStatusBarButton) {\n    button.toolTip = "Coding Rewind"\n}\n',
                encoding="utf-8",
            )

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: Sources/CodingRewindApp/SystemURLOpener.swift:", proc.stderr)
            self.assertIn("setAccessibilityLabel(_:)", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_c_rejects_menubar_extra_url_schemes_and_custom_scheme(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)

            app_file = root / "Sources/CodingRewindApp/SystemURLOpener.swift"
            app_file.write_text(
                app_file.read_text(encoding="utf-8") + '\nlet badScene = MenuBarExtra("Rewind") {}\n',
                encoding="utf-8",
            )

            core_file = root / "Sources/CodingRewindCore/MemosWireFormat.swift"
            core_file.write_text(
                core_file.read_text(encoding="utf-8") + '\nlet legacyLink = "coding-rewind://stash"\n',
                encoding="utf-8",
            )

            bundle_script = root / "scripts/build-app-bundle.sh"
            bundle_script.write_text(
                bundle_script.read_text(encoding="utf-8") + "\nprintf '<key>CFBundleURLSchemes</key>\\n'\n",
                encoding="utf-8",
            )

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("MenuBarExtra", proc.stderr)
            self.assertIn("coding-rewind://", proc.stderr)
            self.assertIn("CFBundleURLSchemes", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_d_rejects_direct_nsworkspace_shared_open(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)
            target = root / "Sources/CodingRewindApp/SettingsViews.swift"
            target.write_text(
                target.read_text(encoding="utf-8")
                + '\nfunc badOpen(_ url: URL) {\n    NSWorkspace.shared.open(url)\n}\n',
                encoding="utf-8",
            )

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: Sources/CodingRewindApp/SettingsViews.swift:", proc.stderr)
            self.assertIn("SystemURLOpener.open(_:)", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_e_rejects_direct_array_methods_on_dom_collections(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)
            target = root / "extensions/web-clipper/extractors.mjs"
            target.write_text(
                target.read_text(encoding="utf-8")
                + "\nexport function badDom(node, range) {\n"
                + "  const a = node.childNodes.some((x) => Boolean(x));\n"
                + "  const b = node.children.map((x) => x);\n"
                + "  const c = range.getClientRects().filter((r) => r.width > 0);\n"
                + "  return [a, b, c];\n"
                + "}\n",
                encoding="utf-8",
            )

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: extensions/web-clipper/extractors.mjs:", proc.stderr)
            self.assertIn(".childNodes.some(", proc.stderr)
            self.assertIn(".children.map(", proc.stderr)
            self.assertIn("getClientRects().filter(", proc.stderr)
            self.assertIn("Array.from(...)", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_f_rejects_bounded_places_snippet_query(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)
            target = root / "Sources/CodingRewindCore/AppCoordinator+Places.swift"
            original = target.read_text(encoding="utf-8")
            mutated = original.replace("resultLimit: .unbounded", "resultLimit: .bounded(200)", 1)
            self.assertNotEqual(original, mutated)
            target.write_text(mutated, encoding="utf-8")

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: Sources/CodingRewindCore/AppCoordinator+Places.swift:", proc.stderr)
            self.assertIn("resultLimit: .unbounded", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_g_rejects_offline_outbox_locking_data_file_directly(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)
            target = root / "Sources/CodingRewindCore/PlatformStorage.swift"
            original = target.read_text(encoding="utf-8")
            old_block = (
                '        let lockURL = fileURL.appendingPathExtension("lock")\n'
                '        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)'
            )
            new_block = "        let fd = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)"
            self.assertIn(old_block, original)
            target.write_text(original.replace(old_block, new_block, 1), encoding="utf-8")

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: Sources/CodingRewindCore/PlatformStorage.swift:", proc.stderr)
            self.assertIn("ADR-001", proc.stderr)
            self.assertIn("Fix:", proc.stderr)

    def test_h_rejects_cross_tier_wire_contract_drift(self) -> None:
        with self._make_temp_repo() as tmp:
            root = Path(tmp)
            contract = json.loads((root / "contracts/wire-contract.json").read_text(encoding="utf-8"))

            swift_places = root / "Sources/CodingRewindCore/Places.swift"
            swift_places.write_text(
                swift_places.read_text(encoding="utf-8").replace(
                    "public static let maxLength = 28",
                    "public static let maxLength = 32",
                    1,
                ),
                encoding="utf-8",
            )

            py_enricher = root / "deploy/vps/enricher/enricher.py"
            py_enricher.write_text(
                py_enricher.read_text(encoding="utf-8").replace(
                    f'CONTEXT_MARKER = "{contract["contextMarker"]}"',
                    'CONTEXT_MARKER = "<!-- rewind-context-v2 -->"',
                    1,
                ),
                encoding="utf-8",
            )

            js_payload = root / "extensions/web-clipper/memos_payload.mjs"
            js_payload.write_text(
                js_payload.read_text(encoding="utf-8").replace(
                    f'{contract["apiPath"]}?memoId=',
                    f'{contract["forbiddenLegacyApiPath"]}?memoId=',
                    1,
                ),
                encoding="utf-8",
            )

            proc = run_linter(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("FAIL: Sources/CodingRewindCore/Places.swift:", proc.stderr)
            self.assertIn("FAIL: deploy/vps/enricher/enricher.py:", proc.stderr)
            self.assertIn("FAIL: extensions/web-clipper/memos_payload.mjs:", proc.stderr)
            self.assertIn("contracts/wire-contract.json", proc.stderr)
            self.assertIn("Fix:", proc.stderr)


if __name__ == "__main__":
    unittest.main()
