class_name VrwebScriptState
extends RefCounted

## Revision-staged bridge to the replicated state subsystem.

var _script_id: String
var _schemas: Dictionary = {}
var _definitions: Dictionary = {}
var _objects: Dictionary = {}
var _subscriptions: Dictionary = {}
var _binding_subscriptions: Dictionary = {}
var _invoke: Callable
var _connected := false
var _authority_connected := false
var _closed := false
var _staging := true
var _pending_schemas: Dictionary = {}
var _pending_objects: Array[Dictionary] = []
var _pending_commands: Array[Dictionary] = []
var _pending_subscriptions: Array[Dictionary] = []
var _pending_binding_subscriptions: Array[Dictionary] = []
var _saved_states: Dictionary = {}
var _result_callbacks: Dictionary = {}
var _results_connected := false


func setup(script_id: String, invoke: Callable) -> void:
	_script_id = script_id
	_invoke = invoke


func api() -> Dictionary:
	return {"define": register_schema,
		"ensure": func(object_id, schema_id, initial, initial_bindings):
			var state_dict = _table_as_dictionary(initial)
			var bindings_dict = _table_as_dictionary(initial_bindings)
			if state_dict == null or bindings_dict == null:
				return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
			return ensure_object(str(object_id), str(schema_id), state_dict, bindings_dict),
		"read": read,
		"bindings": bindings, "binding": binding, "revision": revision,
		"command": func(object_id, schema_id, version, command_name, args = null, callback = null):
			return command(str(object_id), str(schema_id), int(version), str(command_name),
					args if args is Dictionary else {},
					callback if callback is Callable else Callable()),
		"on": subscribe, "on_bindings": subscribe_bindings}


func register_schema(local_schema: String, definition: Dictionary):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not VrwebScriptDeclaration.valid_id(local_schema):
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	if _staging:
		_pending_schemas[local_schema] = definition.duplicate(true)
		return true
	var wire := _wire(local_schema)
	var wrapped := _wrap_definition(definition)
	if not NetworkManager.register_replicated_schema(wire, wrapped):
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	_schemas[local_schema] = wire
	_definitions[local_schema] = wrapped
	return true


func ensure_object(local_object: String, local_schema: String, initial: Dictionary = {},
		bindings: Dictionary = {}):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not VrwebScriptDeclaration.valid_id(local_object):
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	if _staging:
		if not _pending_schemas.has(local_schema):
			return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
		_pending_objects.append({"object": local_object, "schema": local_schema,
			"initial": initial.duplicate(true), "bindings": bindings.duplicate(true)})
		return true
	if not _schemas.has(local_schema):
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	var wire_schema := str(_schemas[local_schema])
	var wire_object := _wire(local_object)
	if not NetworkManager.register_replicated_object(wire_object, wire_schema, initial, bindings):
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	_objects[_key(local_object, local_schema)] = {"schema": wire_schema, "object": wire_object,
		"bindings": bindings.duplicate(true), "initial": initial.duplicate(true)}
	_connect_authority()
	return true


func read(local_object: String, local_schema: String) -> Dictionary:
	if _staging:
		for pending in _pending_objects:
			if pending.object == local_object and pending.schema == local_schema:
				return (pending.initial as Dictionary).duplicate(true)
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	return {} if _closed or record.is_empty() else NetworkManager.replicated_state(
			str(record.object), str(record.schema))


func bindings(local_object: String, local_schema: String) -> Dictionary:
	if _staging:
		for pending in _pending_objects:
			if pending.object == local_object and pending.schema == local_schema:
				return (pending.bindings as Dictionary).duplicate(true)
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	return {} if _closed or record.is_empty() else NetworkManager.replicated_bindings(
			str(record.object), str(record.schema))


func binding(local_object: String, local_schema: String, name: String) -> String:
	return str(bindings(local_object, local_schema).get(name, ""))


func revision(local_object: String, local_schema: String) -> int:
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	return -1 if _closed or record.is_empty() else NetworkManager.replicated_revision(
			str(record.object), str(record.schema))


## Внутренний адрес для доменных capability-адаптеров того же page realm.
func wire_record(local_object: String, local_schema: String) -> Dictionary:
	return (_objects.get(_key(local_object, local_schema), {}) as Dictionary).duplicate(true)


## Опциональный callback — стандартное наблюдение исхода команды: он получает
## {ok, code, revision, request_id} из ACK авторитета (docs/network/replicated-state.md).
func command(local_object: String, local_schema: String, version: int, command_name: String,
		args: Dictionary = {}, callback: Callable = Callable()):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if _staging:
		_pending_commands.append({"object": local_object, "schema": local_schema,
			"version": version, "command": command_name, "args": args.duplicate(true),
			"callback": callback})
		return 0
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	if record.is_empty():
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	var request_id: int = NetworkManager.request_replicated_command(
			str(record.object), str(record.schema), version, command_name, args)
	_track_result(request_id, callback)
	return request_id


func _track_result(request_id: int, callback: Callable) -> void:
	if request_id < 0 or not callback.is_valid():
		return
	if not _results_connected:
		NetworkManager.replicated_command_result.connect(_on_command_result)
		_results_connected = true
	_result_callbacks[request_id] = callback


