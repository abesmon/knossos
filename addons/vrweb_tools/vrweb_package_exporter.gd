@tool
class_name VrwebPackageExporter
extends RefCounted

## Package-срез: source GDScript + рекурсивные .gd и literal relative file dependencies.


static func build(script: GDScript, module_id: String, output_path: String,
		base_class: String, requires: Array[String] = ["vrweb/core/1", "vrweb/scene/1",
				"godot/engine/4"], optional: Array[String] = ["vrweb/state/1", "vrweb/input/1",
				"vrweb/assets/1", "vrweb/timers/1", "vrweb/log/1"]) -> Dictionary:
	if script.resource_path.is_empty() or not script.resource_path.begins_with("res://"):
		return _error("package требует сохранённый GDScript из res://")
	var collected := _collect_scripts(script.resource_path)
	if not bool(collected.ok):
		return collected
	var files: Dictionary = collected.files
	var assets: Dictionary = collected.assets
	var main_path := script.resource_path.trim_prefix("res://")
	var manifest := {
		"format": 1, "id": module_id, "version": "0.0.0", "knossos_api": "1",
		"runtime": "trusted-gdscript",
		"exports": {"default": {"script": main_path, "base": base_class}},
		"assets": assets,
		"permissions": [],
		"requires": requires, "optional": optional,
	}
	var packer := ZIPPacker.new()
	if packer.open(output_path) != OK:
		return _error("не удалось создать %s" % output_path)
	var entries: Array[String] = ["vrweb-module.json"]
	entries.append_array(files.keys())
	entries.sort()
	for entry in entries:
		var bytes: PackedByteArray = JSON.stringify(manifest, "  ").to_utf8_buffer() \
				if entry == "vrweb-module.json" else files[entry]
		if packer.start_file(entry) != OK or packer.write_file(bytes) != OK:
			packer.close()
			return _error("не удалось записать entry %s" % entry)
		packer.close_file()
	packer.close()
	var package_bytes := FileAccess.get_file_as_bytes(output_path)
	if package_bytes.is_empty():
		return _error("создан пустой package")
	return {"ok": true, "error": "", "integrity": ScriptingModuleIntegrity.sri_sha256(package_bytes),
		"hash": _sha256_hex(package_bytes), "files": files.keys(), "assets": assets}


static func _collect_scripts(entry_path: String) -> Dictionary:
	var pending: Array[String] = [entry_path]
	var seen := {}
	var files := {}
	var asset_paths: Array[String] = []
	while not pending.is_empty():
		var path := pending.pop_back()
		if seen.has(path):
			continue
		seen[path] = true
		if not FileAccess.file_exists(path):
			return _error("package dependency недоступен: %s" % path)
		var source := FileAccess.get_file_as_string(path) if _is_text_resource(path) else ""
		if path.ends_with(".gd") and (source.contains("@tool") or source.contains("class_name") \
				or source.contains("res://")):
			return _error("script %s содержит @tool/class_name/res://; package требует переносимый relative source" % path)
		var raw_dependencies: Array[String] = []
		for raw_dependency in ResourceLoader.get_dependencies(path):
			raw_dependencies.append(str(raw_dependency))
		if path.ends_with(".gd"):
			raw_dependencies.append_array(_source_dependencies(source, path))
		elif _is_text_resource(path):
			raw_dependencies.append_array(_resource_paths(source))
			source = _rewrite_resource_paths(source, path)
		var package_path := _package_path(path)
		var file_bytes := source.to_utf8_buffer() if _is_text_resource(path) \
				else _resource_bytes(path)
		if file_bytes.is_empty():
			return _error("не удалось подготовить package dependency: %s" % path)
		files[package_path] = file_bytes
		if not path.ends_with(".gd"):
			asset_paths.append(path.trim_prefix("res://"))
		for raw_dependency in raw_dependencies:
			var dependency := _dependency_path(str(raw_dependency))
			if dependency == "":
				continue
			pending.append(dependency)
	asset_paths.sort()
	var assets := {}
	for asset_path in asset_paths:
		var asset_id := _asset_id(asset_path, assets)
		assets[asset_id] = {"path": _package_path("res://" + asset_path),
			"type": _resource_type("res://" + asset_path)}
	return {"ok": true, "error": "", "files": files, "assets": assets}


