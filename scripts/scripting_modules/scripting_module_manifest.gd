class_name ScriptingModuleManifest
extends RefCounted

## Parser/validator vrweb-module.json format 1 для WebAssembly Component packages.

const FORMAT := 1
const MAX_MANIFEST_BYTES := 64 * 1024
const MAX_EXPORTS := 64
const MAX_ASSETS := 256
const MAX_CAPABILITIES := 64
const DEFAULT_LIMITS := {
	"fuel": 1_000_000,
	"memory_bytes": 16 * 1024 * 1024,
	"deadline_ms": 50,
	"host_calls": 64,
	"instances": 16,
	"tables": 16,
	"memories": 8,
}
const MAX_LIMITS := {
	"fuel": 50_000_000,
	"memory_bytes": 16 * 1024 * 1024,
	"deadline_ms": 50,
	"host_calls": 64,
	"instances": 16,
	"tables": 16,
	"memories": 8,
}


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
	var id_error := ScriptingModuleCollector._id_error(id)
	if not id_error.is_empty():
		errors.append(id_error)
	if not declared_id.is_empty() and id != declared_id:
		errors.append("manifest id «%s» не совпадает с объявленным «%s»" % [id, declared_id])
	var runtime := str(raw.get("runtime", ""))
	if runtime != ScriptingModuleCollector.RUNTIME_WASM:
		errors.append("неизвестный runtime «%s»" % runtime)
	var world := str(raw.get("world", ""))
	if world != ScriptingModuleCollector.SUPPORTED_WORLD:
		errors.append("несовместимый world «%s»" % world)
	var component := str(raw.get("component", ""))
	if not valid_module_path(component) or not component.ends_with(".wasm"):
		errors.append("component должен быть безопасным путём к .wasm")
	var exports = raw.get("exports", {})
	if typeof(exports) != TYPE_DICTIONARY or (exports as Dictionary).is_empty():
		errors.append("manifest требует непустой exports object")
		exports = {}
	elif (exports as Dictionary).size() > MAX_EXPORTS:
		errors.append("exports превышает лимит %d" % MAX_EXPORTS)
	var normalized_exports := {}
	for export_name in exports:
		var export_error := ScriptingModuleCollector._id_error(str(export_name))
		if not export_error.is_empty():
			errors.append("export: " + export_error)
			continue
		var spec = exports[export_name]
		if typeof(spec) != TYPE_DICTIONARY or str((spec as Dictionary).get("kind", "")) != "scene-component":
			errors.append("export «%s» требует kind scene-component" % export_name)
			continue
		normalized_exports[str(export_name)] = {"kind": "scene-component"}
	var assets = raw.get("assets", {})
	if typeof(assets) != TYPE_DICTIONARY or (assets as Dictionary).size() > MAX_ASSETS:
		errors.append("assets должен быть object размером до %d" % MAX_ASSETS)
		assets = {}
	var normalized_assets := {}
	for asset_name in assets:
		var asset_error := ScriptingModuleCollector._id_error(str(asset_name))
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
		normalized_assets[str(asset_name)] = {"path": path, "type": str((spec as Dictionary).get("type", ""))}
	var normalized_requires := _capabilities(raw.get("requires", []), "requires", errors)
	var normalized_optional := _capabilities(raw.get("optional", []), "optional", errors)
	var normalized_limits := _limits(raw.get("limits", null), errors)
	var normalized_debug := {}
	if raw.has("debug"):
		if typeof(raw.debug) != TYPE_DICTIONARY:
			errors.append("debug должен быть object")
		else:
			for field in (raw.debug as Dictionary):
				if str(field) != "source_map":
					errors.append("debug содержит неизвестное поле «%s»" % str(field))
			var source_map := str((raw.debug as Dictionary).get("source_map", ""))
			if not valid_module_path(source_map) or not source_map.ends_with(".map"):
				errors.append("debug.source_map должен быть безопасным путём к .map")
			else:
				normalized_debug["source_map"] = source_map
	for capability in normalized_optional:
		if capability in normalized_requires:
			errors.append("capability «%s» не может быть одновременно requires и optional" % capability)
	for unsupported_field in ["knossos_api", "permissions"]:
		if raw.has(unsupported_field):
			errors.append("неизвестное поле «%s»" % unsupported_field)
	var normalized := {
		"format": FORMAT, "id": id, "version": str(raw.get("version", "0.0.0")),
		"sdk": str(raw.get("sdk", "")),
		"runtime": runtime, "world": world, "component": component,
		"exports": normalized_exports, "assets": normalized_assets,
		"requires": normalized_requires, "optional": normalized_optional,
		"limits": normalized_limits, "debug": normalized_debug,
	}
	return _result(normalized, errors)


static func _capabilities(value: Variant, field: String, errors: Array[String]) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) != TYPE_ARRAY or (value as Array).size() > MAX_CAPABILITIES:
		errors.append("%s должен быть array размером до %d" % [field, MAX_CAPABILITIES])
		return out
	for item in value:
		var capability := str(item)
		if typeof(item) != TYPE_STRING or capability.is_empty() or not capability.contains("/"):
			errors.append("%s содержит невалидную capability «%s»" % [field, capability])
		elif capability in out:
			errors.append("%s содержит дубликат «%s»" % [field, capability])
		else:
			out.append(capability)
	return out


static func _limits(value: Variant, errors: Array[String]) -> Dictionary:
	var out := DEFAULT_LIMITS.duplicate()
	if value == null:
		return out
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("limits должен быть object")
		return out
	for raw_name in (value as Dictionary):
		var name := str(raw_name)
		if not MAX_LIMITS.has(name):
			errors.append("limits содержит неизвестное поле «%s»" % name)
			continue
		var raw_limit: Variant = value[raw_name]
		if typeof(raw_limit) not in [TYPE_INT, TYPE_FLOAT] \
				or float(raw_limit) != floor(float(raw_limit)):
			errors.append("limits.%s должен быть целым числом" % name)
			continue
		var requested := int(raw_limit)
		var maximum := int(MAX_LIMITS[name])
		if requested < 1 or requested > maximum:
			errors.append("limits.%s должен быть от 1 до %d" % [name, maximum])
			continue
		out[name] = requested
	return out


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
