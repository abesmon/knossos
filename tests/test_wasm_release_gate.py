#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from verify_wasm_release_gate import PLATFORMS, TARGETS, verify  # noqa: E402


class WasmReleaseGateTest(unittest.TestCase):
    revision = "a" * 40
    run_id = "12345"

    def write_valid(self, root: Path) -> None:
        for platform in PLATFORMS:
            runtime = {
                "platform": platform,
                "source_revision": self.revision,
                "binary": {"bytes": 100, "sha256": "b" * 64},
                "targets": TARGETS[platform],
                "build_flags": ["--locked", "--lib", "--profile", "dev"],
                "runtime_build": {"runtime": "wasmtime", "version": "46.0.1", "rust": "1.94.0"},
            }
            security = {
                "source_revision": self.revision,
                "property_campaign": {"seed": self.run_id, "multiplier": 10},
                "soak": {"rounds": 10, "exported_e2e": True, "navigation_race": True},
            }
            (root / f"wasm-runtime-evidence-{platform}.json").write_text(json.dumps(runtime))
            (root / f"wasm-security-evidence-{platform}.json").write_text(json.dumps(security))

    def test_three_platform_gate_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_valid(root)
            report = verify(root, self.revision, self.run_id, 10, 10)
            self.assertEqual(report["status"], "pass")
            self.assertEqual(report["platforms"], list(PLATFORMS))

    def test_missing_platform_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_valid(root)
            (root / "wasm-security-evidence-Windows.json").unlink()
            with self.assertRaisesRegex(ValueError, "exactly one"):
                verify(root, self.revision, self.run_id, 10, 10)

    def test_stale_revision_or_short_campaign_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_valid(root)
            runtime = root / "wasm-runtime-evidence-Linux.json"
            value = json.loads(runtime.read_text())
            value["source_revision"] = "c" * 40
            runtime.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                verify(root, self.revision, self.run_id, 10, 10)
            value["source_revision"] = self.revision
            runtime.write_text(json.dumps(value))
            security = root / "wasm-security-evidence-Linux.json"
            campaign = json.loads(security.read_text())
            campaign["property_campaign"]["multiplier"] = 1
            security.write_text(json.dumps(campaign))
            with self.assertRaisesRegex(ValueError, "multiplier"):
                verify(root, self.revision, self.run_id, 10, 10)


if __name__ == "__main__":
    unittest.main()
