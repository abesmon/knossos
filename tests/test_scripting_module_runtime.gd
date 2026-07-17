extends SceneTree

## Проверяет runtime-neutral dispatch и безопасную unavailable degradation до native WASM VM.

class FakeBackend extends ScriptingModuleBackend:
	var prepared: Array = []
	var events: Array = []
	var unmounted: Array[String] = []
	var closed := false

	func prepare(modules: Array) -> Dictionary:
		prepared = modules.duplicate(true)
		return {"ok": true, "errors": []}

	func instantiate_export(module_id: String, export_name: String) -> Dictionary:
		return {"node": null, "context": null, "error": "%s:%s" % [module_id, export_name]}

	func deliver_event(module_id: String, event: Dictionary) -> Dictionary:
		events.append({"module": module_id, "event": event})
		return {"ok": true, "error": ""}

	func unmount(module_id: String) -> void:
		unmounted.append(module_id)

	func close() -> void:
		closed = true


var _failed := false


func _initialize() -> void:
	var fake := FakeBackend.new()
	var registry := ScriptingModuleRegistry.new(fake)
	var modules := [{"id": "demo", "runtime": "wasm-component"}]
	_eq(registry.prepare(modules).ok, true, "registry delegates prepare")
	_eq(fake.prepared, modules, "backend receives normalized modules")
	_eq(registry.instantiate_export("demo", "Door").error, "demo:Door", "registry delegates export")
	_eq(registry.deliver_event("demo", {"kind": "tick"}).ok, true, "registry delegates event")
	registry.unmount("demo")
	_eq(fake.unmounted, ["demo"], "registry delegates unmount")
	registry.clear()
	_eq(fake.closed, true, "registry closes backend")

	var unavailable := ScriptingModuleRegistry.new(UnavailableWasmBackend.new())
	var unavailable_result := unavailable.prepare(modules)
	_eq(unavailable_result.ok, false, "unavailable backend rejects executable module")
	_eq(str(unavailable_result.errors[0]).contains("WASM runtime unavailable"), true,
			"unavailable error is explicit")
	_eq(str(unavailable.instantiate_export("demo", "Door").error).contains("WASM runtime unavailable"),
			true, "component degrades locally")
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
