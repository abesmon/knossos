#!/usr/bin/env python3
"""Run a released VRWeb WASM conformance archive without Knossos or Godot."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent


def main() -> int:
    report = json.loads((ROOT / "compatibility-report.json").read_text(encoding="utf-8"))
    missing = report.get("missing_for_full", {})
    has_missing = any(bool(items) for items in missing.values())
    if report.get("profile") == "full" and has_missing:
        raise SystemExit("invalid compatibility report: full profile has missing mandatory coverage")
    if bool(report.get("full_claim_allowed")) != (not has_missing):
        raise SystemExit("invalid compatibility report: full_claim_allowed disagrees with coverage")

    cargo = os.environ.get("CARGO") or shutil.which("cargo")
    if cargo is None:
        raise SystemExit("cargo was not found")
    command = [
        cargo,
        "run",
        "--locked",
        "--manifest-path",
        str(ROOT / "conformance" / "model-host" / "Cargo.toml"),
        "--",
        str(ROOT / "fixtures" / "rust-conformance.wasm"),
        str(ROOT / "expected" / "rust-conformance.json"),
    ]
    subprocess.run(command, cwd=ROOT, check=True, env=os.environ.copy())
    print(f"VRWeb WASM conformance {report['version']}: PASS ({report['profile']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
