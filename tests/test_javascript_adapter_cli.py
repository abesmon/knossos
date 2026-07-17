#!/usr/bin/env python3
"""Clean-directory smoke test for the external JavaScript/TypeScript adapter CLI."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "sdk" / "javascript" / "build.mjs"


class JavascriptAdapterCliTest(unittest.TestCase):
    def test_external_typescript_build_contains_only_publishable_artifacts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vrweb-js-adapter-") as temporary:
            project = Path(temporary)
            source = project / "light-switch.ts"
            source.write_text(
                'import { core } from "@vrweb/sdk";\n'
                "export function create(): number { core.logCode(1); return 1; }\n"
                "export function mount(_instance: number): number { return 0; }\n"
                "export function event(_instance: number, _event: Uint8Array): number { return 0; }\n"
                "export function unmount(_instance: number): number { return 0; }\n",
                encoding="utf-8",
            )
            manifest = project / "vrweb-module.json"
            manifest.write_text(json.dumps({
                "format": 1,
                "id": "vrweb.example.external-typescript",
                "version": "1.0.0",
                "sdk": "1.0.0",
                "runtime": "wasm-component",
                "world": "vrweb:module@1",
                "component": "build/module.wasm",
                "exports": {"default": {"kind": "scene-component"}},
                "requires": ["vrweb:core/1"],
                "optional": [],
            }, indent=2) + "\n", encoding="utf-8")
            package = project / "dist" / "light-switch.vrmod"
            subprocess.run([
                "node", str(ADAPTER), "--entry", str(source), "--manifest", str(manifest),
                "--output", str(package),
            ], cwd=ROOT, check=True)
            self.assertTrue(package.is_file())
            self.assertTrue(Path(f"{package}.evidence.json").is_file())
            with zipfile.ZipFile(package) as archive:
                self.assertEqual(archive.namelist(), ["build/module.wasm", "vrweb-module.json"])
                self.assertNotIn(source.name, archive.namelist())
                component = project / "module.wasm"
                component.write_bytes(archive.read("build/module.wasm"))
            observed = subprocess.run([
                str(ROOT / "sdk/javascript/node_modules/.bin/jco"), "wit", str(component),
            ], cwd=ROOT, check=True, capture_output=True, text=True).stdout
            self.assertIn("import vrweb:core/host@1.0.0", observed)
            self.assertNotIn("import vrweb:scene/host", observed)
            self.assertNotIn("import vrweb:state/host", observed)

    def test_adapter_rejects_used_but_undeclared_capability(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vrweb-js-capability-") as temporary:
            project = Path(temporary)
            source = project / "state.ts"
            source.write_text(
                'import { state } from "@vrweb/sdk";\n'
                "export function create(): number { state.read('x'); return 1; }\n"
                "export function mount(_instance: number): number { return 0; }\n"
                "export function event(_instance: number, _event: Uint8Array): number { return 0; }\n"
                "export function unmount(_instance: number): number { return 0; }\n",
                encoding="utf-8",
            )
            manifest = project / "vrweb-module.json"
            manifest.write_text(json.dumps({
                "format": 1, "id": "vrweb.example.undeclared", "version": "1.0.0",
                "sdk": "1.0.0", "runtime": "wasm-component", "world": "vrweb:module@1",
                "component": "module.wasm",
                "exports": {"default": {"kind": "scene-component"}},
                "requires": ["vrweb:core/1"], "optional": [],
            }), encoding="utf-8")
            result = subprocess.run([
                "node", str(ADAPTER), "--entry", str(source), "--manifest", str(manifest),
                "--output", str(project / "module.vrmod"),
            ], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("undeclared capability: vrweb:state/1", result.stderr)


if __name__ == "__main__":
    unittest.main()
