class_name ScriptingModuleCollector
extends RefCounted

## Чистый document -> module IR. Ничего не скачивает и не исполняет.

const SCRIPT_MIME := "application/vrweb+gdscript"
const RUNTIME_TRUSTED := "trusted-gdscript"
const RUNTIME_SANDBOXED := "sandboxed"
const MAX_MODULES := 32
const MAX_INLINE_SOURCE_BYTES := 256 * 1024
const MAX_ID_BYTES := 128


## Возвращает {modules: Array[Dictionary], errors: Array[String]}.
## Module: id, kind(inline|script|package), runtime, source/src, integrity, exports, hash.
static func collect(doc: HtmlNode, base_url: String) -> Dictionary:
	var candidates: Array[HtmlNode] = []
	_collect_candidates(doc, candidates)
	var modules: Array[Dictionary] = []
	var errors: Array[String] = []
	var ids := {}
	for elem in candidates:
		if modules.size() >= MAX_MODULES:
			errors.append("слишком много scripting modules (максимум %d)" % MAX_MODULES)
			break
		var parsed := _parse_script(elem, base_url) if elem.tag == "script" \
				else _parse_package(elem, base_url)
		if not parsed.error.is_empty():
			errors.append(parsed.error)
			continue
		var module: Dictionary = parsed.module
		var id := str(module.id)
		if ids.has(id):
			errors.append("дублирующийся module id «%s»" % id)
			continue
		ids[id] = true
		modules.append(module)
	return {"modules": modules, "errors": errors}


static func _collect_candidates(node: HtmlNode, out: Array[HtmlNode]) -> void:
	for child in node.children:
		if child.tag == "script" and child.get_attr("type").to_lower() == SCRIPT_MIME:
			out.append(child)
		elif child.tag == "vrwebmodule":
			out.append(child)
		_collect_candidates(child, out)


static func _parse_script(elem: HtmlNode, base_url: String) -> Dictionary:
	var id := elem.get_attr("id")
	var invalid := _id_error(id)
	if not invalid.is_empty():
		return _error("inline script: " + invalid)
	var src := elem.get_attr("src")
	var source := _raw_text(elem)
	if not src.is_empty() and not source.strip_edges().is_empty():
		return _error("module «%s»: одновременно заданы src и inline body" % id)
	if src.is_empty() and source.strip_edges().is_empty():
		return _error("module «%s»: отсутствуют src и inline body" % id)
	if source.to_utf8_buffer().size() > MAX_INLINE_SOURCE_BYTES:
		return _error("module «%s»: inline source превышает %d байт" % [id, MAX_INLINE_SOURCE_BYTES])
	var runtime := elem.get_attr("data-mode", RUNTIME_TRUSTED)
	if not _valid_runtime(runtime):
		return _error("module «%s»: неизвестный runtime «%s»" % [id, runtime])
	var base := elem.get_attr("data-base", "Node")
	var module := {
		"id": id,
		"kind": "inline" if src.is_empty() else "script",
		"runtime": runtime,
		"source": source if src.is_empty() else "",
		"src": src,
		"base_url": base_url,
		"integrity": elem.get_attr("integrity"),
		"exports": {"default": {"script": "main.gd", "base": base}},
		"hash": source.sha256_text() if src.is_empty() else "",
	}
	return {"module": module, "error": ""}


static func _parse_package(elem: HtmlNode, base_url: String) -> Dictionary:
	var id := elem.get_attr("id")
	var invalid := _id_error(id)
	if not invalid.is_empty():
		return _error("VRWebModule: " + invalid)
	var src := elem.get_attr("src")
	if src.is_empty():
		return _error("module «%s»: отсутствует src пакета" % id)
	var runtime := elem.get_attr("mode", RUNTIME_TRUSTED)
	if not _valid_runtime(runtime):
		return _error("module «%s»: неизвестный runtime «%s»" % [id, runtime])
	return {"module": {
		"id": id, "kind": "package", "runtime": runtime,
		"source": "", "src": src, "base_url": base_url,
		"integrity": elem.get_attr("integrity"), "exports": {}, "hash": "",
	}, "error": ""}


static func _raw_text(elem: HtmlNode) -> String:
	var out := ""
	for child in elem.children:
		if child.is_text():
			out += child.text
	return out


static func _id_error(id: String) -> String:
	if id.is_empty():
		return "отсутствует id"
	if id.to_utf8_buffer().size() > MAX_ID_BYTES:
		return "id превышает %d байт" % MAX_ID_BYTES
	for c in id:
		if not (c >= "a" and c <= "z") and not (c >= "A" and c <= "Z") \
				and not (c >= "0" and c <= "9") and c not in [".", "_", "-"]:
			return "недопустимый id «%s»" % id
	return ""


static func _valid_runtime(runtime: String) -> bool:
	return runtime in [RUNTIME_TRUSTED, RUNTIME_SANDBOXED]


static func _error(message: String) -> Dictionary:
	return {"module": {}, "error": message}
