@tool
class_name VrwebModuleMetadata
extends RefCounted

## Portable authoring contract for trusted scripting modules. Values live as node metadata so
## authors do not need a Knossos class or resource in their scene.

const META_VERSION := "vrweb_module_version"
const META_PERMISSIONS := "vrweb_module_permissions"
const META_REQUIRES := "vrweb_module_requires"
const META_OPTIONAL := "vrweb_module_optional"

const DEFAULT_VERSION := "0.0.0"
const DEFAULT_REQUIRES: Array[String] = [
	"vrweb/core/1", "vrweb/scene/1", "godot/engine/4",
]
const DEFAULT_OPTIONAL: Array[String] = [
	"vrweb/state/1", "vrweb/input/1", "vrweb/assets/1", "vrweb/timers/1", "vrweb/log/1",
]


static func from_node(node: Node, fallback_id: String) -> Dictionary:
	return {
		"id": str(node.get_meta(VrwebExporter.META_SCRIPT_ID, fallback_id)).strip_edges(),
		"version": str(node.get_meta(META_VERSION, DEFAULT_VERSION)).strip_edges(),
		"permissions": _strings(node.get_meta(META_PERMISSIONS, [])),
		"requires": _strings(node.get_meta(META_REQUIRES, DEFAULT_REQUIRES)),
		"optional": _strings(node.get_meta(META_OPTIONAL, DEFAULT_OPTIONAL)),
	}


static func apply_to_node(node: Node, values: Dictionary) -> Array[String]:
	var normalized := normalize(values)
	var errors: Array[String] = normalized.errors
	if not errors.is_empty():
		return errors
	var data: Dictionary = normalized.value
	node.set_meta(VrwebExporter.META_SCRIPT_ID, data.id)
	node.set_meta(META_VERSION, data.version)
	node.set_meta(META_PERMISSIONS, data.permissions)
	node.set_meta(META_REQUIRES, data.requires)
	node.set_meta(META_OPTIONAL, data.optional)
	return []


static func normalize(values: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var module_id := str(values.get("id", "")).strip_edges()
	var version := str(values.get("version", DEFAULT_VERSION)).strip_edges()
	var permissions := _strings(values.get("permissions", []))
	var requires := _strings(values.get("requires", DEFAULT_REQUIRES))
	var optional := _strings(values.get("optional", DEFAULT_OPTIONAL))
	if not _valid_id(module_id):
		errors.append("module id: нужны буквы/цифры и . _ -, первый символ — буква или _")
	if not _valid_version(version):
		errors.append("version должна иметь вид SemVer: 1.2.3, допускаются -pre и +build")
	_validate_list(permissions, "permissions", false, errors)
	_validate_list(requires, "requires", true, errors)
	_validate_list(optional, "optional", true, errors)
	for capability in optional:
		if capability in requires:
			errors.append("capability %s указана одновременно в requires и optional" % capability)
	return {"ok": errors.is_empty(), "errors": errors, "value": {
		"id": module_id, "version": version, "permissions": permissions,
		"requires": requires, "optional": optional,
	}}


static func parse_list(text: String) -> Array[String]:
	var values: Array[String] = []
	for part in text.replace("\n", ",").split(","):
		var value := str(part).strip_edges()
		if not value.is_empty() and not value in values:
			values.append(value)
	return values


static func list_text(values: Variant) -> String:
	return ", ".join(_strings(values))


static func _strings(values: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(values) not in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY]:
		return out
	for raw in values:
		var value := str(raw).strip_edges()
		if not value.is_empty() and not value in out:
			out.append(value)
	return out


static func _valid_id(value: String) -> bool:
	if value.is_empty():
		return false
	var regex := RegEx.new()
	regex.compile("^[A-Za-z_][A-Za-z0-9_.-]*$")
	return regex.search(value) != null


static func _valid_version(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?$")
	return regex.search(value) != null


static func _validate_list(values: Array[String], field: String, capability: bool,
		errors: Array[String]) -> void:
	if values.size() > 64:
		errors.append("%s содержит больше 64 значений" % field)
	for value in values:
		if capability and not value.contains("/"):
			errors.append("%s содержит невалидную capability %s" % [field, value])
