class_name WasmHostContext
extends RefCounted

var authority: SceneAuthority
var services: WasmModuleServices
var _closed := false
var _conformance_trace: Array[String] = []


func _init(scene_authority: SceneAuthority, module_services: WasmModuleServices) -> void:
	authority = scene_authority
	services = module_services


func host_call(operation: String, id: int, payload: PackedByteArray,
		nested: Array) -> Variant:
	if _closed:
		return "instance_stopped"
	if _conformance_trace.size() < WasmModuleServices.MAX_EVENTS:
		_conformance_trace.append(operation)
	if operation.begins_with("scene."):
		return authority.wasm_host_call(operation.trim_prefix("scene."), id, payload, nested)
	return services.wasm_host_call(operation, id, payload, nested)


func conformance_trace() -> Array[String]:
	return _conformance_trace.duplicate()


func close() -> void:
	if _closed: return
	_closed = true
	services.close()
	authority.close()
