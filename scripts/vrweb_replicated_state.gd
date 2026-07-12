class_name VrwebReplicatedState
extends Node

## Невизуальная декларативная часть Replicated State. Не владеет представлением и может
## лежать ребёнком предмета, его соседом либо в отдельной ветке страницы.

var object_id := ""
var schema_id := ""
var schema_version := 1
var initial_state: Dictionary = {}
var field_specs: Dictionary = {}
var command_specs: Dictionary = {}
var bindings: Array[Dictionary] = []
var optimistic := true

var _state: Dictionary = {}
var _pending_requests: Dictionary = {}


func setup(config: Dictionary) -> void:
	object_id = str(config.get("object_id", ""))
	schema_id = str(config.get("schema_id", ""))
	schema_version = int(config.get("version", 1))
	initial_state = (config.get("initial", {}) as Dictionary).duplicate(true)
	field_specs = (config.get("fields", {}) as Dictionary).duplicate(true)
	command_specs = (config.get("commands", {}) as Dictionary).duplicate(true)
	bindings = (config.get("bindings", []) as Array).duplicate(true)
	optimistic = bool(config.get("optimistic", true))


func _ready() -> void:
	var commands := {}
	for command_name in command_specs:
		var spec: Dictionary = command_specs[command_name]
		commands[command_name] = {"reducer": VrwebReplicatedState._reduce.bind(spec)}
	var definition := {
		"version": schema_version,
		"fields": field_specs,
		"default_write_rule": {"rank": {"op": "lte", "value": NetworkManager.DEFAULT_RANK}},
		"commands": commands,
	}
	if not NetworkManager.register_replicated_schema(schema_id, definition):
		Log.warn("builder", "невалидная декларативная replicated-схема «%s»" % schema_id)
		return
	NetworkManager.replicated_state_received.connect(_on_replicated_state)
	NetworkManager.replicated_command_result.connect(_on_command_result)
	NetworkManager.authority_changed.connect(_on_authority_changed)
	_register_object()
	_state = NetworkManager.replicated_state(object_id, schema_id)
	if _state.is_empty():
		_state = initial_state.duplicate(true)
	_apply_bindings()


func _exit_tree() -> void:
	NetworkManager.unregister_replicated_object(object_id, schema_id)


func request_command(command: String, args: Dictionary = {}) -> int:
	if not command_specs.has(command):
		return -1
	if optimistic:
		var patch := _reduce(_state, args, {}, command_specs[command])
		for field in patch:
			_state[field] = patch[field]
		_apply_bindings()
	var request_id := NetworkManager.request_replicated_command(
			object_id, schema_id, schema_version, command, args)
	if NetworkManager.in_room():
		_pending_requests[request_id] = true
	return request_id


func state() -> Dictionary:
	return _state.duplicate(true)


func _register_object() -> void:
	if not object_id.is_empty() and not schema_id.is_empty():
		NetworkManager.register_replicated_object(object_id, schema_id, initial_state)


func _on_authority_changed(_authority: int, _is_me: bool) -> void:
	_register_object()


func _on_replicated_state(received_object_id: String, received_schema_id: String,
		state_value: Dictionary, _changed: Dictionary, _revision: int) -> void:
	if received_object_id != object_id or received_schema_id != schema_id:
		return
	_state = state_value.duplicate(true)
	_apply_bindings()


func _on_command_result(request_id: int, accepted: bool, _code: String, _revision: int) -> void:
	if not _pending_requests.has(request_id):
		return
	_pending_requests.erase(request_id)
	if not accepted:
		_state = NetworkManager.replicated_state(object_id, schema_id)
		_apply_bindings()


func _apply_bindings() -> void:
	if not is_node_ready():
		return
	for binding in bindings:
		var target := get_node_or_null(str(binding.get("target", "")))
		var field := str(binding.get("field", ""))
		var property := str(binding.get("property", ""))
		if target == null or property.is_empty() or not _state.has(field):
			continue
		var value = binding.get("true_value") if bool(_state[field]) \
				else binding.get("false_value")
		target.set_indexed(NodePath(property), value)


static func _reduce(state_value: Dictionary, args: Dictionary, _context: Dictionary,
		spec: Dictionary) -> Dictionary:
	var field := str(spec.get("field", ""))
	match str(spec.get("operation", "")):
		"toggle":
			return {field: not bool(state_value.get(field, false))}
		"set":
			return {field: args.get(str(spec.get("arg", "value")), spec.get("value"))}
	return {}
