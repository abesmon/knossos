use std::fs;
use std::path::PathBuf;

fn main() {
    let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for name in [
        "answer",
        "wasi_import",
        "unknown_import",
        "scene_import_unavailable",
        "scene_import_incompatible_major",
        "scene_lifecycle",
        "portable_services",
        "core_module",
        "infinite_loop",
        "memory_grow",
        "table_grow",
        "trap",
        "lifecycle",
        "host_call_flood",
        "lifecycle_trap_create",
        "lifecycle_trap_mount",
        "lifecycle_trap_event_unmount",
    ] {
        let source = crate_root.join(format!("fixtures/{name}.wat"));
        let output = crate_root.join(format!("fixtures/{name}.wasm"));
        let bytes = wat::parse_file(&source)
            .unwrap_or_else(|error| panic!("parse {}: {error:#}", source.display()));
        fs::write(&output, bytes)
            .unwrap_or_else(|error| panic!("write {}: {error}", output.display()));
        println!("generated {}", output.display());
    }
}
