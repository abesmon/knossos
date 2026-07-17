class_name ScriptingModuleRegistry
extends RefCounted

## Delivery-facing registry. Runtime behavior is delegated to a single WASM backend.

var _backend: ScriptingModuleBackend


func _init(backend: ScriptingModuleBackend = null) -> void:
	if backend != null:
		_backend = backend
	elif NativeWasmBackend.is_available():
		_backend = NativeWasmBackend.new()
	else:
		_backend = UnavailableWasmBackend.new()


func prepare(modules: Array) -> Dictionary:
	return _backend.prepare(modules)


func instantiate_export(module_id: String, export_name: String) -> Dictionary:
	return _backend.instantiate_export(module_id, export_name)


func deliver_event(module_id: String, event: Dictionary) -> Dictionary:
	return _backend.deliver_event(module_id, event)


func unmount(module_id: String) -> void:
	_backend.unmount(module_id)


func reload_module(module: Dictionary) -> Dictionary:
	return _backend.reload_module(module)


func clear() -> void:
	_backend.close()
