# WASM Scene demo

This is the source of the visible `test_pages/wasm_scene_demo.html` example. It demonstrates the
prebuilt-component Maker workflow without relying on Knossos internals:

1. Rust compiles against the standalone `sdk/wit` contract.
2. `wit-component` turns the core module into a WebAssembly Component.
3. The canonical packager combines `module.wasm` and `vrweb-module.json` into `.vrmod`.
4. HTML declares the package with `VRWebModule` and creates it with `VRWebComponent`.
5. `create()` receives only its scoped Scene root and adds a cube, label and light beneath it.

Build it with pinned Rust 1.94:

```bash
python3 examples/wasm-scene-demo/build.py
```

Then open `vrwebresource://wasm_scene_demo.html` in Knossos. The committed `.vrmod` lets the demo
run in a normal exported client without Rust or build tools installed.

For the primary TypeScript authoring path, use Maker Kit's **Add VRWeb Script** action. It creates
the same four lifecycle exports and packages the resulting Component through the JavaScript
adapter; see `docs/maker-kit.md`.
