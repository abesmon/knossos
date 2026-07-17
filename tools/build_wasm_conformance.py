#!/usr/bin/env python3
"""Build a deterministic, standalone VRWeb WASM conformance archive."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "conformance" / "dist" / "vrweb-wasm-conformance-1.0.0-draft.1.zip"
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def files() -> list[tuple[str, bytes]]:
    entries: list[tuple[str, bytes]] = []

    def add_file(archive_path: str, source: Path) -> None:
        if not source.is_file():
            raise FileNotFoundError(source)
        entries.append((archive_path, source.read_bytes()))

    for source in sorted((ROOT / "sdk" / "wit").rglob("*.wit")):
        add_file(f"sdk/wit/{source.relative_to(ROOT / 'sdk' / 'wit').as_posix()}", source)
    add_file("spec/scene-api-catalog.json", ROOT / "spec" / "scene-api-catalog.json")
    add_file("spec/value-codec-golden.json", ROOT / "spec" / "value-codec-golden.json")
    add_file("fixtures/rust-conformance.wasm", ROOT / "sdk" / "rust" / "dist" / "module.wasm")
    add_file("expected/rust-conformance.json", ROOT / "conformance" / "expected" / "rust-conformance.json")
    add_file("compatibility-report.json", ROOT / "conformance" / "compatibility-report.json")
    add_file("README.md", ROOT / "conformance" / "README.md")
    add_file("run.py", ROOT / "conformance" / "run.py")
    for name in ("Cargo.toml", "Cargo.lock"):
        add_file(f"conformance/model-host/{name}", ROOT / "conformance" / "model-host" / name)
    add_file(
        "conformance/model-host/src/main.rs",
        ROOT / "conformance" / "model-host" / "src" / "main.rs",
    )
    return sorted(entries)


def build(output: Path = OUTPUT) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(temporary_path, "w", compression=zipfile.ZIP_STORED) as archive:
            for relative, content in files():
                info = zipfile.ZipInfo(relative, FIXED_TIME)
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.flag_bits = 0x800
                archive.writestr(info, content)
        data = temporary_path.read_bytes()
        temporary_path.replace(output)
    finally:
        temporary_path.unlink(missing_ok=True)
    digest = hashlib.sha256(data).hexdigest()
    evidence = {
        "format": 1,
        "version": "1.0.0-draft.1",
        "archive": output.name,
        "sha256": digest,
        "entries": len(files()),
    }
    output.with_suffix(".json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    return digest


if __name__ == "__main__":
    print(f"{build()}  {OUTPUT}")
