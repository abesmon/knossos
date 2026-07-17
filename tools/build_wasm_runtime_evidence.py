#!/usr/bin/env python3
"""Validate and describe one platform-specific native runtime artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "vrweb_wasm_runtime"
OUTPUT_ROOT = ROOT / "conformance" / "dist"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_revision(explicit: str) -> str:
    if explicit:
        value = explicit
    else:
        value = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True,
            text=True, capture_output=True,
        ).stdout.strip()
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value.lower()):
        raise SystemExit("source revision is not a full Git SHA")
    return value.lower()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=["Linux", "macOS", "Windows"])
    parser.add_argument("--binary", required=True)
    parser.add_argument("--profile", choices=["debug", "release"], required=True)
    parser.add_argument("--source-revision", default=os.environ.get("GITHUB_SHA", ""))
    args = parser.parse_args()

    descriptor = ADDON / "vrweb_wasm_runtime.gdextension"
    binary = ADDON / "bin" / args.binary
    addon_license = ADDON / "LICENSES.md"
    source_license = ROOT / "native" / "vrweb_wasm_runtime" / "LICENSES.md"
    runtime_build_path = ROOT / "native" / "vrweb_wasm_runtime" / "runtime-build.json"
    for required in (descriptor, binary, addon_license, source_license, runtime_build_path):
        if not required.is_file() or required.stat().st_size == 0:
            raise SystemExit(f"runtime artifact input is missing: {required}")
    descriptor_text = descriptor.read_text(encoding="utf-8")
    if f"bin/{args.binary}" not in descriptor_text:
        raise SystemExit("GDExtension descriptor does not reference the platform binary")
    if addon_license.read_bytes() != source_license.read_bytes():
        raise SystemExit("packaged runtime license differs from the pinned source license")
    runtime_build = json.loads(runtime_build_path.read_text(encoding="utf-8"))
    platform_targets = {
        "Linux": ["x86_64-unknown-linux-gnu"],
        "macOS": ["aarch64-apple-darwin", "x86_64-apple-darwin"],
        "Windows": ["x86_64-pc-windows-msvc"],
    }[args.platform]
    if any(target not in runtime_build.get("targets", []) for target in platform_targets):
        raise SystemExit("runtime build metadata does not declare every platform target")
    evidence = {
        "format": 1,
        "platform": args.platform,
        "source_revision": source_revision(args.source_revision),
        "profile": args.profile,
        "targets": platform_targets,
        "build_flags": ["--locked", "--lib", "--profile", "dev" if args.profile == "debug" else "release"],
        "binary": {
            "name": args.binary,
            "bytes": binary.stat().st_size,
            "sha256": sha256(binary),
        },
        "descriptor_sha256": sha256(descriptor),
        "licenses_sha256": sha256(addon_license),
        "runtime_build": runtime_build,
    }
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    output = OUTPUT_ROOT / f"wasm-runtime-evidence-{args.platform}.json"
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    digest = hashlib.sha256(
        json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with Path(github_output).open("a", encoding="utf-8") as stream:
            stream.write(f"artifact_digest={digest}\n")
    print(f"{digest}  {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
