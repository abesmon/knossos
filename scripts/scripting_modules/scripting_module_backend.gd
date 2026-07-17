class_name ScriptingModuleBackend
extends RefCounted

## Runtime-neutral boundary used by delivery/materialization. Concrete backends must never expose
## engine objects to guest code; the unavailable backend is used until the native WASM VM exists.

func prepare(_modules: Array) -> Dictionary:
	return {"ok": true, "errors": []}


func instantiate_export(_module_id: String, _export_name: String) -> Dictionary:
	return {"node": null, "context": null, "error": "WASM backend did not instantiate export"}


func deliver_event(_module_id: String, _event: Dictionary) -> Dictionary:
	return {"ok": false, "error": "WASM backend unavailable"}


func unmount(_module_id: String) -> void:
	pass


func reload_module(_module: Dictionary) -> Dictionary:
	return {"ok": false, "error": "WASM backend does not support reload", "replacements": []}


func close() -> void:
	pass
