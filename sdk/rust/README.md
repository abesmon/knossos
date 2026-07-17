# VRWeb Rust conformance oracle

This crate is the compact second-language ABI oracle for `vrweb:module@1`. It is intentionally
not the primary creator-facing SDK. It compiles against the same standalone WIT tree as the
JavaScript adapter and produces a component with no WASI imports.

```bash
python3 sdk/rust/build.py
```

The command uses pinned Rust 1.94.0 and `wit-bindgen` 0.55.0, creates the component twice, requires
byte equality, and packages it as a canonical `.vrmod` with SDK/build evidence.
