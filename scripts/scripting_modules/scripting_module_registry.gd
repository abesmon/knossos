class_name ScriptingModuleRegistry
extends RefCounted

## Подготовленные/одобренные exports одной навигации. Builder ничего не компилирует сам.

enum ScriptMode { ALLOW_ALL, SELECTED, DENY_ALL }

const CAPABILITIES := {
	"vrweb/core/1": true,
	"vrweb/scene/1": true,
	"vrweb/state/1": true,
	"vrweb/assets/1": true,
	"vrweb/timers/1": true,
	"vrweb/input/1": true,
	"vrweb/log/1": true,
	"vrweb/features/1": true,
	"godot/engine/4": true,
}

var _modules: Dictionary = {}


## Совместимый старый вход для тестов/синхронного inline pipeline.
func prepare_inline(definitions: Array, mode: ScriptMode,
		selected_hashes: Dictionary = {}) -> Dictionary:
	return prepare(definitions, mode, selected_hashes)


## Trusted inline и уже fetched/verified single-file script. Package готовит unpacker позже.
## selected_hashes: {hex_sha256: true}.
func prepare(definitions: Array, mode: ScriptMode,
		selected_hashes: Dictionary = {}) -> Dictionary:
	_modules.clear()
	var errors: Array[String] = []
	var pending: Array[Dictionary] = []
	for definition in definitions:
		var module: Dictionary = definition
		var kind := str(module.get("kind", ""))
		if kind not in ["inline", "script", "package"]:
			continue
		if str(module.get("runtime", "")) != ScriptingModuleCollector.RUNTIME_TRUSTED:
			errors.append("module «%s»: runtime ещё не поддержан" % str(module.get("id", "")))
			continue
		var hash := str(module.get("hash", ""))
		var allowed := mode == ScriptMode.ALLOW_ALL \
				or (mode == ScriptMode.SELECTED and selected_hashes.has(hash))
		if not allowed:
			pending.append(module)
			continue
		if kind == "package":
			var added := _prepare_package(module)
			if not str(added).is_empty():
				errors.append(added)
			continue
		var source := str(module.get("source", ""))
		if kind == "script" and module.get("bytes", PackedByteArray()) is PackedByteArray:
			source = (module.get("bytes") as PackedByteArray).get_string_from_utf8()
		var script := GDScript.new()
		script.source_code = source
		if script.reload() != OK or not script.can_instantiate():
			errors.append("module «%s»: GDScript не скомпилирован" % str(module.get("id", "")))
			continue
		_modules[str(module.get("id", ""))] = {
			"definition": module,
			"session": ScriptingModuleSession.new(str(module.get("id", "")), hash),
			"exports": {"default": {"script": script,
				"base": str(module.get("exports", {}).get("default", {}).get("base", "Node"))}},
		}
	return {"ok": errors.is_empty() and pending.is_empty(), "errors": errors, "pending": pending}


func _prepare_package(module: Dictionary) -> String:
	var module_id := str(module.get("id", ""))
	var root := str(module.get("module_root", ""))
	var export_defs: Dictionary = module.get("exports", {})
	if root.is_empty() or export_defs.is_empty():
		return "module «%s»: package не распакован" % module_id
	var manifest: Dictionary = module.get("manifest", {})
	for capability in manifest.get("requires", []):
		if not CAPABILITIES.has(str(capability)):
			return "module «%s»: обязательная capability «%s» недоступна" % [module_id, capability]
	var exports := {}
	for export_name in export_defs:
		var definition: Dictionary = export_defs[export_name]
		var script_path := str(definition.get("script", ""))
		if not script_path.is_empty():
			var resource = ResourceLoader.load(root.path_join(script_path), "GDScript",
					ResourceLoader.CACHE_MODE_IGNORE)
			if not (resource is GDScript) or not resource.can_instantiate():
				return "module «%s»: export «%s» не загружен" % [module_id, export_name]
			exports[str(export_name)] = {"script": resource,
				"base": str(definition.get("base", "Node"))}
		else:
			return "module «%s»: scene exports ещё не реализованы" % module_id
	_modules[module_id] = {"definition": module, "exports": exports,
		"session": ScriptingModuleSession.new(module_id, str(module.get("hash", "")))}
	return ""


func instantiate_export(module_id: String, export_name: String) -> Dictionary:
	module_id = module_id.trim_prefix("#")
	if not _modules.has(module_id):
		return _error("module «%s» не подготовлен или не разрешён" % module_id)
	var exports: Dictionary = _modules[module_id].exports
	if not exports.has(export_name):
		return _error("module «%s» не экспортирует «%s»" % [module_id, export_name])
	var spec: Dictionary = exports[export_name]
	var script: GDScript = spec.script
	var instance = script.new()
	if not (instance is Node):
		return _error("export «%s:%s» не является Node" % [module_id, export_name])
	var node := instance as Node
	var base := str(spec.get("base", "Node"))
	if not node.is_class(base):
		node.free()
		return _error("export «%s:%s» несовместим с заявленным base «%s»" \
				% [module_id, export_name, base])
	var definition: Dictionary = _modules[module_id].definition
	var session: ScriptingModuleSession = _modules[module_id].session
	var manifest: Dictionary = definition.get("manifest", {})
	var context := ScriptingModuleContext.new(module_id, str(definition.get("hash", "")), node, session,
			str(definition.get("module_root", "")), manifest.get("assets", {}),
			str(definition.get("base_url", "")), CAPABILITIES)
	node.set_meta("vrweb_module_context", context)
	_bind_lifecycle(node, context)
	return {"node": node, "context": context, "error": ""}


func has_module(module_id: String) -> bool:
	return _modules.has(module_id.trim_prefix("#"))


func clear() -> void:
	_modules.clear()


func _bind_lifecycle(node: Node, context: ScriptingModuleContext) -> void:
	var on_ready := func():
		if not context.valid:
			return
		context._session.acquire()
		if node.has_method("mount"):
			node.call("mount", context)
		context.mounted = true
	var on_exit := func():
		if context.unmounted:
			return
		if context.mounted and node.has_method("unmount"):
			node.call("unmount")
		context.unmounted = true
		context.invalidate()
		context._session.release()
	node.ready.connect(on_ready, CONNECT_ONE_SHOT)
	node.tree_exiting.connect(on_exit, CONNECT_ONE_SHOT)


static func _error(message: String) -> Dictionary:
	return {"node": null, "context": null, "error": message}
