#!/usr/bin/env python3
"""Build a canonical VRWeb .vrmod from a manifest and its declared files."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tempfile
import zipfile


FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def safe_path(value: object) -> str:
    path = str(value)
    pure = PurePosixPath(path)
    if not path or pure.is_absolute() or "\\" in path or ":" in path:
        raise ValueError(f"unsafe package path: {path!r}")
    if any(part in ("", ".", "..") for part in pure.parts):
        raise ValueError(f"unsafe package path: {path!r}")
    return path


def declared_paths(manifest: dict) -> list[str]:
    if manifest.get("format") != 1:
        raise ValueError("manifest format must be 1")
    if manifest.get("runtime") != "wasm-component":
        raise ValueError("manifest runtime must be wasm-component")
    if manifest.get("world") != "vrweb:module@1":
        raise ValueError("manifest world must be vrweb:module@1")
    component = safe_path(manifest.get("component", ""))
    if not component.endswith(".wasm"):
        raise ValueError("manifest component must end with .wasm")
    paths = [component]
    assets = manifest.get("assets", {})
    if not isinstance(assets, dict):
        raise ValueError("manifest assets must be an object")
    for spec in assets.values():
        if not isinstance(spec, dict):
            raise ValueError("asset specification must be an object")
        paths.append(safe_path(spec.get("path", "")))
    debug = manifest.get("debug", {})
    if debug:
        if not isinstance(debug, dict) or set(debug) != {"source_map"}:
            raise ValueError("manifest debug must contain only source_map")
        source_map = safe_path(debug.get("source_map", ""))
        if not source_map.endswith(".map"):
            raise ValueError("manifest debug source_map must end with .map")
        paths.append(source_map)
    folded = [path.casefold() for path in paths]
    if len(folded) != len(set(folded)):
        raise ValueError("declared package paths collide")
    return sorted(paths)


def build(manifest_path: Path, output_path: Path) -> str:
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    if not isinstance(manifest, dict):
        raise ValueError("manifest root must be an object")
    root = manifest_path.parent
    entries = [("vrweb-module.json", manifest_bytes)]
    for relative in declared_paths(manifest):
        source = root / relative
        if not source.is_file():
            raise FileNotFoundError(f"declared package file is missing: {source}")
        entries.append((relative, source.read_bytes()))
    entries.sort(key=lambda item: item[0])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=output_path.name + ".", dir=output_path.parent)
    os.close(handle)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
            for relative, content in entries:
                info = zipfile.ZipInfo(relative, FIXED_TIME)
                info.compress_type = zipfile.ZIP_STORED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.flag_bits = 0x800
                archive.writestr(info, content)
        data = Path(temporary).read_bytes()
        os.replace(temporary, output_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    digest = build(args.manifest, args.output)
    print(f"{digest}  {args.output}")


if __name__ == "__main__":
    main()
