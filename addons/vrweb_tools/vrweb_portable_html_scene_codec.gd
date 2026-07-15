@tool
class_name VrwebPortableHtmlSceneCodec
extends RefCounted

## Lossless HTML envelope + portable declarative <vrwml> materialization. Procedural HTML
## geometry intentionally remains a host/runtime adapter concern.


static func build_from_path(path: String) -> Node3D:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty() and not FileAccess.file_exists(path):
		push_error("HTML scene import: не удалось прочитать %s" % path)
		return null
	var span := VrwebHtmlDocument.locate(source)
	var block: HtmlNode = null
	if bool(span.get("ok", false)):
		block = HtmlParser.parse(str(span.block)).find_descendant(VrwebFormat.TAG)
	var materialized := VrwebMarkupMaterializer.build(block,
			VrwebCompatibility.PROFILE_STRICT) if block != null else {
		"ok": false, "complete": false, "root": null, "mode": VrwebFormat.MODE_COMBINE,
		"errors": [str(span.get("error", "HTML не содержит <vrwml>"))], "warnings": []}
	var materialized_ok := bool(materialized.get("ok", false))
	var editable := bool(span.get("ok", false)) and materialized_ok \
			and bool(materialized.get("complete", false))
	var root := materialized.get("root") as Node3D
	if root == null or not materialized_ok:
		if root != null:
			root.free()
		root = Node3D.new()
	root.name = path.get_file().get_basename().to_pascal_case()
	root.set_meta(VrwebHtmlDocument.META_IMPORTED, editable)
	root.set_meta(VrwebHtmlDocument.META_SOURCE_PATH, path)
	root.set_meta(VrwebHtmlDocument.META_MODE,
			materialized.get("mode", VrwebFormat.MODE_COMBINE))
	root.set_meta(VrwebHtmlDocument.META_DIAGNOSTICS, {
		"errors": materialized.get("errors", []), "warnings": materialized.get("warnings", [])})
	if bool(span.get("ok", false)):
		var start := int(span.start)
		var finish := int(span.end)
		root.set_meta(VrwebHtmlDocument.META_PREFIX, source.substr(0, start))
		root.set_meta(VrwebHtmlDocument.META_SUFFIX, source.substr(finish))
		root.set_meta(VrwebHtmlDocument.META_BLOCK_HASH, str(span.block).sha256_text())
	if not editable:
		var reasons: Array = materialized.get("errors", [])
		reasons.append_array(materialized.get("warnings", []))
		root.set_meta(VrwebHtmlDocument.META_READ_ONLY_REASON, "; ".join(reasons))
	_set_owner_recursive(root, root)
	return root


static func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner_recursive(child, owner)
