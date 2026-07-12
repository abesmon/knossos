class_name PageModuleStateAPI
extends RefCounted

## Module-namespaced facade Replicated State. Compatibility boundary для page scripts.

var _module_id: String
var _schemas: Dictionary = {} # local -> wire
var _objects: Dictionary = {} # "schema\nobject" -> {schema,object}
var _subscriptions: Dictionary = {} # "schema\nobject" -> Array[Callable]
var _connected := false
var _closed := false


func _init(module_id: String) -> void:
	_module_id = module_id


func register_schema(local_schema: String, definition: Dictionary) -> bool:
	if _closed or not _valid_local_id(local_schema):
		return false
	var wire := _wire(local_schema)
	if not NetworkManager.register_replicated_schema(wire, definition):
		return false
	_schemas[local_schema] = wire
	return true


func ensure_object(local_object: String, local_schema: String, initial: Dictionary = {},
		owner_user_id: String = "") -> bool:
	if _closed or not _valid_local_id(local_object) or not _schemas.has(local_schema):
		return false
	var wire_schema := str(_schemas[local_schema])
	var wire_object := _wire(local_object)
	if not NetworkManager.register_replicated_object(wire_object, wire_schema, initial, owner_user_id):
		return false
	_objects[_key(local_object, local_schema)] = {"schema": wire_schema, "object": wire_object}
	return true


func command(local_object: String, local_schema: String, version: int, command_name: String,
		args: Dictionary = {}) -> int:
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	if _closed or record.is_empty():
		return -1
	return NetworkManager.request_replicated_command(str(record.object), str(record.schema),
			version, command_name, args)


func read(local_object: String, local_schema: String) -> Dictionary:
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	if _closed or record.is_empty():
		return {}
	return NetworkManager.replicated_state(str(record.object), str(record.schema))


func revision(local_object: String, local_schema: String) -> int:
	var record: Dictionary = _objects.get(_key(local_object, local_schema), {})
	if _closed or record.is_empty():
		return -1
	return NetworkManager.replicated_revision(str(record.object), str(record.schema))


func subscribe(local_object: String, local_schema: String, callback: Callable) -> bool:
	var key := _key(local_object, local_schema)
	if _closed or not _objects.has(key) or not callback.is_valid():
		return false
	if not _subscriptions.has(key):
		_subscriptions[key] = []
	_subscriptions[key].append(callback)
	if not _connected:
		NetworkManager.replicated_state_received.connect(_on_state)
		_connected = true
	return true


func unsubscribe(local_object: String, local_schema: String, callback: Callable) -> void:
	var key := _key(local_object, local_schema)
	if _subscriptions.has(key):
		_subscriptions[key].erase(callback)
		if _subscriptions[key].is_empty():
			_subscriptions.erase(key)


func close() -> void:
	if _closed:
		return
	_closed = true
	if _connected and NetworkManager.replicated_state_received.is_connected(_on_state):
		NetworkManager.replicated_state_received.disconnect(_on_state)
	_connected = false
	_subscriptions.clear()
	for record in _objects.values():
		NetworkManager.unregister_replicated_object(str(record.object), str(record.schema))
	_objects.clear()
	for wire_schema in _schemas.values():
		NetworkManager.unregister_replicated_schema(str(wire_schema))
	_schemas.clear()


func is_closed() -> bool:
	return _closed


func _on_state(object_id: String, schema_id: String, state: Dictionary,
		changed: Dictionary, revision_value: int) -> void:
	for local_key in _objects:
		var record: Dictionary = _objects[local_key]
		if str(record.object) != object_id or str(record.schema) != schema_id:
			continue
		for callback in _subscriptions.get(local_key, []):
			if callback.is_valid():
				callback.call(state.duplicate(true), changed.duplicate(true), revision_value)


func _wire(local_id: String) -> String:
	return _module_id + "/" + local_id


static func _key(object_id: String, schema_id: String) -> String:
	return schema_id + "\n" + object_id


static func _valid_local_id(value: String) -> bool:
	return PageModuleCollector._id_error(value).is_empty()
