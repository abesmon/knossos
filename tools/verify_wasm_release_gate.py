#!/usr/bin/env python3
"""Fail-closed aggregation of the three platform WASM release evidence sets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


PLATFORMS = ("Linux", "macOS", "Windows")
TARGETS = {
    "Linux": ["x86_64-unknown-linux-gnu"],
    "macOS": ["aarch64-apple-darwin", "x86_64-apple-darwin"],
    "Windows": ["x86_64-pc-windows-msvc"],
}
HEX = set("0123456789abcdef")


def load_exact(root: Path, pattern: str) -> dict:
    matches = list(root.rglob(pattern))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {pattern}, found {len(matches)}")
    return json.loads(matches[0].read_text(encoding="utf-8"))


def valid_sha(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and set(value) <= HEX


def verify(root: Path, source_revision: str, run_id: str,
           minimum_multiplier: int, minimum_soak_rounds: int) -> dict:
    runtime: dict[str, dict] = {}
    security: dict[str, dict] = {}
    for platform in PLATFORMS:
        runtime[platform] = load_exact(root, f"wasm-runtime-evidence-{platform}.json")
        security[platform] = load_exact(root, f"wasm-security-evidence-{platform}.json")
    for platform in PLATFORMS:
        artifact = runtime[platform]
        if artifact.get("platform") != platform or artifact.get("source_revision") != source_revision:
            raise ValueError(f"{platform}: runtime evidence identity mismatch")
        binary = artifact.get("binary", {})
        if not valid_sha(binary.get("sha256")) or int(binary.get("bytes", 0)) <= 0:
            raise ValueError(f"{platform}: invalid runtime binary evidence")
        if artifact.get("targets") != TARGETS[platform] or "--locked" not in artifact.get("build_flags", []):
            raise ValueError(f"{platform}: target/build flags mismatch")
        build = artifact.get("runtime_build", {})
        if (build.get("runtime"), build.get("version"), build.get("rust")) != (
                "wasmtime", "46.0.1", "1.94.0"):
            raise ValueError(f"{platform}: unpinned runtime toolchain")
        campaign = security[platform].get("property_campaign", {})
        if security[platform].get("source_revision") != source_revision:
            raise ValueError(f"{platform}: security evidence revision mismatch")
        if str(campaign.get("seed")) != run_id:
            raise ValueError(f"{platform}: fuzz seed does not bind the workflow run")
        if int(campaign.get("multiplier", 0)) < minimum_multiplier:
            raise ValueError(f"{platform}: fuzz multiplier below release gate")
        soak = security[platform].get("soak", {})
        if int(soak.get("rounds", 0)) < minimum_soak_rounds:
            raise ValueError(f"{platform}: soak rounds below release gate")
        if not bool(soak.get("exported_e2e")) or not bool(soak.get("navigation_race")):
            raise ValueError(f"{platform}: required exported/navigation soak missing")
    report = {
        "format": 1,
        "status": "pass",
        "platforms": list(PLATFORMS),
        "source_revision": source_revision,
        "run_id": run_id,
        "minimum_multiplier": minimum_multiplier,
        "minimum_soak_rounds": minimum_soak_rounds,
        "runtime_binary_sha256": {
            platform: runtime[platform]["binary"]["sha256"] for platform in PLATFORMS
        },
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--minimum-multiplier", type=int, default=1)
    parser.add_argument("--minimum-soak-rounds", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = verify(args.root, args.source_revision, args.run_id,
                        args.minimum_multiplier, args.minimum_soak_rounds)
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise SystemExit(f"WASM release gate failed: {error}") from error
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"WASM release gate: PASS ({', '.join(PLATFORMS)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
