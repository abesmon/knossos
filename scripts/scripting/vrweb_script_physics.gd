class_name VrwebScriptPhysics
extends RefCounted

## Page capability, связывающий существующий VRWML <RigidBody3D> с одним namespaced
## Replicated State subject. Сетевой transport и proxy реализует RigidbodySync.

var _script_id := ""
var _state: VrwebScriptState
var _page_root: Node
var _invoke: Callable
var _pending: Array[Dictionary] = []
var _records: Dictionary = {} # local object -> {schema, wire object/schema, adapter}
var _subscriptions: Dictionary = {}
var _closed := false
var _committed := false


func setup(script_id: String, state: VrwebScriptState, page_root: Node,
		invoke: Callable) -> void:
	_script_id = script_id
	_state = state
	_page_root = page_root
	_invoke = invoke


func api() -> Dictionary:
	return {
		"claim": claim,
		"handoff": handoff,
		"apply_impulse": apply_impulse,
		"command": func(object_id, command_name, args = {}):
			return command(str(object_id), str(command_name), args if args is Dictionary else {}),
		"simulator": simulator,
		"is_local_simulator": is_local_simulator,
		"on_simulator": on_simulator,
	}


func bind(body: RigidBody3D, local_object: String, options: Dictionary = {}) -> bool:
	if _closed or _committed or body == null or not is_instance_valid(body) \
			or not VrwebScriptDeclaration.valid_id(local_object):
		return false
	for pending in _pending:
		if str(pending.object) == local_object or pending.body == body:
			return false
	var local_schema := "physics_%s" % local_object
	var commands = options.get("commands", {})
	if commands is Array and (commands as Array).is_empty():
		commands = {}
	if typeof(commands) != TYPE_DICTIONARY:
		return false
	var fields = options.get("fields", {})
	if fields is Array and (fields as Array).is_empty():
		fields = {}
	if typeof(fields) != TYPE_DICTIONARY:
		return false
	if not _state.register_schema(local_schema,
			RigidbodyStateSchema.definition(commands as Dictionary, fields as Dictionary)):
		return false
	if not _state.ensure_object(local_object, local_schema,
			RigidbodyStateSchema.initial_state(body), {}):
		return false
	_pending.append({"body": body, "object": local_object, "schema": local_schema,
		"options": options.duplicate(true)})
	return true


func commit() -> bool:
	if _closed:
		return false
	_committed = true
	for pending in _pending:
		var body: RigidBody3D = pending.body
		var local_object := str(pending.object)
		var local_schema := str(pending.schema)
		var wire := _state.wire_record(local_object, local_schema)
		if body == null or not is_instance_valid(body) or wire.is_empty():
			return false
		var adapter := RigidbodySync.new()
		adapter.name = "VRWebRigidbodySync_%s" % local_object
		adapter.setup(body, str(wire.object), str(wire.schema), pending.options)
		_page_root.add_child(adapter)
		_records[local_object] = {"schema": local_schema, "object": str(wire.object),
			"wire_schema": str(wire.schema), "adapter": adapter, "body": body}
	_pending.clear()
	if not _records.is_empty() \
			and not NetworkManager.replicated_bindings_received.is_connected(_on_bindings):
		NetworkManager.replicated_bindings_received.connect(_on_bindings)
	return true


func close(replacement: VrwebScriptPhysics = null) -> void:
	if _closed:
		return
	_closed = true
	if NetworkManager.replicated_bindings_received.is_connected(_on_bindings):
		NetworkManager.replicated_bindings_received.disconnect(_on_bindings)
	for record in _records.values():
		var adapter: Node = record.get("adapter")
		if adapter != null and is_instance_valid(adapter):
			if adapter.has_method("shutdown"):
				adapter.shutdown(not _replacement_owns_body(replacement, record.get("body")))
			adapter.queue_free()
	_records.clear()
	_pending.clear()
	_subscriptions.clear()
	_invoke = Callable()
	_page_root = null


func _replacement_owns_body(replacement: VrwebScriptPhysics, target) -> bool:
	if replacement == null or target == null:
		return false
	for record in replacement._records.values():
		if record.get("body") == target:
			return true
	return false


func claim(local_object: String) -> int:
	var adapter := _adapter(local_object)
	return -1 if adapter == null else adapter.claim()


func handoff(local_object: String, command_name: String) -> int:
	var adapter := _adapter(local_object)
	return -1 if adapter == null else adapter.handoff(command_name)


func apply_impulse(local_object: String, impulse) -> bool:
	var adapter := _adapter(local_object)
	return false if adapter == null or typeof(impulse) != TYPE_VECTOR3 \
			else adapter.apply_impulse(impulse)


func command(local_object: String, command_name: String, args: Dictionary = {}) -> int:
	var adapter := _adapter(local_object)
	return -1 if adapter == null else adapter.command(command_name, args)


func simulator(local_object: String) -> String:
	var adapter := _adapter(local_object)
	return "" if adapter == null else adapter.simulator()


func is_local_simulator(local_object: String) -> bool:
	var adapter := _adapter(local_object)
	return false if adapter == null else adapter.is_local_simulator()


func on_simulator(local_object: String, callback: Callable) -> bool:
	if _closed or not callback.is_valid():
		return false
	if not _subscriptions.has(local_object):
		_subscriptions[local_object] = []
	_subscriptions[local_object].append(callback)
	return true


func _adapter(local_object: String) -> RigidbodySync:
	var record: Dictionary = _records.get(local_object, {})
	var adapter = record.get("adapter")
	return adapter as RigidbodySync if adapter is RigidbodySync and is_instance_valid(adapter) else null


func _on_bindings(object_id: String, schema_id: String, bindings: Dictionary,
		changed: Dictionary, revision: int) -> void:
	if not changed.has("simulator"):
		return
	for local_object in _records:
		var record: Dictionary = _records[local_object]
		if str(record.object) != object_id or str(record.wire_schema) != schema_id:
			continue
		for callback in _subscriptions.get(local_object, []):
			if callback.is_valid() and _invoke.is_valid():
				_invoke.call(callback, {"simulator": str(bindings.get("simulator", "")),
					"revision": revision})
