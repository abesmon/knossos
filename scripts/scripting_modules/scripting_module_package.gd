class_name ScriptingModulePackage
extends RefCounted

## Проверяет и извлекает уже integrity-verified .vrmod из content cache.

const MANIFEST := "vrweb-module.json"
const UNPACK_ROOT := "user://scripting_module_cache/unpacked/"
const MAX_FILES := 512
const MAX_UNPACKED_BYTES := 64 * 1024 * 1024


static func unpack(module: Dictionary) -> Dictionary:
	var hash := str(module.get("hash", ""))
	if not ScriptingModuleCache.valid_hash(hash):
		return _error("invalid_hash")
	var archive_path := Sandbox.resolve(str(module.get("cache_path", ScriptingModuleCache.path_for(hash))))
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
	for export_spec in parsed.manifest.exports.values():
		var path := str(export_spec.script) if not str(export_spec.script).is_empty() \
				else str(export_spec.scene)
		if not contents.has(path):
			return _error("missing_export_file")
	for asset_spec in parsed.manifest.assets.values():
		if not contents.has(str(asset_spec.path)):
			return _error("missing_asset_file")
	var root := UNPACK_ROOT.path_join(hash)
	var absolute_root := Sandbox.resolve(root)
	DirAccess.make_dir_recursive_absolute(absolute_root)
	for path in contents:
		var output := absolute_root.path_join(str(path))
		DirAccess.make_dir_recursive_absolute(output.get_base_dir())
		var file := FileAccess.open(output, FileAccess.WRITE)
		if file == null:
			return _error("extract_write_failed")
		file.store_buffer(contents[path])
		file.close()
	module["manifest"] = parsed.manifest
	module["exports"] = parsed.manifest.exports
	module["module_root"] = root
	return {"ok": true, "module": module, "error": "", "errors": []}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "module": {}, "error": code, "errors": []}
