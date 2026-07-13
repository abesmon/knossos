@tool
extends EditorSceneFormatImporter

## Нативный Godot scene importer для локальных data-only `.vrwml`. Он намеренно синхронный:
## документы с ExtResource должны материализоваться существующей командой editable copy,
## которая умеет дождаться асинхронных loaders.


func _get_extensions() -> PackedStringArray:
	return PackedStringArray(["vrwml"])


func _import_scene(path: String, _flags: int, _options: Dictionary) -> Object:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("VRWML import: не удалось прочитать %s" % path)
		return null
	var policy := AvatarVrwmlPolicy.new()
	var base_url := PageFetcher.LOCAL_SCHEME + ProjectSettings.globalize_path(path)
	var built := VrwebBuilder.build(HtmlParser.parse(text), base_url, null, policy)
	var holder := built.get("root") as Node3D
	if policy.has_errors() or holder == null or holder.get_child_count() != 1 \
			or not (holder.get_child(0) is Avatar):
		if holder != null:
			holder.free()
		push_error("VRWML import rejected: %s%s" % [path,
				(" (" + policy.summary() + ")") if policy.has_errors() else ""])
		return null
	var ext: Dictionary = built.get("ext", {})
	if not ext.get("targets", []).is_empty():
		holder.free()
		push_error("VRWML import: %s содержит ExtResource; используйте editable-copy command" % path)
		return null
	var avatar := holder.get_child(0) as Avatar
	holder.remove_child(avatar)
	holder.free()
	_set_owner_recursive(avatar, avatar)
	return avatar


func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_owner_recursive(child, root)
