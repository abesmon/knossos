class_name VrwebScriptRemote
extends RefCounted

## Typed targeted transient calls for one page-script realm.

const MAX_ENDPOINTS := 32
const TYPE_NAMES := {
	"any": true, "bool": true, "int": true, "float": true, "string": true,
	"vector2": true, "vector3": true, "vector4": true, "color": true,
	"quaternion": true, "bytes": true, "array": true, "dictionary": true,
}

var _script_id := ""
var _invoke: Callable
var _endpoints: Dictionary = {}
var _pending_calls: Array[Dictionary] = []
var _closed := false
var _staging := true
var _connected := false


func setup(script_id: String, invoke: Callable) -> void:
	_script_id = script_id
	_invoke = invoke


func api() -> Dictionary:
	return {
		"expose": expose,
		"call": func(target_peer_id, target_script_id, endpoint, version, args = []):
			return send(int(target_peer_id), str(target_script_id), str(endpoint), int(version),
					args if args is Array else []),
	}


func expose(endpoint: String, schema: Dictionary, callback: Callable) -> bool:
	if _closed or not VrwebScriptDeclaration.valid_id(endpoint) or not callback.is_valid() \
			or _endpoints.size() >= MAX_ENDPOINTS or _endpoints.has(endpoint):
		return false
	var normalized := _normalize_schema(schema)
	if normalized.is_empty():
		return false
	_endpoints[endpoint] = {"schema": normalized, "callback": callback}
	return true


func send(target_peer_id: int, target_script_id: String, endpoint: String, version: int,
		args: Array = []) -> bool:
	if _closed or not VrwebScriptDeclaration.valid_id(target_script_id) \
			or not VrwebScriptDeclaration.valid_id(endpoint) or version < 1:
		return false
	var record := {"target": target_peer_id, "script": target_script_id,
		"endpoint": endpoint, "version": version, "args": args.duplicate(true)}
	if _staging:
		_pending_calls.append(record)
		return true
	return NetworkManager.send_script_remote_call(target_peer_id, target_script_id, endpoint,
			version, args)


func commit() -> bool:
	if _closed:
		return false
	_staging = false
	NetworkManager.script_remote_call_received.connect(_on_remote_call)
	_connected = true
	for record in _pending_calls:
		NetworkManager.send_script_remote_call(int(record.target), str(record.script),
				str(record.endpoint), int(record.version), record.args)
	_pending_calls.clear()
	return true


func close() -> void:
	if _closed:
		return
	_closed = true
	if _connected and NetworkManager.script_remote_call_received.is_connected(_on_remote_call):
		NetworkManager.script_remote_call_received.disconnect(_on_remote_call)
	_connected = false
	_endpoints.clear()
	_pending_calls.clear()
	_invoke = Callable()


func _on_remote_call(sender_id: int, target_script_id: String, endpoint: String,
		version: int, args: Array) -> void:
	if _closed or _staging or target_script_id != _script_id or not _endpoints.has(endpoint):
		return
	var record: Dictionary = _endpoints[endpoint]
	var schema: Dictionary = record.schema
	if version != int(schema.version) or not _validate_args(args, schema.args):
		return
	var callback: Callable = record.callback
	if callback.is_valid() and _invoke.is_valid():
		_invoke.call(callback, {
			"caller": VrwebScriptPlayers.peer_snapshot(sender_id),
			"args": args.duplicate(true),
			"endpoint": endpoint,
			"version": version,
		})


func _normalize_schema(schema: Dictionary) -> Dictionary:
	var version := int(schema.get("version", 0))
	var args = schema.get("args", [])
	if version < 1 or not (args is Array) or args.size() > 8:
		return {}
	var normalized_args: Array[String] = []
	for type_name in args:
		var name := str(type_name).to_lower()
		if not TYPE_NAMES.has(name):
			return {}
		normalized_args.append(name)
	return {"version": version, "args": normalized_args}


func _validate_args(args: Array, expected: Array) -> bool:
	if args.size() != expected.size():
		return false
	for index in args.size():
		if not _matches_type(args[index], str(expected[index])):
			return false
	return true


func _matches_type(value, expected: String) -> bool:
	if expected == "any":
		return true
	match expected:
		"bool": return typeof(value) == TYPE_BOOL
		"int": return typeof(value) == TYPE_INT
		"float": return typeof(value) in [TYPE_FLOAT, TYPE_INT]
		"string": return typeof(value) == TYPE_STRING
		"vector2": return typeof(value) == TYPE_VECTOR2
		"vector3": return typeof(value) == TYPE_VECTOR3
		"vector4": return typeof(value) == TYPE_VECTOR4
		"color": return typeof(value) == TYPE_COLOR
		"quaternion": return typeof(value) == TYPE_QUATERNION
		"bytes": return typeof(value) == TYPE_PACKED_BYTE_ARRAY
		"array": return typeof(value) == TYPE_ARRAY
		"dictionary": return typeof(value) == TYPE_DICTIONARY
	return false
