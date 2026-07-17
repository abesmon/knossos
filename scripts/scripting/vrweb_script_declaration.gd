class_name VrwebScriptDeclaration
extends RefCounted

## Pure HTML document -> ordered Luau source declarations. No I/O and no execution.

const MIME := "application/vrweb+luau"
const PROFILE := "vrweb-luau/1"
const MAX_SCRIPTS := 32
const MAX_SOURCE_BYTES := 256 * 1024
const MAX_ID_BYTES := 128


static func collect(doc: HtmlNode, base_url: String) -> Dictionary:
	var elements: Array[HtmlNode] = []
	_collect(doc, elements)
	var scripts: Array[Dictionary] = []
	var errors: Array[String] = []
	var ids := {}
	for element in elements:
		if scripts.size() >= MAX_SCRIPTS:
			errors.append("слишком много VRWeb scripts (максимум %d)" % MAX_SCRIPTS)
			break
		var parsed := _parse(element, base_url)
		if not str(parsed.error).is_empty():
			errors.append(str(parsed.error))
			continue
		var declaration: Dictionary = parsed.declaration
		if ids.has(declaration.id):
			errors.append("дублирующийся script id «%s»" % declaration.id)
			continue
		ids[declaration.id] = true
		scripts.append(declaration)
	return {"scripts": scripts, "errors": errors}


static func valid_id(value: String) -> bool:
	if value.is_empty() or value.to_utf8_buffer().size() > MAX_ID_BYTES:
		return false
	for character in value:
		if not (character >= "a" and character <= "z") \
				and not (character >= "A" and character <= "Z") \
				and not (character >= "0" and character <= "9") \
				and character not in [".", "_", "-"]:
			return false
	return true


static func _collect(node: HtmlNode, output: Array[HtmlNode]) -> void:
	for child in node.children:
		if child.tag == "script" and child.get_attr("type").to_lower() == MIME:
			output.append(child)
		_collect(child, output)


static func _parse(element: HtmlNode, base_url: String) -> Dictionary:
	var script_id := element.get_attr("id")
	if not valid_id(script_id):
		return _error("script id отсутствует или недопустим: «%s»" % script_id)
	var src := element.get_attr("src").strip_edges()
	var source := _raw_text(element)
	if not src.is_empty() and not source.strip_edges().is_empty():
		return _error("script «%s»: одновременно заданы src и inline body" % script_id)
	if src.is_empty() and source.strip_edges().is_empty():
		return _error("script «%s»: отсутствуют src и inline body" % script_id)
	if not src.is_empty() and src.to_lower().begins_with("data:"):
		return _error("script «%s»: data URL не поддерживается" % script_id)
	if source.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return _error("script «%s»: source превышает %d байт" % [script_id, MAX_SOURCE_BYTES])
	return {"declaration": {
		"id": script_id,
		"profile": PROFILE,
		"kind": "inline" if src.is_empty() else "linked",
		"source": source if src.is_empty() else "",
		"src": src,
		"integrity": element.get_attr("integrity").strip_edges(),
		"base_url": base_url,
		"hash": source.sha256_text() if src.is_empty() else "",
	}, "error": ""}


static func _raw_text(element: HtmlNode) -> String:
	var output := ""
	for child in element.children:
		if child.is_text():
			output += child.text
	return output


static func _error(message: String) -> Dictionary:
	return {"declaration": {}, "error": message}
