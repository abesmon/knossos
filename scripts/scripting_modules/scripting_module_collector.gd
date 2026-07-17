class_name ScriptingModuleCollector
extends RefCounted

## Чистый document -> WASM module IR. Ничего не скачивает и не исполняет.

const RUNTIME_WASM := "wasm-component"
const SUPPORTED_WORLD := "vrweb:module@1"
const MAX_MODULES := 32
const MAX_ID_BYTES := 128


## Возвращает {modules: Array[Dictionary], errors: Array[String]}.
## Module: id, kind(package), runtime, world, src, integrity, hash.
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
		var parsed := _parse_package(elem, base_url)
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
		if child.tag == "vrwebmodule":
			out.append(child)
		_collect_candidates(child, out)


static func _parse_package(elem: HtmlNode, base_url: String) -> Dictionary:
	var id := elem.get_attr("id")
	var invalid := _id_error(id)
	if not invalid.is_empty():
		return _error("VRWebModule: " + invalid)
	var src := elem.get_attr("src")
	if src.is_empty():
		return _error("module «%s»: отсутствует src пакета" % id)
	var runtime := elem.get_attr("runtime", RUNTIME_WASM)
	if runtime != RUNTIME_WASM:
		return _error("module «%s»: неизвестный runtime «%s»" % [id, runtime])
	var world := elem.get_attr("world", SUPPORTED_WORLD)
	if world != SUPPORTED_WORLD:
		return _error("module «%s»: несовместимый world «%s»" % [id, world])
	var src_path := src.get_slice("?", 0).get_slice("#", 0)
	if src_path.get_extension().to_lower() == "wasm":
		var metadata_text := elem.get_attr("manifest")
		if metadata_text.is_empty():
			return _error("module «%s»: прямой .wasm требует manifest metadata" % id)
		var metadata: Variant = JSON.parse_string(metadata_text)
		if not (metadata is Dictionary):
			return _error("module «%s»: manifest metadata содержит невалидный JSON" % id)
		var parsed := ScriptingModuleManifest.parse(
				JSON.stringify(metadata).to_utf8_buffer(), id)
		if not bool(parsed.ok):
			return _error("module «%s»: %s" % [id, "; ".join(parsed.errors)])
		if str(parsed.manifest.component) != "module.wasm":
			return _error("module «%s»: direct manifest component должен быть module.wasm" % id)
		return {"module": {
			"id": id, "kind": "component", "runtime": runtime, "world": world,
			"src": src, "base_url": base_url, "integrity": elem.get_attr("integrity"),
			"manifest": parsed.manifest, "exports": parsed.manifest.exports, "hash": "",
		}, "error": ""}
	return {"module": {
		"id": id, "kind": "package", "runtime": runtime, "world": world,
		"src": src, "base_url": base_url, "integrity": elem.get_attr("integrity"),
		"exports": {}, "hash": "",
	}, "error": ""}


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


static func _error(message: String) -> Dictionary:
	return {"module": {}, "error": message}
