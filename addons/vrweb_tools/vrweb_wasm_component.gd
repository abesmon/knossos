@tool
class_name VrwebWasmComponent
extends Node3D

## Authoring-only placeholder for an export from a prebuilt portable WASM package. Maker Kit
## validates and publishes the bytes, but deliberately never instantiates or executes them.

const MANIFEST := "vrweb-module.json"
const MAX_FILES := 512
const MAX_UNPACKED_BYTES := 64 * 1024 * 1024

@export_category("VRWeb WASM component")
@export var module_id := ""
@export var export_name := "default"
@export_file("*.vrmod") var package_path := ""


static func inspect_package(path: String, expected_id: String, expected_export: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return _error("package not found: " + path)
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return _error("package is empty: " + path)
	var reader := ZIPReader.new()
	if reader.open(path) != OK:
		return _error("package is not a valid ZIP: " + path)
	var files := reader.get_files()
	if files.is_empty() or files.size() > MAX_FILES or not files.has(MANIFEST):
		reader.close()
		return _error("package requires vrweb-module.json and at most %d entries" % MAX_FILES)
	var seen := {}
	var contents := {}
	var total := 0
	for raw_path in files:
		var entry := str(raw_path)
		var checked := entry.trim_suffix("/") if entry.ends_with("/") else entry
		var folded := checked.to_lower()
		if not _valid_entry_path(checked) or seen.has(folded):
			reader.close()
			return _error("unsafe or case-colliding package path: " + entry)
		seen[folded] = true
		if entry.ends_with("/"):
			continue
		var entry_bytes := reader.read_file(entry)
		total += entry_bytes.size()
		if total > MAX_UNPACKED_BYTES:
			reader.close()
			return _error("package exceeds unpacked size limit")
		contents[entry] = entry_bytes
	reader.close()
	var parsed = JSON.parse_string((contents[MANIFEST] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return _error("vrweb-module.json is not a JSON object")
	var manifest := parsed as Dictionary
	if int(manifest.get("format", 0)) != 1:
		return _error("unsupported module manifest format")
	if str(manifest.get("id", "")) != expected_id:
		return _error("manifest id does not match node module_id")
	if str(manifest.get("runtime", "")) != "wasm-component":
		return _error("manifest runtime must be wasm-component")
	if str(manifest.get("world", "")) != "vrweb:module@1":
		return _error("manifest world must be vrweb:module@1")
	var component := str(manifest.get("component", ""))
	if not _valid_entry_path(component) or not component.ends_with(".wasm") \
			or not contents.has(component):
		return _error("manifest component must reference a package .wasm file")
	var wasm_files: Array[String] = []
	for entry in contents:
		var file_path := str(entry)
		if file_path.ends_with(".wasm"):
			wasm_files.append(file_path)
		if file_path.get_extension().to_lower() in ["dll", "so", "dylib"]:
			return _error("native libraries are forbidden in .vrmod")
	if wasm_files != [component]:
		return _error("package must contain exactly its declared WASM component")
	var exports = manifest.get("exports", {})
	if not exports is Dictionary or not (exports as Dictionary).has(expected_export):
		return _error("manifest does not declare export: " + expected_export)
	var export_spec = (exports as Dictionary).get(expected_export, {})
	if not export_spec is Dictionary or str((export_spec as Dictionary).get("kind", "")) \
			!= "scene-component":
		return _error("selected export must have kind scene-component")
	var assets = manifest.get("assets", {})
	if not assets is Dictionary:
		return _error("manifest assets must be an object")
	for asset_spec in (assets as Dictionary).values():
		if not asset_spec is Dictionary or not contents.has(str(asset_spec.get("path", ""))):
			return _error("manifest references a missing asset")
	var hash := _sha256(bytes)
	var sorted_files: Array[String] = []
	for entry in contents:
		sorted_files.append(str(entry))
	sorted_files.sort()
	return {"ok": true, "error": "", "bytes": bytes, "hash": hash,
		"sri": "sha256-" + Marshalls.raw_to_base64(_sha256_bytes(bytes)),
		"manifest": manifest, "files": sorted_files}


static func publish(path: String, output_path: String, expected_id: String,
		expected_export: String) -> Dictionary:
	var checked := inspect_package(path, expected_id, expected_export)
	if not bool(checked.ok):
		return checked
	if output_path.is_empty():
		return _error("WASM package publishing requires an output path")
	var relative := "modules/%s.vrmod" % str(checked.hash)
	var target := output_path.get_base_dir().path_join(relative)
	var absolute := ProjectSettings.globalize_path(target)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return _error("cannot create module output directory")
	var needs_write := true
	if FileAccess.file_exists(target):
		needs_write = FileAccess.get_file_as_bytes(target) != checked.bytes
	if needs_write:
		var file := FileAccess.open(target, FileAccess.WRITE)
		if file == null:
			return _error("cannot publish WASM package: " + target)
		file.store_buffer(checked.bytes)
		file.close()
	checked["file"] = relative
	checked["size"] = (checked.bytes as PackedByteArray).size()
	return checked


static func _valid_entry_path(path: String) -> bool:
	if path.is_empty() or path.begins_with("/") or path.contains("\\") or path.contains(":"):
		return false
	for part in path.split("/", false):
		if part.is_empty() or part in [".", ".."]:
			return false
	return true


static func _sha256(bytes: PackedByteArray) -> String:
	return _sha256_bytes(bytes).hex_encode()


static func _sha256_bytes(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
