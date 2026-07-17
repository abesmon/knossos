#!/usr/bin/env python3
"""Verify deterministic release archive and execute it from a clean directory."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import build_wasm_conformance  # noqa: E402


class WasmConformanceArchiveTest(unittest.TestCase):
    def test_clean_archive_is_deterministic_and_self_testing(self) -> None:
        with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
            first = Path(first_dir) / "suite.zip"
            second = Path(second_dir) / "suite.zip"
            first_hash = build_wasm_conformance.build(first)
            second_hash = build_wasm_conformance.build(second)
            self.assertEqual(first_hash, second_hash)
            self.assertEqual(first.read_bytes(), second.read_bytes())

            extracted = Path(first_dir) / "clean suite"
            with zipfile.ZipFile(first) as archive:
                archive.extractall(extracted)
            self.assertFalse(any(path.suffix == ".gd" for path in extracted.rglob("*")))
            self.assertFalse(any("godot" in path.name.lower() for path in extracted.rglob("*")))
            subprocess.run(
                [sys.executable, "run.py"],
                cwd=extracted,
                check=True,
                env=os.environ.copy(),
            )


if __name__ == "__main__":
    unittest.main()
