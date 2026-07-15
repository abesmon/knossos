@tool
class_name VrwebMarkupMaterializer
extends RefCounted

const RESERVED := {"id": true, "type": true, "path": true, "src": true}

var _profile := VrwebCompatibility.PROFILE_STRICT
var _resources := {}
var _external := {}
var _errors: Array[String] = []
var _warnings: Array[String] = []


static func build(block: HtmlNode,
		profile: String = VrwebCompatibility.PROFILE_STRICT) -> Dictionary:
	var materializer := VrwebMarkupMaterializer.new()
	materializer._profile = VrwebCompatibility.normalized_profile(profile)
	return materializer._build(block)


func _build(block: HtmlNode) -> Dictionary:
	if block == null or block.tag != VrwebFormat.TAG:
		return {"ok": false, "root": null, "mode": VrwebFormat.MODE_COMBINE,
			"errors": ["HTML не содержит <vrwml>"], "warnings": []}
	_collect_definitions(block)
	var root := Node3D.new()
	root.name = "VRWeb"
	_append_materialized_children(root, block, "/VRWeb")
	var mode := VrwebFormat.normalized_mode(block.get_attr("mode", VrwebFormat.MODE_COMBINE))
	return {"ok": _errors.is_empty(), "complete": _warnings.is_empty(), "root": root, "mode": mode,
		"resources": _resources, "errors": _errors, "warnings": _warnings}


func _collect_definitions(block: HtmlNode) -> void:
	for child in block.children:
		if child.raw_tag == VrwebFormat.EXT_RESOURCE_TAG:
			var id := child.get_attr("id")
			if id.is_empty() or _external.has(id):
				_warn("ExtResource id отсутствует или дублируется: " + id)
				continue
			var external := VrwebExtResource.new()
			external.type = child.get_attr("type")
			external.url = child.get_attr("path")
			_external[id] = external
	for child in block.children:
		if child.raw_tag != VrwebFormat.RESOURCE_TAG:
			continue
		var id := child.get_attr("id")
		var type := child.get_attr("type")
		if id.is_empty() or _resources.has(id):
			_warn("Resource id отсутствует или дублируется: " + id)
			continue
		var resource = _instantiate(type, false, "Resource " + id)
		if resource is Resource:
			_resources[id] = resource
		else:
			_warn("Resource %s: не удалось создать %s" % [id, type])
	for child in block.children:
		if child.raw_tag == VrwebFormat.RESOURCE_TAG:
			var resource = _resources.get(child.get_attr("id"))
			if resource != null:
				_apply_attributes(resource, child, "Resource " + child.get_attr("id"), RESERVED)


func _build_node(element: HtmlNode, parent_path: String) -> Node:
	if element.raw_tag == VrwebFormat.SPAWNER_TAG:
		return _build_spawner(element)
	if element.raw_tag == VrwebFormat.EXT_SCENE_TAG:
		var placeholder := Node3D.new()
		_apply_attributes(placeholder, element, parent_path + "/ExtScene", {"src": true})
		var reference := element.get_attr("src")
		var external = _external.get(reference.trim_prefix(VrwebFormat.EXTRESOURCE_PREFIX))
		if external is VrwebExtResource:
			placeholder.set_meta(VrwebExtResource.META_SCENE, external)
		else:
			_warn(parent_path + "/ExtScene: неизвестный external reference " + reference)
		return placeholder
	var type := element.raw_tag
	var path := parent_path + "/" + type
	var instance = _instantiate(type, true, path)
	if not instance is Node:
		_warn(path + ": не удалось создать node")
		return null
	var node := instance as Node
	_apply_attributes(node, element, path, {})
	_append_materialized_children(node, element, path)
	return node


## Skip an unsupported wrapper but retain every descendant the local policy can materialize.
func _append_materialized_children(parent: Node, element: HtmlNode, parent_path: String) -> void:
	for child in element.children:
		if child.is_text() or _is_definition(child):
			continue
		var child_node := _build_node(child, parent_path)
		if child_node != null:
			parent.add_child(child_node)
		else:
			_append_materialized_children(parent, child, parent_path)


func _build_spawner(element: HtmlNode) -> VrwebSpawner:
	var spawner := VrwebSpawner.new()
	spawner.mode = element.get_attr("mode", "first")
	for child in element.children:
		if child.raw_tag != VrwebFormat.SPAWN_POINT_TAG:
			continue
		var point := Marker3D.new()
		var value = str_to_var(child.get_attr("transform", var_to_str(Transform3D.IDENTITY)))
		if value is Transform3D:
			point.transform = value
		else:
			_warn("VRWebSpawner/SpawnerPoint: invalid transform")
		spawner.add_child(point)
	return spawner


func _instantiate(type: String, node: bool, context: String):
	var public := VrwebExportRegistry.instantiate(type)
	if public != null:
		return public
	var supported := VrwebCompatibility.supports_node(type) if node \
			else VrwebCompatibility.supports_resource(type)
	if _profile == VrwebCompatibility.PROFILE_STRICT and not supported:
		_warn("%s: %s пропущен локальной strict policy" % [context, type])
		return null
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		_warn("%s: неизвестный ClassDB type %s" % [context, type])
		return null
	var instance = ClassDB.instantiate(type)
	if node and not instance is Node:
		if instance is RefCounted:
			instance = null
		return null
	if not node and not instance is Resource:
		if instance is Node:
			instance.free()
		return null
	return instance


func _apply_attributes(object: Object, element: HtmlNode, context: String,
		reserved: Dictionary) -> void:
	for property in element.attributes:
		if reserved.has(property) or property == "mode":
			continue
		var raw := str(element.attributes[property])
		if property == "name" and object is Node:
			(object as Node).name = raw
			continue
		if raw.begins_with(VrwebFormat.EXTRESOURCE_PREFIX):
			var external = _external.get(raw.trim_prefix(VrwebFormat.EXTRESOURCE_PREFIX))
			if not external is VrwebExtResource or not object is Node:
				_warn("%s.%s: invalid external reference" % [context, property])
				continue
			var bindings: Dictionary = object.get_meta(VrwebExtResource.META_BINDINGS, {}).duplicate()
			bindings[property] = external
			object.set_meta(VrwebExtResource.META_BINDINGS, bindings)
			continue
		if not _has_property(object, property):
			_warn("%s: неизвестное property %s" % [context, property])
			continue
		var resolved = _resolve_value(raw)
		if resolved == null and raw != "null":
			_warn("%s.%s: значение не разобрано" % [context, property])
			continue
		object.set(property, resolved)


func _resolve_value(raw: String):
	if raw.begins_with(VrwebFormat.SUBRESOURCE_PREFIX):
		return _resources.get(raw.trim_prefix(VrwebFormat.SUBRESOURCE_PREFIX))
	var value = str_to_var(raw)
	return _resolve_nested(value)


func _resolve_nested(value):
	if value is String and value.begins_with(VrwebFormat.SUBRESOURCE_PREFIX):
		return _resources.get(value.trim_prefix(VrwebFormat.SUBRESOURCE_PREFIX))
	if value is Array:
		var result := []
		for item in value:
			result.append(_resolve_nested(item))
		return result
	return value


func _has_property(object: Object, property: String) -> bool:
	for entry in object.get_property_list():
		if str(entry.name) == property:
			return true
	return false


func _is_definition(element: HtmlNode) -> bool:
	return element.raw_tag in [VrwebFormat.RESOURCE_TAG, VrwebFormat.EXT_RESOURCE_TAG]


func _warn(message: String) -> void:
	_warnings.append(message)
