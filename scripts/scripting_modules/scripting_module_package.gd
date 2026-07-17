class_name ScriptingModulePackage
extends RefCounted

## Проверяет и извлекает уже integrity-verified .vrmod из content cache.

const MANIFEST := "vrweb-module.json"
const UNPACK_ROOT := "user://scripting_module_cache/unpacked/"
const MAX_FILES := 512
const MAX_UNPACKED_BYTES := 64 * 1024 * 1024


static func unpack(module: Dictionary) -> Dictionary:
	var module_hash := str(module.get("hash", ""))
	if not ScriptingModuleCache.valid_hash(module_hash):
		return _error("invalid_hash")
	var archive_path := Sandbox.resolve(str(module.get("cache_path",
			ScriptingModuleCache.path_for(module_hash))))
	if not FileAccess.file_exists(archive_path):
		return _error("missing_artifact")
	# cache_path is caller metadata, not authority. Bind the bytes again before opening ZIP so a
	# valid hash cannot be paired with an arbitrary local archive.
	var archive_bytes := FileAccess.get_file_as_bytes(archive_path)
	if ScriptingModuleCache._sha256_hex(archive_bytes) != module_hash:
		return _error("artifact_hash_mismatch")
	if str(module.get("kind", "package")) == "component":
		return _unpack_direct_component(module, module_hash, archive_bytes)
	var reader := ZIPReader.new()
	if reader.open(archive_path) != OK:
		return _error("invalid_zip")
	var files := reader.get_files()
	if files.is_empty() or files.size() > MAX_FILES or not files.has(MANIFEST):
		reader.close()
		return _error("invalid_file_list")
	var seen := {}
	var seen_folded := {}
	var contents := {}
	var total := 0
	for path in files:
		var normalized := str(path)
		var is_directory := normalized.ends_with("/")
		var checked_path := normalized.trim_suffix("/") if is_directory else normalized
		var folded := checked_path.to_lower()
		if not ScriptingModuleManifest.valid_module_path(checked_path) or seen.has(checked_path) \
				or seen_folded.has(folded):
			reader.close()
			return _error("unsafe_path")
		seen[checked_path] = true
		seen_folded[folded] = true
		if is_directory:
			continue
		var bytes := reader.read_file(normalized)
		total += bytes.size()
		if total > MAX_UNPACKED_BYTES:
			reader.close()
			return _error("unpacked_too_large")
		contents[normalized] = bytes
	reader.close()
	var parsed := ScriptingModuleManifest.parse(contents[MANIFEST], str(module.get("id", "")))
	if not bool(parsed.ok):
		return {"ok": false, "error": "invalid_manifest", "errors": parsed.errors}
	var component_path := str(parsed.manifest.component)
	if not contents.has(component_path):
		return _error("missing_component")
	var wasm_files: Array[String] = []
	for path in contents:
		var file_path := str(path)
		if file_path.ends_with(".wasm"):
			wasm_files.append(file_path)
		if file_path.get_extension().to_lower() in ["dll", "so", "dylib"]:
			return _error("native_library_forbidden")
	if wasm_files != [component_path]:
		return _error("invalid_component_entries")
	var declared_files := {MANIFEST: true, component_path: true}
	for asset_spec in parsed.manifest.assets.values():
		if not contents.has(str(asset_spec.path)):
			return _error("missing_asset_file")
		declared_files[str(asset_spec.path)] = true
	var debug: Dictionary = parsed.manifest.get("debug", {})
	if not debug.is_empty():
		var source_map := str(debug.source_map)
		if not contents.has(source_map):
			return _error("missing_debug_sidecar")
		declared_files[source_map] = true
	for path in contents:
		if not declared_files.has(str(path)):
			return _error("undeclared_package_entry")
	# Registry must load from the same sandboxed path into which files are extracted. Keeping
	# unsandboxed user:// here works only when Sandbox.id() is empty and breaks isolated clients.
	var module_root := Sandbox.resolve(UNPACK_ROOT.path_join(module_hash))
	var absolute_module_root := module_root
	DirAccess.make_dir_recursive_absolute(absolute_module_root)
	for path in contents:
		var output := absolute_module_root.path_join(str(path))
		DirAccess.make_dir_recursive_absolute(output.get_base_dir())
		var file := FileAccess.open(output, FileAccess.WRITE)
		if file == null:
			return _error("extract_write_failed")
		file.store_buffer(contents[path])
		file.close()
	module["manifest"] = parsed.manifest
	module["exports"] = parsed.manifest.exports
	module["component_path"] = module_root.path_join(component_path)
	module["module_root"] = module_root
	module["debug_source_map_path"] = module_root.path_join(str(debug.source_map)) \
			if not debug.is_empty() else ""
	module["execution_key"] = ScriptingModuleCache.execution_key(module_hash, parsed.manifest)
	return {"ok": true, "module": module, "error": "", "errors": []}


static func _unpack_direct_component(module: Dictionary, module_hash: String,
		component_bytes: PackedByteArray) -> Dictionary:
	if component_bytes.size() > ScriptingModuleCache.MAX_ARTIFACT_BYTES:
		return _error("component_too_large")
	var manifest: Dictionary = module.get("manifest", {})
	var parsed := ScriptingModuleManifest.parse(
			JSON.stringify(manifest).to_utf8_buffer(), str(module.get("id", "")))
	if not bool(parsed.ok):
		return {"ok": false, "module": {}, "error": "invalid_manifest", "errors": parsed.errors}
	if str(parsed.manifest.component) != "module.wasm":
		return _error("invalid_direct_component_name")
	var module_root := Sandbox.resolve(UNPACK_ROOT.path_join(module_hash))
	DirAccess.make_dir_recursive_absolute(module_root)
	var component_path := module_root.path_join("module.wasm")
	var output := FileAccess.open(component_path, FileAccess.WRITE)
	if output == null:
		return _error("extract_write_failed")
	output.store_buffer(component_bytes)
	output.close()
	module["manifest"] = parsed.manifest
	module["exports"] = parsed.manifest.exports
	module["component_path"] = component_path
	module["module_root"] = module_root
	module["debug_source_map_path"] = ""
	module["execution_key"] = ScriptingModuleCache.execution_key(module_hash, parsed.manifest)
	return {"ok": true, "module": module, "error": "", "errors": []}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "module": {}, "error": code, "errors": []}
