class_name UnavailableWasmBackend
extends ScriptingModuleBackend

var _module_ids: Dictionary = {}


func prepare(modules: Array) -> Dictionary:
	_module_ids.clear()
	var errors: Array[String] = []
	for item in modules:
		var module: Dictionary = item
		var module_id := str(module.get("id", ""))
		_module_ids[module_id] = true
		errors.append("module «%s»: WASM runtime unavailable" % module_id)
	return {"ok": modules.is_empty(), "errors": errors}


func instantiate_export(module_id: String, export_name: String) -> Dictionary:
	module_id = module_id.trim_prefix("#")
	if not _module_ids.has(module_id):
		return {"node": null, "context": null,
			"error": "module «%s» не подготовлен" % module_id}
	return {"node": null, "context": null,
		"error": "module «%s:%s»: WASM runtime unavailable" % [module_id, export_name]}


func close() -> void:
	_module_ids.clear()