static func _resource_type(path: String) -> String:
	if path.ends_with(".tscn") or path.ends_with(".scn"):
		return "PackedScene"
	if path.ends_with(".tres") or path.ends_with(".res") or _is_imported_source(path):
		var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		return resource.get_class() if resource != null else "Resource"
	return ""


static func _package_path(path: String) -> String:
	var relative := path.trim_prefix("res://")
	return relative + ".res" if _is_imported_source(path) else relative


static func _is_imported_source(path: String) -> bool:
	return path.get_extension().to_lower() in [
		"png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "dds", "ktx",
		"ogg", "wav", "mp3", "glb", "gltf",
	]


static func _resource_bytes(path: String) -> PackedByteArray:
	if not _is_imported_source(path):
		return FileAccess.get_file_as_bytes(path)
	var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if resource == null:
		return PackedByteArray()
	var temp := "user://scripting_module_export/%s.res" % path.sha256_text()
	DirAccess.make_dir_recursive_absolute(temp.get_base_dir())
	if ResourceSaver.save(resource, temp, ResourceSaver.FLAG_BUNDLE_RESOURCES) != OK:
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(temp)
	DirAccess.remove_absolute(temp)
	return bytes


static func _is_text_resource(path: String) -> bool:
	return path.ends_with(".gd") or path.ends_with(".tscn") or path.ends_with(".tres")


static func _resource_paths(source: String) -> Array[String]:
	var out: Array[String] = []
	var regex := RegEx.new()
	regex.compile("(?:path|script)=\"(res://[^\"]+)\"")
	for match in regex.search_all(source):
		var path := match.get_string(1)
		if not out.has(path):
			out.append(path)
	return out


static func _rewrite_resource_paths(source: String, owner_path: String) -> String:
	var regex := RegEx.new()
	regex.compile("((?:path|script)=\")(res://[^\"]+)(\")")
	var result := source
	var matches := regex.search_all(source)
	matches.reverse()
	for match in matches:
		var target := match.get_string(2)
		var owner_package := "res://" + _package_path(owner_path)
		var target_package := "res://" + _package_path(target)
		var relative := _relative_path(owner_package.get_base_dir(), target_package)
		result = result.substr(0, match.get_start(2)) + relative \
				+ result.substr(match.get_end(2))
	return result


static func _relative_path(from_dir: String, target: String) -> String:
	var from_parts := from_dir.trim_prefix("res://").split("/", false)
	var target_parts := target.trim_prefix("res://").split("/", false)
	while not from_parts.is_empty() and not target_parts.is_empty() \
			and from_parts[0] == target_parts[0]:
		from_parts.remove_at(0)
		target_parts.remove_at(0)
	var parts: Array[String] = []
	for _part in from_parts:
		parts.append("..")
	for part in target_parts:
		parts.append(str(part))
	return "./" + "/".join(parts) if from_parts.is_empty() else "/".join(parts)


static func _asset_id(path: String, existing: Dictionary) -> String:
	var candidate := path.get_file().get_basename().to_snake_case()
	var safe := ""
	for character in candidate:
		safe += character if character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789_-" else "_"
	if safe.is_empty() or not safe[0].to_lower() in "abcdefghijklmnopqrstuvwxyz_":
		safe = "asset_" + safe
	if not existing.has(safe):
		return safe
	return "%s_%s" % [safe, path.sha256_text().left(8)]


static func _source_dependencies(source: String, owner_path: String) -> Array[String]:
	var out: Array[String] = []
	var regex := RegEx.new()
	regex.compile("(?:preload|load)\\s*\\(\\s*[\"']([^\"']+)[\"']\\s*\\)")
	for match in regex.search_all(source):
		var dependency := match.get_string(1)
		if dependency.begins_with("./") or dependency.begins_with("../"):
			dependency = owner_path.get_base_dir().path_join(dependency).simplify_path()
		if not out.has(dependency):
			out.append(dependency)
	return out


static func _dependency_path(raw: String) -> String:
	for part in raw.split("::"):
		if part.begins_with("res://"):
			return part
		if part.begins_with("uid://"):
			var resolved := ResourceUID.get_id_path(ResourceUID.text_to_id(part))
			if resolved.begins_with("res://"):
				return resolved
	if raw.begins_with("uid://"):
		return ResourceUID.get_id_path(ResourceUID.text_to_id(raw))
	return raw if raw.begins_with("res://") else ""


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message, "files": {}, "assets": {}}
