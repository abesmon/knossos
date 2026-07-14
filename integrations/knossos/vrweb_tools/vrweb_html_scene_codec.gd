@tool
class_name VrwebHtmlSceneCodec
extends RefCounted

## Testable implementation behind EditorSceneFormatImporter.


static func build_from_path(path: String) -> Node3D:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty() and not FileAccess.file_exists(path):
		push_error("HTML scene import: не удалось прочитать %s" % path)
		return null
	var span := VrwebHtmlDocument.locate(source)
	var doc := HtmlParser.parse(source)
	var base_url := PageFetcher.LOCAL_SCHEME + ProjectSettings.globalize_path(path)
	var block := doc.find_descendant(VrwebBuilder.TAG)
	var mode := str(block.get_attr("mode", VrwebBuilder.MODE_COMBINE)) if block != null \
		else VrwebBuilder.MODE_COMBINE
	if mode not in [VrwebBuilder.MODE_COMBINE, VrwebBuilder.MODE_EXCLUSIVE]:
		mode = VrwebBuilder.MODE_COMBINE
	var editable := bool(span.ok) and block != null and _tool_safe_vrweb(block)
	var built := VrwebBuilder.build(doc, base_url) if editable else {
		"root": null, "mode": VrwebBuilder.MODE_COMBINE, "ext": {}}
	var root := built.get("root") as Node3D
	if root == null:
		root = Node3D.new()
	root.name = path.get_file().get_basename().to_pascal_case()
	root.set_meta(VrwebHtmlDocument.META_IMPORTED, editable)
	root.set_meta(VrwebHtmlDocument.META_SOURCE_PATH, path)
	root.set_meta(VrwebHtmlDocument.META_MODE, mode)
	if editable:
		root.set_meta(VrwebHtmlDocument.META_BLOCK_HASH, str(span.block).sha256_text())
	else:
		root.set_meta(VrwebHtmlDocument.META_READ_ONLY_REASON,
			"нет <vrweb>" if not bool(span.ok) else
			"<vrweb> содержит scripted/неизвестные классы, недоступные в editor tool mode")
	_materialize_ext_metadata(built.get("ext", {}))

	if mode != VrwebBuilder.MODE_EXCLUSIVE:
		if bool(span.ok):
			_remove_first_vrweb(doc)
		var space := TopologyBuilder.build(doc, true)
		var preview := Node3D.new()
		preview.name = "HTMLPreview_ReadOnly"
		preview.set_meta(VrwebHtmlDocument.META_PREVIEW, true)
		# PackedScene does not retain internal children. Import cache therefore stores this as a
		# regular marked child; EditorPlugin turns it internal in the live edited tree on open.
		root.add_child(preview)
		if int(space.get("root", -1)) != -1:
			var seed_value := PageFetcher.space_seed(base_url, TopologyBuilder.signature(space))
			WorldGenerator.generate_editor_preview(space, preview, seed_value, base_url)
	_set_owner_recursive(root, root)
	return root


static func make_preview_internal(root: Node) -> void:
	if root == null:
		return
	for child in root.get_children():
		if not bool(child.get_meta(VrwebHtmlDocument.META_PREVIEW, false)):
			continue
		child.owner = null
		root.remove_child(child)
		root.add_child(child, false, Node.INTERNAL_MODE_BACK)
		child.owner = root


static func attach_procedural_preview(root: Node3D) -> void:
	if root == null or str(root.get_meta(VrwebHtmlDocument.META_MODE,
			VrwebFormat.MODE_COMBINE)) == VrwebFormat.MODE_EXCLUSIVE:
		return
	for child in root.get_children(true):
		if bool(child.get_meta(VrwebHtmlDocument.META_PREVIEW, false)):
			return
	var path := str(root.get_meta(VrwebHtmlDocument.META_SOURCE_PATH, ""))
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty() and not FileAccess.file_exists(path):
		return
	var doc := HtmlParser.parse(source)
	_remove_first_vrweb(doc)
	var space := TopologyBuilder.build(doc, true)
	var preview := Node3D.new()
	preview.name = "HTMLPreview_ReadOnly"
	preview.set_meta(VrwebHtmlDocument.META_PREVIEW, true)
	root.add_child(preview)
	preview.owner = root
	if int(space.get("root", -1)) != -1:
		var base_url := PageFetcher.LOCAL_SCHEME + ProjectSettings.globalize_path(path)
		var seed_value := PageFetcher.space_seed(base_url, TopologyBuilder.signature(space))
		WorldGenerator.generate_editor_preview(space, preview, seed_value, base_url)


static func _tool_safe_vrweb(block: HtmlNode) -> bool:
	for child in block.children:
		if child.is_text():
			continue
		var raw := child.raw_tag
		if raw in [VrwebBuilder.RESOURCE_TAG, VrwebBuilder.EXT_RESOURCE_TAG]:
			var type := child.get_attr("type")
			if type != "" and not ClassDB.class_exists(type):
				return false
			continue
		if raw == VrwebBuilder.SPAWNER_TAG:
			continue
		if raw != VrwebBuilder.EXT_SCENE_TAG \
				and (not ClassDB.class_exists(raw) or not ClassDB.is_parent_class(raw, "Node")):
			return false
		if not _tool_safe_vrweb(child):
			return false
	return true


static func _materialize_ext_metadata(ext: Dictionary) -> void:
	var defs: Dictionary = ext.get("defs", {})
	for target in ext.get("targets", []):
		var obj := target.get("obj") as Node
		var definition: Dictionary = defs.get(target.get("id", ""), {})
		if obj == null or definition.is_empty():
			continue
		var resource := VrwebExtResource.new()
		resource.url = str(definition.get("url", ""))
		resource.type = str(definition.get("type", ""))
		if bool(target.get("child", false)):
			obj.set_meta(VrwebExtResource.META_SCENE, resource)
		else:
			var bindings: Dictionary = obj.get_meta(VrwebExtResource.META_BINDINGS, {}).duplicate()
			bindings[str(target.get("prop", ""))] = resource
			obj.set_meta(VrwebExtResource.META_BINDINGS, bindings)


static func _remove_first_vrweb(node: HtmlNode) -> bool:
	for i in range(node.children.size()):
		var child := node.children[i]
		if child.tag == VrwebBuilder.TAG:
			node.children.remove_at(i)
			return true
		if _remove_first_vrweb(child):
			return true
	return false


static func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children(true):
		child.owner = root
		_set_owner_recursive(child, root)
