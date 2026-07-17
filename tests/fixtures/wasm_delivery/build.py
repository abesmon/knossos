#!/usr/bin/env python3
"""Rebuild the small declaration-only delivery fixture."""

from __future__ import annotations

from pathlib import Path
import shutil
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[2]
sys.path.insert(0, str(REPOSITORY / "tools"))
import build_vrmod  # noqa: E402


def main() -> int:
    with tempfile.TemporaryDirectory() as directory:
        staging = Path(directory)
        shutil.copy2(ROOT / "vrweb-module.json", staging / "vrweb-module.json")
        shutil.copy2(
            REPOSITORY / "native/vrweb_wasm_runtime/fixtures/lifecycle.wasm",
            staging / "module.wasm",
        )
        digest = build_vrmod.build(
            staging / "vrweb-module.json", ROOT / "lifecycle.vrmod"
        )
    print(f"{digest}  {ROOT / 'lifecycle.vrmod'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