func _on_command_result(request_id: int, accepted: bool, code: String, revision: int) -> void:
	if _closed or not _result_callbacks.has(request_id):
		return
	var callback: Callable = _result_callbacks[request_id]
	_result_callbacks.erase(request_id)
	if callback.is_valid() and _invoke.is_valid():
		_invoke.call(callback, {"ok": accepted, "code": code, "revision": revision,
			"request_id": request_id})


func subscribe(local_object: String, local_schema: String, callback: Callable):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not callback.is_valid():
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var key := _key(local_object, local_schema)
	if _staging:
		_pending_subscriptions.append({"object": local_object, "schema": local_schema,
			"callback": callback})
		return true
	if not _objects.has(key):
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	if not _subscriptions.has(key):
		_subscriptions[key] = []
	_subscriptions[key].append(callback)
	if not _connected:
		NetworkManager.replicated_state_received.connect(_on_state)
		_connected = true
	return true


func subscribe_bindings(local_object: String, local_schema: String, callback: Callable):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not callback.is_valid():
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	if _staging:
		_pending_binding_subscriptions.append({"object": local_object, "schema": local_schema,
			"callback": callback})
		return true
	var key := _key(local_object, local_schema)
	if not _objects.has(key):
		return VrwebScriptError.err(VrwebScriptError.NOT_FOUND)
	if not _binding_subscriptions.has(key):
		_binding_subscriptions[key] = []
	_binding_subscriptions[key].append(callback)
	if not NetworkManager.replicated_bindings_received.is_connected(_on_bindings):
		NetworkManager.replicated_bindings_received.connect(_on_bindings)
	return true


func commit() -> bool:
	if _closed:
		return false
	_staging = false
	for local_schema in _pending_schemas:
		if register_schema(str(local_schema), _pending_schemas[local_schema]) != true:
			return false
	for pending in _pending_objects:
		if ensure_object(str(pending.object), str(pending.schema), pending.initial,
				pending.bindings) != true:
			return false
	for pending in _pending_subscriptions:
		subscribe(str(pending.object), str(pending.schema), pending.callback)
	for pending in _pending_binding_subscriptions:
		subscribe_bindings(str(pending.object), str(pending.schema), pending.callback)
	for pending in _pending_commands:
		command(str(pending.object), str(pending.schema), int(pending.version),
				str(pending.command), pending.args,
				pending.get("callback", Callable()))
	_pending_schemas.clear()
	_pending_objects.clear()
	_pending_subscriptions.clear()
	_pending_binding_subscriptions.clear()
	_pending_commands.clear()
	return true


func close(unregister := true) -> void:
	if _closed:
		return
	_closed = true
	if _connected and NetworkManager.replicated_state_received.is_connected(_on_state):
		NetworkManager.replicated_state_received.disconnect(_on_state)
	_connected = false
	if _authority_connected and NetworkManager.authority_changed.is_connected(_on_authority_changed):
		NetworkManager.authority_changed.disconnect(_on_authority_changed)
	_authority_connected = false
	_subscriptions.clear()
	_binding_subscriptions.clear()
	if _results_connected and NetworkManager.replicated_command_result.is_connected(_on_command_result):
		NetworkManager.replicated_command_result.disconnect(_on_command_result)
	_results_connected = false
	_result_callbacks.clear()
	if NetworkManager.replicated_bindings_received.is_connected(_on_bindings):
		NetworkManager.replicated_bindings_received.disconnect(_on_bindings)
	if unregister and not _staging:
		for record in _objects.values():
			NetworkManager.unregister_replicated_object(str(record.object), str(record.schema))
		for schema in _schemas.values():
			NetworkManager.unregister_replicated_schema(str(schema))
	_objects.clear()
	_schemas.clear()
	_definitions.clear()
	_pending_schemas.clear()
	_pending_objects.clear()
	_pending_subscriptions.clear()
	_pending_binding_subscriptions.clear()
	_pending_commands.clear()
	_saved_states.clear()
	_invoke = Callable()


## Reinstalls a still-live revision after a candidate commit rolled back shared wire ids.
func restore_registrations() -> bool:
	if _closed or _staging:
		return false
	for local_schema in _schemas:
		if not NetworkManager.register_replicated_schema(str(_schemas[local_schema]),
				_definitions.get(local_schema, {})):
			return false
	for record in _objects.values():
		var key := str(record.schema) + "\n" + str(record.object)
		var saved: Dictionary = _saved_states.get(key, {})
		if not NetworkManager.register_replicated_object(str(record.object), str(record.schema),
				(saved.get("state", {}) as Dictionary).duplicate(true),
				(saved.get("bindings", record.get("bindings", {})) as Dictionary).duplicate(true)):
			return false
	_saved_states.clear()
	return true


func snapshot_registrations() -> void:
	_saved_states.clear()
	for record in _objects.values():
		var key := str(record.schema) + "\n" + str(record.object)
		_saved_states[key] = {
			"state": NetworkManager.replicated_state(
					str(record.object), str(record.schema)).duplicate(true),
			"bindings": NetworkManager.replicated_bindings(
					str(record.object), str(record.schema)).duplicate(true),
		}


