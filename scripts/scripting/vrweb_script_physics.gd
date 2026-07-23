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
var _result_callbacks: Dictionary = {}
var _results_connected := false
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
		"claim": func(object_id, callback = null):
			return claim(str(object_id), callback if callback is Callable else Callable()),
		"handoff": func(object_id, command_name, callback = null):
			return handoff(str(object_id), str(command_name),
					callback if callback is Callable else Callable()),
		"apply_impulse": apply_impulse,
		"command": func(object_id, command_name, args = null, callback = null):
			return command(str(object_id), str(command_name), args if args is Dictionary else {},
					callback if callback is Callable else Callable()),
		"simulator": simulator,
		"is_local_simulator": is_local_simulator,
		"on_simulator": on_simulator,
	}


## Возвращает код стандартного контракта ("" — успех): host превращает его в `nil, code`.
func bind(body: RigidBody3D, local_object: String, options: Dictionary = {}) -> String:
	if _closed:
		return VrwebScriptError.LIFECYCLE
	if _committed:
		# bind — часть staged top-level: после commit realm состав physics-схем зафиксирован.
		return VrwebScriptError.LIFECYCLE
	if body == null or not is_instance_valid(body) \
			or not VrwebScriptDeclaration.valid_id(local_object):
		return VrwebScriptError.INVALID_ARGS
	for pending in _pending:
		if str(pending.object) == local_object or pending.body == body:
			return VrwebScriptError.BUSY
	var local_schema := "physics_%s" % local_object
	var commands = options.get("commands", {})
	if commands is Array and (commands as Array).is_empty():
		commands = {}
	if typeof(commands) != TYPE_DICTIONARY:
		return VrwebScriptError.INVALID_ARGS
	var fields = options.get("fields", {})
	if fields is Array and (fields as Array).is_empty():
		fields = {}
	if typeof(fields) != TYPE_DICTIONARY:
		return VrwebScriptError.INVALID_ARGS
	if _state.register_schema(local_schema,
			RigidbodyStateSchema.definition(commands as Dictionary, fields as Dictionary)) != true:
		return VrwebScriptError.INVALID_ARGS
	if _state.ensure_object(local_object, local_schema,
			RigidbodyStateSchema.initial_state(body), {}) != true:
		return VrwebScriptError.INTERNAL
	_pending.append({"body": body, "object": local_object, "schema": local_schema,
		"options": options.duplicate(true)})
	return ""


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
	if _results_connected and NetworkManager.replicated_command_result.is_connected(_on_command_result):
		NetworkManager.replicated_command_result.disconnect(_on_command_result)
	_results_connected = false
	_result_callbacks.clear()
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


## claim/handoff/command возвращают request_id; опциональный callback получает
## {ok, code, revision, request_id} из того же ACK-пути, что document.state.command.
func claim(local_object: String, callback: Callable = Callable()):
	var adapter := _adapter(local_object)
	if adapter == null:
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	return _tracked(adapter.claim(), callback)


func handoff(local_object: String, command_name: String, callback: Callable = Callable()):
	var adapter := _adapter(local_object)
	if adapter == null:
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	return _tracked(adapter.handoff(command_name), callback)


func apply_impulse(local_object: String, impulse):
	var adapter := _adapter(local_object)
	if adapter == null:
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	if typeof(impulse) != TYPE_VECTOR3:
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	return adapter.apply_impulse(impulse)


func command(local_object: String, command_name: String, args: Dictionary = {},
		callback: Callable = Callable()):
	var adapter := _adapter(local_object)
	if adapter == null:
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	return _tracked(adapter.command(command_name, args), callback)


func _tracked(request_id: int, callback: Callable):
	if request_id >= 0 and callback.is_valid():
		if not _results_connected:
			NetworkManager.replicated_command_result.connect(_on_command_result)
			_results_connected = true
		_result_callbacks[request_id] = callback
	return request_id


func _on_command_result(request_id: int, accepted: bool, code: String, revision: int) -> void:
	if _closed or not _result_callbacks.has(request_id):
		return
	var callback: Callable = _result_callbacks[request_id]
	_result_callbacks.erase(request_id)
	if callback.is_valid() and _invoke.is_valid():
		_invoke.call(callback, {"ok": accepted, "code": code, "revision": revision,
			"request_id": request_id})


func simulator(local_object: String) -> String:
	var adapter := _adapter(local_object)
	return "" if adapter == null else adapter.simulator()


func is_local_simulator(local_object: String) -> bool:
	var adapter := _adapter(local_object)
	return false if adapter == null else adapter.is_local_simulator()


func on_simulator(local_object: String, callback: Callable):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not callback.is_valid():
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
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
