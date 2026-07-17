extends SceneTree

class ReentrantRuntime:
	extends RefCounted
	var backend: NativeWasmBackend
	var calls := 0
	var nested_result: Dictionary = {}

	func deliver_event_bytes(_instance: String, _envelope: PackedByteArray) -> bool:
		calls += 1
		if calls == 1:
			nested_result = backend.deliver_event("recursive", {"kind": "nested"})
		return true

	func get_last_error() -> String:
		return ""

	func unmount_instance(_instance: String) -> bool:
		return true

	func drop_component(_module: String) -> bool:
		return true

	func clear_components() -> void:
		pass


var _failed := false


func _initialize() -> void:
	var backend := NativeWasmBackend.new()
	var runtime := ReentrantRuntime.new()
	runtime.backend = backend
	backend._runtime = runtime
	backend._prepared = {"recursive": {"id": "recursive"}}
	backend._instances = {"recursive": ["recursive::0"]}
	var delivered := backend.deliver_event("recursive", {"kind": "outer"})
	_eq(delivered.ok, true, "outer event completes")
	_eq(runtime.nested_result.get("queued", false), true,
			"recursive delivery is queued instead of entering guest")
	_eq(runtime.calls, 2, "queued event runs only after outer guest phase")
	backend.close()
	runtime.backend = null
	backend = null
	runtime = null
	quit(1 if _failed else 0)


func _eq(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
