#!/usr/bin/env python3

from pathlib import Path
import json
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build_vrmod import build  # noqa: E402


with tempfile.TemporaryDirectory() as temporary:
    first = Path(temporary) / "first.vrmod"
    second = Path(temporary) / "second.vrmod"
    manifest = ROOT / "native" / "vrweb_wasm_runtime" / "fixtures" / "vrweb-module.json"
    first_hash = build(manifest, first)
    second_hash = build(manifest, second)
    assert first.read_bytes() == second.read_bytes()
    assert first_hash == second_hash
    with zipfile.ZipFile(first) as archive:
        assert archive.namelist() == ["lifecycle.wasm", "vrweb-module.json"]
        assert all(info.date_time == (1980, 1, 1, 0, 0, 0) for info in archive.infolist())
    debug_root = Path(temporary) / "debug-input"
    debug_root.mkdir()
    source_manifest = json.loads(manifest.read_text(encoding="utf-8"))
    source_manifest["debug"] = {"source_map": "debug/module.wasm.map"}
    (debug_root / "vrweb-module.json").write_text(
        json.dumps(source_manifest), encoding="utf-8")
    (debug_root / "lifecycle.wasm").write_bytes((manifest.parent / "lifecycle.wasm").read_bytes())
    (debug_root / "debug").mkdir()
    (debug_root / "debug/module.wasm.map").write_text(
        '{"version":3,"sources":["src/module.ts"]}', encoding="utf-8")
    debug_package = Path(temporary) / "debug.vrmod"
    build(debug_root / "vrweb-module.json", debug_package)
    with zipfile.ZipFile(debug_package) as archive:
        assert archive.namelist() == [
            "debug/module.wasm.map", "lifecycle.wasm", "vrweb-module.json"]
print("deterministic .vrmod packaging: PASS")
