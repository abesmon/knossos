extends SceneTree

var _failed := false
var _archive_seq := 0


func _initialize() -> void:
	var bytes := FileAccess.get_file_as_bytes("res://test_pages/lights.vrmod")
	var cached := ScriptingModuleCache.store(bytes)
	_eq(cached.ok, true, "WASM package cached")
	var unpacked := ScriptingModulePackage.unpack({
		"id": "external.tiny",
		"hash": cached.hash,
		"cache_path": cached.path,
	})
	_eq(unpacked.ok, true, "WASM package validated and unpacked")
	if bool(unpacked.ok):
		var module: Dictionary = unpacked.module
		_eq(module.manifest.runtime, "wasm-component", "runtime preserved")
		_eq(module.manifest.world, "vrweb:module@1", "world preserved")
		_eq(module.exports.default.kind, "scene-component", "export preserved")
		_eq(FileAccess.file_exists(module.component_path), true, "component extracted")
		_eq(str(module.execution_key).length(), 64, "validated package gets execution cache key")
	_test_direct_component()
	_test_substituted_archive(cached)
	_test_rejected_packages()
	quit(1 if _failed else 0)


func _test_direct_component() -> void:
	var wasm := FileAccess.get_file_as_bytes(
			"res://native/vrweb_wasm_runtime/fixtures/lifecycle.wasm")
	var cached := ScriptingModuleCache.store(wasm)
	var manifest: Dictionary = JSON.parse_string(_manifest("external.direct").get_string_from_utf8())
	var unpacked := ScriptingModulePackage.unpack({
		"id": "external.direct", "kind": "component", "hash": cached.hash,
		"cache_path": cached.path, "manifest": manifest,
	})
	_eq(unpacked.ok, true, "content-addressed direct WASM prepared")
	if bool(unpacked.ok):
		_eq(FileAccess.get_file_as_bytes(unpacked.module.component_path), wasm,
				"direct component bytes preserved exactly")
		_eq(str(unpacked.module.execution_key).length(), 64,
				"direct component gets contract-bound execution key")
	var changed := manifest.duplicate(true)
	changed.id = "substituted.id"
	var rejected := ScriptingModulePackage.unpack({
		"id": "external.direct", "kind": "component", "hash": cached.hash,
		"cache_path": cached.path, "manifest": changed,
	})
	_eq(rejected.error, "invalid_manifest", "direct manifest identity substitution rejected")


func _test_substituted_archive(cached: Dictionary) -> void:
	var other := ScriptingModuleCache.store("not the package".to_utf8_buffer())
	var result := ScriptingModulePackage.unpack({
		"id": "external.tiny",
		"hash": cached.hash,
		"cache_path": other.path,
	})
	_eq(result.ok, false, "cache path cannot substitute bytes for a valid hash")
	_eq(result.error, "artifact_hash_mismatch", "substitution has stable error code")


func _test_rejected_packages() -> void:
	var wasm := FileAccess.get_file_as_bytes(
			"res://native/vrweb_wasm_runtime/fixtures/lifecycle.wasm")
	var valid_manifest := _manifest("external.tiny")
	_expect_error([
		{"path": "vrweb-module.json", "bytes": valid_manifest},
		{"path": "module.wasm", "bytes": wasm},
		{"path": "second.wasm", "bytes": wasm},
	], "external.tiny", "invalid_component_entries", "duplicate WASM component rejected")
	_expect_error([
		{"path": "vrweb-module.json", "bytes": valid_manifest},
		{"path": "module.wasm", "bytes": wasm},
		{"path": "plugin.dylib", "bytes": PackedByteArray([1])},
	], "external.tiny", "native_library_forbidden", "native library rejected")
	_expect_error([
		{"path": "vrweb-module.json", "bytes": valid_manifest},
		{"path": "module.wasm", "bytes": wasm},
		{"path": "hidden.txt", "bytes": PackedByteArray([1])},
	], "external.tiny", "undeclared_package_entry", "undeclared sidecar rejected")
	_expect_error([
		{"path": "vrweb-module.json", "bytes": _manifest("changed.id")},
		{"path": "module.wasm", "bytes": wasm},
	], "external.tiny", "invalid_manifest", "changed manifest identity rejected")
	_expect_error([
		{"path": "vrweb-module.json", "bytes": valid_manifest},
		{"path": "module.wasm", "bytes": wasm},
		{"path": "../escape.txt", "bytes": PackedByteArray([1])},
	], "external.tiny", "unsafe_path", "ZIP traversal rejected")
	var asset_manifest := JSON.stringify({
		"format": 1, "id": "external.tiny", "runtime": "wasm-component",
		"world": "vrweb:module@1", "component": "module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"requires": ["vrweb:core/1"], "optional": [],
		"assets": {"missing": {"path": "assets/missing.bin", "type": "bytes"}},
	}).to_utf8_buffer()
	_expect_error([
		{"path": "vrweb-module.json", "bytes": asset_manifest},
		{"path": "module.wasm", "bytes": wasm},
	], "external.tiny", "missing_asset_file", "missing manifest asset rejected")
	var debug_manifest: Dictionary = JSON.parse_string(_manifest("external.tiny").get_string_from_utf8())
	debug_manifest["debug"] = {"source_map": "debug/module.wasm.map"}
	_expect_error([
		{"path": "vrweb-module.json", "bytes": JSON.stringify(debug_manifest).to_utf8_buffer()},
		{"path": "module.wasm", "bytes": wasm},
	], "external.tiny", "missing_debug_sidecar", "declared debug sidecar must exist")


func _manifest(id: String) -> PackedByteArray:
	return JSON.stringify({
		"format": 1, "id": id, "runtime": "wasm-component", "world": "vrweb:module@1",
		"component": "module.wasm", "exports": {"default": {"kind": "scene-component"}},
		"requires": ["vrweb:core/1"], "optional": [],
	}).to_utf8_buffer()


func _expect_error(entries: Array, declared_id: String, expected: String, label: String) -> void:
	var path := "user://package-negative-%d.vrmod" % _archive_seq
	_archive_seq += 1
	var packer := ZIPPacker.new()
	_eq(packer.open(path), OK, label + " fixture opens")
	for entry in entries:
		_eq(packer.start_file(str(entry.path)), OK, label + " fixture entry")
		packer.write_file(entry.bytes)
		packer.close_file()
	packer.close()
	var cached := ScriptingModuleCache.store(FileAccess.get_file_as_bytes(path))
	var result := ScriptingModulePackage.unpack({
		"id": declared_id, "hash": cached.hash, "cache_path": cached.path,
	})
	_eq(result.ok, false, label)
	_eq(result.error, expected, label + " error code")


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
