class_name VrwebScriptState
extends RefCounted

## Revision-staged bridge to the replicated state subsystem.

var _script_id: String
var _schemas: Dictionary = {}
var _definitions: Dictionary = {}
var _objects: Dictionary = {}
var _subscriptions: Dictionary = {}
var _invoke: Callable
var _connected := false
var _authority_connected := false
var _closed := false
var _staging := true
var _pending_schemas: Dictionary = {}
var _pending_objects: Array[Dictionary] = []
var _pending_commands: Array[Dictionary] = []
var _pending_subscriptions: Array[Dictionary] = []
var _saved_states: Dictionary = {}


func setup(script_id: String, invoke: Callable) -> void:
	_script_id = script_id
	_invoke = invoke


func api() -> Dictionary:
	return {"define": register_schema, "ensure": ensure_object, "read": read,
		"revision": revision,
		"command": func(object_id, schema_id, version, command_name, args = {}):
			return command(str(object_id), str(schema_id), int(version), str(command_name),
					args if args is Dictionary else {}),
		"on": subscribe}


func register_schema(local_schema: String, definition: Dictionary) -> bool:
	if _closed or not VrwebScriptDeclaration.valid_id(local_schema):
		return false
	if _staging:
		_pending_schemas[local_schema] = definition.duplicate(true)
		return true
	var wire := _wire(local_schema)
	var wrapped := _wrap_definition(definition)
	if not NetworkManager.register_replicated_schema(wire, wrapped):
		return false
	_schemas[local_schema] = wire
	_definitions[local_schema] = wrapped
	return true


func ensure_object(local_object: String, local_schema: String, initial: Dictionary = {},
		owner_user_id: String = "") -> bool:
	if _closed or not VrwebScriptDeclaration.valid_id(local_object):
		return false
	if _staging:
		if not _pending_schemas.has(local_schema):
			return false
		_pending_objects.append({"object": local_object, "schema": local_schema,
			"initial": initial.duplicate(true), "owner": owner_user_id})
		return true
	if not _schemas.has(local_schema):
		return false
	var wire_schema := str(_schemas[local_schema])
	var wire_object := _wire(local_object)
	if not NetworkManager.register_replicated_object(wire_object, wire_schema, initial, owner_user_id):
		return false
	_objects[_key(local_object, local_schema)] = {"schema": wire_schema, "object": wire_object,
		"owner": owner_user_id, "initial": initial.duplicate(true)}
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


func revision(local_object: String, local_schema: String) -> int:
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	return -1 if _closed or record.is_empty() else NetworkManager.replicated_revision(
			str(record.object), str(record.schema))


func command(local_object: String, local_schema: String, version: int, command_name: String,
		args: Dictionary = {}) -> int:
	if _staging:
		_pending_commands.append({"object": local_object, "schema": local_schema,
			"version": version, "command": command_name, "args": args.duplicate(true)})
		return 0
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	return -1 if _closed or record.is_empty() else NetworkManager.request_replicated_command(
			str(record.object), str(record.schema), version, command_name, args)


func subscribe(local_object: String, local_schema: String, callback: Callable) -> bool:
	if _closed or not callback.is_valid():
		return false
	var key := _key(local_object, local_schema)
	if _staging:
		_pending_subscriptions.append({"object": local_object, "schema": local_schema,
			"callback": callback})
		return true
	if not _objects.has(key):
		return false
	if not _subscriptions.has(key):
		_subscriptions[key] = []
	_subscriptions[key].append(callback)
	if not _connected:
		NetworkManager.replicated_state_received.connect(_on_state)
		_connected = true
	return true


func commit() -> bool:
	if _closed:
		return false
	_staging = false
	for local_schema in _pending_schemas:
		if not register_schema(str(local_schema), _pending_schemas[local_schema]):
			return false
	for pending in _pending_objects:
		if not ensure_object(str(pending.object), str(pending.schema), pending.initial,
				str(pending.owner)):
			return false
	for pending in _pending_subscriptions:
		subscribe(str(pending.object), str(pending.schema), pending.callback)
	for pending in _pending_commands:
		command(str(pending.object), str(pending.schema), int(pending.version),
				str(pending.command), pending.args)
	_pending_schemas.clear()
	_pending_objects.clear()
	_pending_subscriptions.clear()
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
		var current: Dictionary = _saved_states.get(key, {})
		if not NetworkManager.register_replicated_object(str(record.object), str(record.schema),
				current, str(record.get("owner", ""))):
			return false
	_saved_states.clear()
	return true


func snapshot_registrations() -> void:
	_saved_states.clear()
	for record in _objects.values():
		var key := str(record.schema) + "\n" + str(record.object)
		_saved_states[key] = NetworkManager.replicated_state(
				str(record.object), str(record.schema)).duplicate(true)


func ownership() -> Dictionary:
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
				str(record.get("owner", "")))


func _connect_authority() -> void:
	if _authority_connected:
		return
	NetworkManager.authority_changed.connect(_on_authority_changed)
	_authority_connected = true


func _wrap_definition(definition: Dictionary) -> Dictionary:
	var wrapped := definition.duplicate(true)
	if wrapped.get("fields") is Array and (wrapped.fields as Array).is_empty():
		wrapped["fields"] = {}
	if wrapped.get("commands") is Array and (wrapped.commands as Array).is_empty():
		wrapped["commands"] = {}
	var commands: Dictionary = wrapped.get("commands", {})
	for command_name in commands:
		var spec: Dictionary = commands[command_name]
		var reducer: Callable = spec.get("reducer", Callable())
		if reducer.is_valid():
			spec["reducer"] = func(state: Dictionary, args: Dictionary, context: Dictionary):
				if not _invoke.is_valid():
					return state
				var result = _invoke.call(reducer, {"state": state, "args": args,
					"context": context}, true)
				return result if result is Dictionary else state
		commands[command_name] = spec
	wrapped["commands"] = commands
	return wrapped


func _wire(local_id: String) -> String:
	return _script_id + "/" + local_id


static func _key(object_id: String, schema_id: String) -> String:
	return schema_id + "\n" + object_id
