#!/usr/bin/env python3
"""Emit machine-readable evidence for the WASM hostile matrix executed by CI."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = ROOT / "conformance" / "dist"


def required_fixture(name: str) -> None:
    wat = ROOT / "native" / "vrweb_wasm_runtime" / "fixtures" / f"{name}.wat"
    wasm = wat.with_suffix(".wasm")
    if not wat.is_file() or not wasm.is_file():
        raise SystemExit(f"hostile fixture is missing: {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", default=platform.system().lower())
    args = parser.parse_args()
    multiplier = max(1, min(100, int(os.environ.get("VRWEB_FUZZ_MULTIPLIER", "1"))))
    source_revision = os.environ.get("GITHUB_SHA") or subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True,
        text=True, capture_output=True,
    ).stdout.strip()
    runtime_manifest = json.loads(
        (ROOT / "native/vrweb_wasm_runtime/runtime-build.json").read_text(encoding="utf-8")
    )
    cargo = (ROOT / "native/vrweb_wasm_runtime/Cargo.toml").read_text(encoding="utf-8")
    wasmtime = re.search(r'wasmtime = \{ version = "=([^"]+)"', cargo)
    godot_rust = re.search(r'godot = \{ version = "=([^"]+)"', cargo)
    if wasmtime is None or godot_rust is None:
        raise SystemExit("pinned runtime versions were not found")
    runtime_fixtures = [
        "wasi_import",
        "unknown_import",
        "infinite_loop",
        "memory_grow",
        "table_grow",
        "trap",
        "host_call_flood",
        "lifecycle_trap_create",
        "lifecycle_trap_mount",
        "lifecycle_trap_event_unmount",
    ]
    for fixture in runtime_fixtures:
        required_fixture(fixture)
    evidence = {
        "format": 2,
        "profile": "vrweb-wasm-security-draft",
        "platform": args.platform,
        "source_revision": source_revision,
        "toolchain": {
            "rust": "1.94.0",
            "wasmtime": wasmtime.group(1),
            "godot_rust": godot_rust.group(1),
            "runtime_build": runtime_manifest,
        },
        "ambient_authority": {"wasi_linked": False, "filesystem": False, "network": False},
        "hostile_coverage": {
            "binary": ["invalid", "truncated-prefixes", "byte-mutations", "core-module",
                       "seeded-random-binaries", "seeded-multi-mutations"],
            "imports": ["wasi", "unknown", "undeclared", "incompatible-major"],
            "execution": ["infinite-loop", "trap", "host-call-flood"],
            "growth": ["linear-memory", "table-elements", "scene-resources", "signal-queue"],
            "handles": ["forged", "foreign-owner", "foreign-page", "stale", "after-close"],
            "scene_policy": ["unsafe-property", "unsafe-method", "unsafe-resource"],
            "lifecycle": ["duplicate-unmount", "callback-after-unmount", "recursive-delivery-queued",
                          "create-trap", "mount-trap", "event-trap", "unmount-trap",
                          "healthy-after-each-runtime-failure"],
            "javascript": ["infinite-loop", "memory-growth", "no-browser-globals", "no-node-globals"],
            "value_codec": ["round-trip", "malformed-json", "invalid-utf8", "invalid-base64",
                            "non-finite-float", "oversized-depth", "oversized-items"],
        },
        "property_campaign": {
            "seed": os.environ.get("VRWEB_FUZZ_SEED", "12648430"),
            "multiplier": multiplier,
            "binary_random_inputs": 10000 * multiplier,
            "binary_mutated_components": 10000 * multiplier,
            "value_round_trips": 4000 * multiplier,
            "untrusted_value_byte_inputs": 4000 * multiplier,
            "malformed_value_inputs": 4000 * multiplier,
            "handle_lifecycle_cases": 8000 * multiplier,
        },
        "soak": {
            "rounds": max(1, int(os.environ.get("WASM_SOAK_ROUNDS", "1"))),
            "exported_e2e": True,
            "navigation_race": True,
            "scenarios": ["compatible", "mismatch", "navigation-race", "authority-change"],
        },
        "commands": [
            "cargo test --locked --manifest-path native/vrweb_wasm_runtime/Cargo.toml",
            "godot --headless --script tests/test_native_wasm_runtime.gd",
            "godot --headless --script tests/test_wasm_reentrancy.gd",
            "godot --headless --script tests/test_wasm_value_handles.gd",
            "godot --headless --script tests/test_wasm_value_fuzz.gd",
            "godot --headless --script tests/test_wasm_services.gd",
            "godot --headless --script tests/test_javascript_wasm_runtime.gd",
            "python3 tests/test_wasm_product_audit.py",
        ],
    }
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    output = OUTPUT_ROOT / f"wasm-security-evidence-{args.platform}.json"
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
