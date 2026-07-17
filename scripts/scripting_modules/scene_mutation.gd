class_name SceneMutation
extends RefCounted

const MAX_COMMANDS := 256

var _authority: SceneAuthority
var _commands: Array[Dictionary] = []
var _create_tokens: Dictionary = {}
var _closed := false


func _init(authority: SceneAuthority) -> void:
	_authority = authority


func set_property(handle: int, property: String, encoded_value: Dictionary) -> Dictionary:
	if _closed:
		return _error("transaction_closed")
	if _commands.size() >= MAX_COMMANDS:
		return _error("command_limit")
	_commands.append({"op": "set", "handle": handle, "property": property,
		"encoded": encoded_value.duplicate(true)})
	return _ok(null)


func create_node(class_name_: String, parent_handle: int,
		initial_properties: Dictionary = {}, token: String = "") -> Dictionary:
	if _closed: return _error("transaction_closed")
	if _commands.size() >= MAX_COMMANDS: return _error("command_limit")
	var create_token := token if not token.is_empty() else str(_commands.size())
	if _create_tokens.has(create_token): return _error("duplicate_create_token")
	_create_tokens[create_token] = true
	_commands.append({"op": "create", "class": class_name_, "parent": parent_handle,
		"initial": initial_properties.duplicate(true), "token": create_token})
	return _ok(create_token)


func set_resource(node_handle: int, property: String, resource_handle: int) -> Dictionary:
	if _closed: return _error("transaction_closed")
	if _commands.size() >= MAX_COMMANDS: return _error("command_limit")
	_commands.append({"op": "set_resource", "handle": node_handle,
		"property": property, "resource": resource_handle})
	return _ok(null)


func reparent(node_handle: int, parent_handle: int) -> Dictionary:
	if _closed: return _error("transaction_closed")
	if _commands.size() >= MAX_COMMANDS: return _error("command_limit")
	_commands.append({"op": "reparent", "handle": node_handle, "parent": parent_handle})
	return _ok(null)


func destroy(node_handle: int) -> Dictionary:
	if _closed: return _error("transaction_closed")
	if _commands.size() >= MAX_COMMANDS: return _error("command_limit")
	_commands.append({"op": "destroy", "handle": node_handle})
	return _ok(null)


func commit() -> Dictionary:
	if _closed:
		return _error("transaction_closed")
	_closed = true
	var create_count := 0
	for command in _commands:
		if str(command.op) == "create":
			create_count += 1
	if not _authority.can_allocate_guest_nodes(create_count):
		return _error("node_quota")
	var prepared: Array[Dictionary] = []
	for index in _commands.size():
		var command: Dictionary = _commands[index]
		var checked: Dictionary
		match str(command.op):
			"set": checked = _authority.validate_property_write(
					int(command.handle), str(command.property), command.encoded)
			"create": checked = _authority.validate_create_node(
					str(command["class"]), int(command.parent), command.initial)
			"set_resource": checked = _authority.validate_resource_write(
					int(command.handle), str(command.property), int(command.resource))
			"reparent": checked = _authority.validate_reparent(
					int(command.handle), int(command.parent))
			"destroy": checked = _authority.validate_destroy(int(command.handle))
			_: checked = _error("unknown_operation")
		if not bool(checked.ok):
			for prepared_command in prepared:
				if prepared_command.op == "create": prepared_command.value.node.free()
			return checked
		prepared.append({"op": command.op, "value": checked.value,
			"token": str(command.get("token", index))})
	var created := {}
	for command in prepared:
		match str(command.op):
			"set", "set_resource":
				command.value.node.set(command.value.property, command.value.value)
			"create":
				var node: Node = command.value.node
				for property in command.value.properties:
					node.set(property.property, property.value)
				command.value.parent.add_child(node)
				created[command.token] = _authority.adopt_created_node(node)
			"reparent":
				command.value.node.reparent(command.value.parent, false)
			"destroy":
				_authority.forget_destroyed(command.value)
				command.value.free()
	_commands.clear()
	_create_tokens.clear()
	return _ok({"applied": prepared.size(), "created": created})


func cancel() -> void:
	_closed = true
	_commands.clear()
	_create_tokens.clear()


func _ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


func _error(code: String) -> Dictionary:
	return {"ok": false, "value": null, "error": code}
