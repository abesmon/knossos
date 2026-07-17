extends Node

## Minimal smoke intended to run from an exported debug client, not only from the editor binary.


func _ready() -> void:
	var failed := false
	failed = not _check(NativeWasmBackend.is_available(), "export contains native WASM runtime") \
			or failed
	var package_path := "res://tests/fixtures/wasm_delivery/lifecycle.vrmod"
	failed = not _check(FileAccess.file_exists(package_path), "export contains declared .vrmod") \
			or failed
	if failed:
		get_tree().quit(1)
		return
	var cached := ScriptingModuleCache.store(FileAccess.get_file_as_bytes(package_path))
	var unpacked := ScriptingModulePackage.unpack({
		"id": "fixture.delivery-lifecycle", "hash": cached.hash, "cache_path": cached.path})
	failed = not _check(bool(unpacked.get("ok", false)), "export validates and unpacks .vrmod") \
			or failed
	if not bool(unpacked.get("ok", false)):
		get_tree().quit(1)
		return
	var backend := NativeWasmBackend.new()
	var prepared := backend.prepare([unpacked.module])
	failed = not _check(bool(prepared.ok), "export compiles Component Model module") or failed
	if bool(prepared.ok):
		var made := backend.instantiate_export("fixture.delivery-lifecycle", "default")
		failed = not _check(str(made.error).is_empty() and made.node != null,
				"export executes create and mount") or failed
		if made.node != null:
			add_child(made.node)
			var delivered := backend.deliver_event(
					"fixture.delivery-lifecycle", {"kind": "export-smoke"})
			failed = not _check(bool(delivered.ok), "export delivers event") or failed
			made.node.free()
	backend.close()
	print("VRWEB_EXPORTED_WASM_SMOKE PASS" if not failed else "VRWEB_EXPORTED_WASM_SMOKE FAIL")
	get_tree().quit(1 if failed else 0)


func _check(ok: bool, label: String) -> bool:
	if ok: print("  [ok]  ", label)
	else: push_error("FAIL: " + label)
	return ok
