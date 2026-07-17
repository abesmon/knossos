#!/usr/bin/env python3
"""Keep WASM Component Model as the only executable content contract."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
IGNORED_PARTS = {"node_modules", "target", "dist", ".godot"}


class WasmProductAuditTest(unittest.TestCase):
    def test_only_wasm_component_is_deliverable_executable_runtime(self) -> None:
        collector = (ROOT / "scripts/scripting_modules/scripting_module_collector.gd").read_text()
        self.assertIn('const RUNTIME_WASM := "wasm-component"', collector)
        self.assertIn("if runtime != RUNTIME_WASM", collector)

        runtime_constants: set[str] = set()
        for path in (ROOT / "scripts" / "scripting_modules").glob("*.gd"):
            runtime_constants.update(
                re.findall(r'const RUNTIME_[A-Z_]+\s*:=\s*"([^"]+)"', path.read_text())
            )
        self.assertEqual(runtime_constants, {"wasm-component"})

    def test_all_shipped_module_declarations_are_components(self) -> None:
        for path in ROOT.rglob("vrweb-module.json"):
            if any(part in IGNORED_PARTS for part in path.parts):
                continue
            manifest = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(manifest.get("runtime"), "wasm-component", str(path))
            self.assertEqual(manifest.get("world"), "vrweb:module@1", str(path))
            self.assertTrue(str(manifest.get("component", "")).endswith(".wasm"), str(path))

        tag_pattern = re.compile(r"<vrwebmodule\b[^>]*>", re.IGNORECASE | re.DOTALL)
        for path in (ROOT / "test_pages").glob("*.html"):
            for tag in tag_pattern.findall(path.read_text(encoding="utf-8")):
                self.assertRegex(tag, r'runtime\s*=\s*["\']wasm-component["\']')
                self.assertNotRegex(tag, r"\.gd(?:[\"']|\s|>)")

    def test_starter_contains_no_executable_guest_source(self) -> None:
        self.assertEqual(list((ROOT / "templates/vrweb_maker_starter").rglob("*.gd")), [])

    def test_removed_scripts_leave_no_uid_sidecars(self) -> None:
        for relative_root in ("addons/vrweb_tools", "scripts/scripting_modules", "tests"):
            for uid in (ROOT / relative_root).rglob("*.gd.uid"):
                source = Path(str(uid)[:-4])
                self.assertTrue(source.is_file(), f"orphan script UID: {uid.relative_to(ROOT)}")


if __name__ == "__main__":
    unittest.main()
