@tool
class_name VrwebHtmlSceneCodec
extends RefCounted

## Testable implementation behind EditorSceneFormatImporter.


static func build_from_path(path: String) -> Node3D:
	var root := VrwebPortableHtmlSceneCodec.build_from_path(path)
	if root == null:
		return null
	attach_procedural_preview(root)
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


static func _remove_first_vrweb(node: HtmlNode) -> bool:
	for i in range(node.children.size()):
		var child := node.children[i]
		if child.tag == VrwebBuilder.TAG:
			node.children.remove_at(i)
			return true
		if _remove_first_vrweb(child):
			return true
	return false
