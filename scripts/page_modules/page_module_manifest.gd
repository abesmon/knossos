class_name PageModuleManifest
extends RefCounted

## Parser/validator vrweb-module.json format 1. Не трогает ZIP и не исполняет exports.

const FORMAT := 1
const MAX_MANIFEST_BYTES := 64 * 1024
const MAX_EXPORTS := 64
const MAX_ASSETS := 256
const MAX_PERMISSIONS := 64


static func parse(bytes: PackedByteArray, declared_id: String = "") -> Dictionary:
	var errors: Array[String] = []
	if bytes.size() > MAX_MANIFEST_BYTES:
		return _result({}, ["manifest превышает %d байт" % MAX_MANIFEST_BYTES])
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK:
		return _result({}, ["невалидный JSON manifest: строка %d: %s" \
				% [json.get_error_line(), json.get_error_message()]])
	if typeof(json.data) != TYPE_DICTIONARY:
		return _result({}, ["корень manifest должен быть object"])
	var raw: Dictionary = json.data
	if int(raw.get("format", 0)) != FORMAT:
		errors.append("неподдерживаемый manifest format «%s»" % str(raw.get("format")))
	var id := str(raw.get("id", ""))
	var id_error := PageModuleCollector._id_error(id)
	if not id_error.is_empty():
		errors.append(id_error)
	if not declared_id.is_empty() and id != declared_id:
		errors.append("manifest id «%s» не совпадает с объявленным «%s»" % [id, declared_id])
	var runtime := str(raw.get("runtime", PageModuleCollector.RUNTIME_TRUSTED))
	if not PageModuleCollector._valid_runtime(runtime):
		errors.append("неизвестный runtime «%s»" % runtime)
	var exports = raw.get("exports", {})
	if typeof(exports) != TYPE_DICTIONARY or (exports as Dictionary).is_empty():
		errors.append("manifest требует непустой exports object")
		exports = {}
	elif (exports as Dictionary).size() > MAX_EXPORTS:
		errors.append("exports превышает лимит %d" % MAX_EXPORTS)
	var normalized_exports := {}
	for export_name in exports:
		var export_error := PageModuleCollector._id_error(str(export_name))
		if not export_error.is_empty():
			errors.append("export: " + export_error)
			continue
		var spec = exports[export_name]
		if typeof(spec) != TYPE_DICTIONARY:
			errors.append("export «%s» должен быть object" % export_name)
			continue
		var script := str((spec as Dictionary).get("script", ""))
		var scene := str((spec as Dictionary).get("scene", ""))
		if script.is_empty() == scene.is_empty():
			errors.append("export «%s» требует ровно один script или scene" % export_name)
			continue
		var path := script if not script.is_empty() else scene
		if not valid_module_path(path):
			errors.append("export «%s» содержит небезопасный путь «%s»" % [export_name, path])
			continue
		normalized_exports[str(export_name)] = {
			"script": script, "scene": scene,
			"base": str((spec as Dictionary).get("base", "Node")),
		}
	var assets = raw.get("assets", {})
	if typeof(assets) != TYPE_DICTIONARY or (assets as Dictionary).size() > MAX_ASSETS:
		errors.append("assets должен быть object размером до %d" % MAX_ASSETS)
		assets = {}
	var normalized_assets := {}
	for asset_name in assets:
		var asset_error := PageModuleCollector._id_error(str(asset_name))
		if not asset_error.is_empty():
			errors.append("asset: " + asset_error)
			continue
		var spec = assets[asset_name]
		if typeof(spec) != TYPE_DICTIONARY:
			errors.append("asset «%s» должен быть object" % asset_name)
			continue
		var path := str((spec as Dictionary).get("path", ""))
		if not valid_module_path(path):
			errors.append("asset «%s» содержит небезопасный путь «%s»" % [asset_name, path])
			continue
		normalized_assets[str(asset_name)] = {
			"path": path, "type": str((spec as Dictionary).get("type", "")),
		}
	var permissions = raw.get("permissions", [])
	if typeof(permissions) != TYPE_ARRAY or (permissions as Array).size() > MAX_PERMISSIONS:
		errors.append("permissions должен быть array размером до %d" % MAX_PERMISSIONS)
		permissions = []
	var normalized_permissions: Array[String] = []
	for permission in permissions:
		if typeof(permission) != TYPE_STRING or str(permission).is_empty():
			errors.append("permission должен быть непустой строкой")
		else:
			normalized_permissions.append(str(permission))
	var normalized := {
		"format": FORMAT, "id": id, "version": str(raw.get("version", "0.0.0")),
		"knossos_api": str(raw.get("knossos_api", "1")), "runtime": runtime,
		"exports": normalized_exports, "assets": normalized_assets,
		"permissions": normalized_permissions,
	}
	return _result(normalized, errors)


static func valid_module_path(path: String) -> bool:
	if path.is_empty() or path.begins_with("/") or path.contains("\\") \
			or path.contains("://") or path.begins_with("res:") or path.begins_with("user:"):
		return false
	for segment in path.split("/", false):
		if segment == "." or segment == ".." or segment.is_empty():
			return false
	return true


static func _result(manifest: Dictionary, errors: Array[String]) -> Dictionary:
	return {"ok": errors.is_empty(), "manifest": manifest, "errors": errors}
