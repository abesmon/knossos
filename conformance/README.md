# VRWeb WASM conformance suite

This directory is the source of the engine-independent conformance archive. The release contains
the normative WIT tree, Scene API catalog, unchanged WASM fixture, canonical expected trace,
coverage report and a Wasmtime model host. It does not contain or link Knossos or Godot code.

Build and verify the archive after building `sdk/rust/dist/module.wasm`:

```bash
python3 tools/build_wasm_conformance.py
python3 tests/test_wasm_conformance_archive.py
```

An extracted archive is self-testing:

```bash
python3 run.py
```

The compatibility report is deliberately not a `full` profile until every mandatory class,
property, method, signal and portable host interface has an executable test. The runner rejects a
report that claims full compatibility while any mandatory coverage is listed as missing.
