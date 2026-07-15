@tool
class_name VrwebSchemaGenerator
extends RefCounted

## Generates VS Code HTML Custom Data for the local strict Maker Kit policy. The complete VRWML
## vocabulary is broader (all Godot classes plus standard special tags); this JSON only provides
## completion for the subset this Maker Kit profile has verified.

const SCHEMA_VERSION := 1.1
const SKIP_PROPERTIES := {
	"owner": true,
	"name": true,
	"script": true,
	"scene_file_path": true,
}


static func build() -> Dictionary:
	var tags: Array[Dictionary] = []
	tags.append(_tag(VrwebFormat.TAG,
			"VRWML scene embedded in an HTML document.", [
		_attr("mode", "World composition mode.", [VrwebFormat.MODE_EXCLUSIVE,
				VrwebFormat.MODE_COMBINE]),
	]))
	tags.append(_tag(VrwebFormat.RESOURCE_TAG,
			"Inline Godot Resource definition. Property values use Godot Variant syntax.", [
		_attr("id", "Resource identifier used by SubResource::: references."),
		_attr("type", "Resource class allowed by the local strict Maker Kit policy.",
				_sorted_keys(VrwebCompatibility.RESOURCE_ALLOWLIST)),
	]))
	tags.append(_tag(VrwebFormat.EXT_RESOURCE_TAG,
			"External resource definition loaded from path.", [
		_attr("id", "Resource identifier used by ExtResource::: references."),
		_attr("type", "External resource class.",
				_sorted_keys(VrwebCompatibility.EXTERNAL_TYPE_ALLOWLIST)),
		_attr("path", "Absolute HTTP(S)/VRWeb URL or a relative bundled asset path."),
	]))
	tags.append(_tag(VrwebFormat.EXT_SCENE_TAG,
			"External PackedScene placeholder with Node3D transform properties.",
			[_attr("src", "ExtResource::: identifier of a PackedScene.")] +
			_class_attributes("Node3D", false)))
	tags.append(_tag(VrwebFormat.SPAWNER_TAG, "World spawn policy.", [
		_attr("mode", "Choose the first point or a random point.", ["first", "random"]),
	]))
	tags.append(_tag(VrwebFormat.SPAWN_POINT_TAG, "A spawn pose inside VRWebSpawner.", [
		_attr("transform", "Godot Transform3D Variant literal."),
	]))
	tags.append(_tag("VRWebModule", "Trusted GDScript package declaration.", [
		_attr("id", "Stable module id."),
		_attr("src", "Relative or absolute .vrmod URL."),
		_attr("integrity", "sha256-BASE64 integrity value."),
		_attr("mode", "Runtime trust mode.", ["trusted-gdscript"]),
	]))
	tags.append(_tag("VRWebComponent", "Node implemented by an inline or packaged module.", [
		_attr("module", "Module id, or #id for an inline script."),
		_attr("class", "Exported module class; inline modules use default."),
	] + _class_attributes("Node3D", true)))
	for class_name_ in _sorted_keys(VrwebCompatibility.NODE_ALLOWLIST):
		tags.append(_tag(class_name_,
				"Godot %s node allowed by the local strict Maker Kit policy." % class_name_,
				_class_attributes(class_name_, true)))
	return {
		"version": SCHEMA_VERSION,
		"tags": tags,
	}


static func json_text() -> String:
	return JSON.stringify(build(), "  ", false, true) + "\n"


static func _class_attributes(class_name_: String, include_name: bool) -> Array[Dictionary]:
	var attributes: Array[Dictionary] = []
	var seen := {}
	if include_name:
		attributes.append(_attr("name", "Godot node name; required for stable NodePath references."))
		seen["name"] = true
	for entry in ClassDB.class_get_property_list(class_name_):
		var property := str(entry.get("name", ""))
		var usage := int(entry.get("usage", 0))
		if property.is_empty() or seen.has(property) or SKIP_PROPERTIES.has(property) \
				or property.begins_with("metadata/") or usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		seen[property] = true
		attributes.append(_property_attribute(entry))
	attributes.sort_custom(func(a, b): return str(a.name) < str(b.name))
	return attributes


static func _property_attribute(entry: Dictionary) -> Dictionary:
	var type_name := type_string(int(entry.get("type", TYPE_NIL)))
	var description := "Godot %s property; use a Godot Variant literal." % type_name
	var values: Array[String] = []
	var hint := int(entry.get("hint", PROPERTY_HINT_NONE))
	var hint_string := str(entry.get("hint_string", ""))
	if hint == PROPERTY_HINT_ENUM:
		for option in hint_string.split(","):
			var value := str(option).get_slice(":", 0).strip_edges()
			if not value.is_empty() and not value in values:
				values.append(value)
	elif int(entry.get("type", TYPE_NIL)) == TYPE_BOOL:
		values.assign(["true", "false"])
	return _attr(str(entry.get("name", "")), description, values)


static func _tag(name: String, description: String, attributes: Array) -> Dictionary:
	return {"name": name, "description": description, "attributes": attributes}


static func _attr(name: String, description: String,
		values: Array = []) -> Dictionary:
	var result := {"name": name, "description": description}
	if not values.is_empty():
		var options: Array[Dictionary] = []
		for value in values:
			options.append({"name": value})
		result["values"] = options
	return result


static func _sorted_keys(values: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key in values:
		keys.append(str(key))
	keys.sort()
	return keys
