#!/usr/bin/env python3
"""Build the compact scene demo and publish its canonical package into test_pages."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parent.parent
TARGET = "wasm32-unknown-unknown"
BUILD = ROOT / "build"
OUTPUT = REPOSITORY / "test_pages" / "wasm_scene_demo.vrmod"


def main() -> int:
    environment = os.environ.copy()
    rustup = Path.home() / ".cargo" / "bin" / "rustup"
    cargo = environment.get("CARGO")
    if cargo is None and rustup.is_file():
        cargo = subprocess.check_output(
            [str(rustup), "which", "cargo", "--toolchain", "1.94.0"], text=True
        ).strip()
        environment["RUSTC"] = subprocess.check_output(
            [str(rustup), "which", "rustc", "--toolchain", "1.94.0"], text=True
        ).strip()
    cargo = cargo or shutil.which("cargo")
    if cargo is None:
        raise SystemExit("Rust cargo was not found")

    subprocess.run(
        [cargo, "build", "--locked", "--release", "--lib", "--target", TARGET],
        cwd=ROOT,
        check=True,
        env=environment,
    )
    BUILD.mkdir(parents=True, exist_ok=True)
    core_module = ROOT / "target" / TARGET / "release" / "vrweb_wasm_scene_demo.wasm"
    component = BUILD / "module.wasm"
    subprocess.run(
        [
            cargo,
            "run",
            "--locked",
            "--release",
            "--manifest-path",
            str(REPOSITORY / "sdk" / "rust" / "Cargo.toml"),
            "--bin",
            "componentize",
            "--",
            str(core_module),
            str(component),
        ],
        cwd=ROOT,
        check=True,
        env=environment,
    )
    subprocess.run(
        [
            sys.executable,
            str(REPOSITORY / "tools" / "build_vrmod.py"),
            "--manifest",
            str(ROOT / "vrweb-module.json"),
            "--output",
            str(OUTPUT),
        ],
        cwd=REPOSITORY,
        check=True,
    )
    print(f"WASM scene demo built: {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