func registrations() -> Dictionary:
	var schemas := {}
	var objects := {}
	for wire in _schemas.values():
		schemas[str(wire)] = true
	for record in _objects.values():
		objects[str(record.schema) + "\n" + str(record.object)] = true
	return {"schemas": schemas, "objects": objects}


func retire_except(preserved: Dictionary) -> void:
	var keep_schemas: Dictionary = preserved.get("schemas", {})
	var keep_objects: Dictionary = preserved.get("objects", {})
	for record in _objects.values():
		var key := str(record.schema) + "\n" + str(record.object)
		if not keep_objects.has(key) and keep_schemas.has(str(record.schema)):
			NetworkManager.unregister_replicated_object(str(record.object), str(record.schema))
	for wire in _schemas.values():
		if not keep_schemas.has(str(wire)):
			NetworkManager.unregister_replicated_schema(str(wire))


func _on_state(object_id: String, schema_id: String, state: Dictionary,
		changed: Dictionary, revision_value: int) -> void:
	for local_key in _objects:
		var record: Dictionary = _objects[local_key]
		if str(record.object) != object_id or str(record.schema) != schema_id:
			continue
		for callback in _subscriptions.get(local_key, []):
			if callback.is_valid() and _invoke.is_valid():
				_invoke.call(callback, {"state": state.duplicate(true),
					"changed": changed.duplicate(true), "revision": revision_value})


func _on_bindings(object_id: String, schema_id: String, current: Dictionary,
		changed: Dictionary, revision_value: int) -> void:
	for local_key in _objects:
		var record: Dictionary = _objects[local_key]
		if str(record.object) != object_id or str(record.schema) != schema_id:
			continue
		for callback in _binding_subscriptions.get(local_key, []):
			if callback.is_valid() and _invoke.is_valid():
				_invoke.call(callback, {"bindings": current.duplicate(true),
					"changed": changed.duplicate(true), "revision": revision_value})


## Room/mesh replacement clears replicated objects after page scripts may already have run.
## Schemas survive reset_session, but registering both parts again is idempotent and also makes
## this bridge robust if the network implementation later scopes schemas to a room as well.
func _on_authority_changed(_authority: int, _is_me: bool) -> void:
	if _closed or _staging:
		return
	for local_schema in _schemas:
		NetworkManager.register_replicated_schema(str(_schemas[local_schema]),
				_definitions.get(local_schema, {}))
	for record in _objects.values():
		NetworkManager.register_replicated_object(str(record.object), str(record.schema),
				(record.get("initial", {}) as Dictionary).duplicate(true),
				(record.get("bindings", {}) as Dictionary).duplicate(true))


func _connect_authority() -> void:
	if _authority_connected:
		return
	NetworkManager.authority_changed.connect(_on_authority_changed)
	_authority_connected = true


func _wrap_definition(definition: Dictionary) -> Dictionary:
	var wrapped := definition.duplicate(true)
	var transaction_validator: Callable = wrapped.get("_transaction_validator", Callable())
	if wrapped.get("fields") is Array and (wrapped.fields as Array).is_empty():
		wrapped["fields"] = {}
	if wrapped.get("commands") is Array and (wrapped.commands as Array).is_empty():
		wrapped["commands"] = {}
	var commands: Dictionary = wrapped.get("commands", {})
	for command_name in commands:
		var spec: Dictionary = commands[command_name]
		var reducer: Callable = spec.get("reducer", Callable())
		if reducer.is_valid() and bool(spec.get("_host_reducer", false)):
			spec["reducer"] = func(state: Dictionary, args: Dictionary, context: Dictionary):
				var result = reducer.call(state.duplicate(true), args.duplicate(true), context.duplicate(true))
				return transaction_validator.call(state, context.get("bindings", {}), result, context) \
						if transaction_validator.is_valid() else result
		elif reducer.is_valid():
			spec["reducer"] = func(state: Dictionary, args: Dictionary, context: Dictionary):
				if not _invoke.is_valid():
					return state
				var result = _invoke.call(reducer, {"state": state, "args": args,
					"context": context}, true)
				if result is Dictionary:
					for patch_name in ["state", "bindings"]:
						if result.has(patch_name) and result[patch_name] is Array \
								and (result[patch_name] as Array).is_empty():
							result[patch_name] = {}
				if transaction_validator.is_valid():
					return transaction_validator.call(state, context.get("bindings", {}), result, context)
				return result if result is Dictionary else state
		spec.erase("_host_reducer")
		commands[command_name] = spec
	wrapped["commands"] = commands
	wrapped.erase("_transaction_validator")
	return wrapped


func _wire(local_id: String) -> String:
	return _script_id + "/" + local_id


static func _key(object_id: String, schema_id: String) -> String:
	return schema_id + "\n" + object_id


static func _table_as_dictionary(value):
	if value == null:
		return {}
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array and (value as Array).is_empty():
		return {}
	return null
