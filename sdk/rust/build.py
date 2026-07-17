#!/usr/bin/env python3
"""Build the compact Rust VRWeb conformance component and canonical package."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parent.parent
DIST = ROOT / "dist"
TARGET = "wasm32-unknown-unknown"
BUILD_ENV = os.environ.copy()


def run(arguments: list[str]) -> None:
    subprocess.run(arguments, cwd=ROOT, check=True, env=BUILD_ENV)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_sha256(directory: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in directory.rglob("*") if item.is_file()):
        digest.update(path.relative_to(directory).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def main() -> int:
    cargo = os.environ.get("CARGO")
    rustup = Path.home() / ".cargo" / "bin" / "rustup"
    if cargo is None and rustup.is_file():
        cargo = subprocess.check_output(
            [str(rustup), "which", "cargo", "--toolchain", "1.94.0"], text=True).strip()
        BUILD_ENV["RUSTC"] = subprocess.check_output(
            [str(rustup), "which", "rustc", "--toolchain", "1.94.0"], text=True).strip()
    cargo = cargo or shutil.which("cargo")
    if cargo is None:
        raise SystemExit("Rust cargo was not found")
    DIST.mkdir(parents=True, exist_ok=True)
    run([cargo, "build", "--locked", "--release", "--lib", "--target", TARGET])
    core = ROOT / "target" / TARGET / "release" / "vrweb_rust_conformance.wasm"
    component = DIST / "module.wasm"
    second = DIST / "module.second.wasm"
    componentizer = [cargo, "run", "--locked", "--release", "--bin", "componentize", "--"]
    run(componentizer + [str(core), str(component)])
    run(componentizer + [str(core), str(second)])
    if component.read_bytes() != second.read_bytes():
        raise SystemExit("Rust component build is not byte-reproducible")
    second.unlink()

    manifest = {
        "format": 1,
        "id": "vrweb.example.rust-conformance",
        "version": "1.0.0",
        "sdk": "1.0.0",
        "runtime": "wasm-component",
        "world": "vrweb:module@1",
        "component": "module.wasm",
        "exports": {"default": {"kind": "scene-component"}},
        "requires": ["vrweb:core/1", "vrweb:scene/1", "vrweb:state/1"],
        "optional": [],
    }
    manifest_path = DIST / "vrweb-module.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    package = DIST / "conformance.vrmod"
    run([sys.executable, str(REPOSITORY / "tools" / "build_vrmod.py"),
         "--manifest", str(manifest_path), "--output", str(package)])
    evidence = {
        "format": 1,
        "sdk": "1.0.0",
        "adapter": "wit-bindgen-rust",
        "wit_bindgen": "0.55.0",
        "rust": "1.94.0",
        "target": TARGET,
        "byte_reproducible": True,
        "source_sha256": sha256(ROOT / "src" / "lib.rs"),
        "lock_sha256": sha256(ROOT / "Cargo.lock"),
        "wit_tree_sha256": tree_sha256(ROOT.parent / "wit"),
        "component_sha256": sha256(component),
        "package_sha256": sha256(package),
    }
    (DIST / "build-evidence.json").write_text(
        json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print("VRWeb Rust conformance component build: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
