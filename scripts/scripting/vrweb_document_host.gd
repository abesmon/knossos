class_name VrwebDocumentHost
extends RefCounted

## Narrow, engine-independent capability surface exposed to one Luau script.

const MAX_HANDLES := 256
const MAX_TIMERS := 64
const MAX_UPDATE_CALLBACKS := 8
const MAX_HOST_CALLS := 10_000
const MAX_VALUE_BYTES := 64 * 1024
const CREATE_CLASSES := {
	"Node3D": true, "MeshInstance3D": true, "StaticBody3D": true, "Area3D": true,
	"CollisionShape3D": true, "Label3D": true, "OmniLight3D": true,
	"DirectionalLight3D": true, "SpotLight3D": true, "CSGBox3D": true,
	"CSGSphere3D": true,
}
const SAFE_METHODS := {"show": true, "hide": true, "play": true, "stop": true}
const BLOCKED_PROPERTIES := {
	"script": true, "owner": true, "scene_file_path": true,
	"process_mode": true, "process_priority": true, "process_physics_priority": true,
	"process_thread_group": true, "process_thread_messages": true,
}
const CAPABILITIES := {
	"vrweb/core/1": true,
	"vrweb/scene/1": true,
	"vrweb/state/1": true,
	"vrweb/remote/1": true,
	"vrweb/players/1": true,
	"vrweb/player/1": true,
	"vrweb/assets/1": true,
	"vrweb/clock/1": true,
	"vrweb/log/1": true,
}

var script_id := ""
var script_hash := ""
var session: Dictionary = {}

var _page_root: Node
var _targets: Dictionary = {}
var _base_url := ""
var _player: Node
var _owner: Node
var _invoke: Callable
var _policy: VrwebContentPolicy
var _valid := true
var _staging := true
var _calls := 0
var _next_handle := 1
var _handles: Dictionary = {}
var _reverse_handles: Dictionary = {}
var _owned: Dictionary = {}
var _pending_sets: Array[Dictionary] = []
var _overrides: Dictionary = {}
var _pending_events: Array[Dictionary] = []
var _pending_timers: Array[Dictionary] = []
var _pending_updates: Array[Callable] = []
var _input_bridges: Array[VrwebScriptInputBridge] = []
var _timers: Dictionary = {}
var _updates: Array[Callable] = []
var _next_timer := 1
var _state := VrwebScriptState.new()
var _remote := VrwebScriptRemote.new()
var _players := VrwebScriptPlayers.new()
var _clock_snapshot: Callable


func setup(id: String, content_hash: String, page_root: Node, targets: Dictionary,
		base_url: String, player: Node, owner: Node, invoke: Callable,
		previous_session: Dictionary, policy: VrwebContentPolicy,
		clock_snapshot: Callable = Callable()) -> void:
	script_id = id
	script_hash = content_hash
	_page_root = page_root
	_targets = targets.duplicate()
	_base_url = base_url
	_player = player
	_owner = owner
	_invoke = invoke
	session = previous_session.duplicate(true)
	_policy = policy
	_clock_snapshot = clock_snapshot
	_state.setup(script_id, _invoke)
	_remote.setup(script_id, _invoke)
	_players.setup(_invoke)


func api() -> Dictionary:
	return {
		"query": query,
		"query_all": query_all,
		"create": create,
		"session_get": func(key: String, fallback = null): return session.get(key, fallback),
		"session_set": func(key: String, value): return _session_set(key, value),
		"session": session,
		"state": _state.api(),
		"remote": _remote.api(),
		"players": _players.api(),
		"assets": {"resolve": resolve_asset},
		"clock": {"local_time": local_time, "authority_time": authority_time,
			"authority_ready": authority_clock_ready, "set_timeout": set_timeout,
			"set_interval": set_interval, "cancel": cancel_timer},
		"on_update": on_update,
		"values": {"vector3": make_vector3, "color": make_color},
		"player": {"get": player_get, "set_position": player_set_position},
		"log": {"debug": log_debug, "info": log_info, "warning": log_warning,
			"error": log_error},
		"features": {"has": feature_has, "require": feature_require},
	}


func commit() -> bool:
	if not _valid or not is_instance_valid(_page_root):
		return false
	if not _state.commit():
		return false
	if not _remote.commit() or not _players.commit():
		return false
	for handle_id in _owned:
		var node: Node = _owned[handle_id]
		if is_instance_valid(node) and node.get_parent() == null:
			_page_root.add_child(node)
	for operation in _pending_sets:
		_apply_set(operation.node, operation.property, operation.value)
	for event in _pending_events:
		_connect_event(event.node, event.name, event.callback, event.hint)
	for timer in _pending_timers:
		_start_timer(float(timer.seconds), timer.callback, bool(timer.repeat))
	_updates.append_array(_pending_updates)
	_pending_sets.clear()
	_pending_events.clear()
	_pending_timers.clear()
	_pending_updates.clear()
	_overrides.clear()
	_staging = false
	return true


func close(preserve_replicated_state := false) -> void:
	if not _valid:
		return
	_valid = false
	for bridge in _input_bridges:
		bridge.close()
	_input_bridges.clear()
	for timer_id in _timers.keys():
		cancel_timer(timer_id)
	_updates.clear()
	_pending_updates.clear()
	for node in _owned.values():
		if is_instance_valid(node):
			node.queue_free()
	_owned.clear()
	_handles.clear()
	_reverse_handles.clear()
	_state.close(not preserve_replicated_state)
	_remote.close()
	_players.close()
	_invoke = Callable()
	_page_root = null
	_player = null
	_owner = null
	_clock_snapshot = Callable()


func restore_replicated_state() -> bool:
	return _valid and _state.restore_registrations()


func snapshot_replicated_state() -> void:
	if _valid:
		_state.snapshot_registrations()


func retire_for_replacement(replacement: VrwebDocumentHost) -> void:
	if _valid and replacement != null:
		_state.retire_except(replacement._state.ownership())
	close(true)


func query(selector: String):
	if not _allow_call() or not selector.begins_with("#"):
		return null
	var object = _targets.get(selector.trim_prefix("#"))
	return _handle_for(object) if object is Object and is_instance_valid(object) else null


func query_all(selector: String) -> Array:
	var one = query(selector)
	return [] if one == null else [one]


func create(type_name: String, properties: Dictionary = {}):
	if not _allow_call() or not CREATE_CLASSES.has(type_name) or _handles.size() >= MAX_HANDLES:
		return null
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_element(type_name,
			{}, {"source": "script", "script_id": script_id})):
		return null
	var object = ClassDB.instantiate(type_name)
	if not (object is Node):
		if object is Object and not (object is RefCounted):
			object.free()
		return null
	var node := object as Node
	var handle: Dictionary = _handle_for(node)
	if handle.is_empty():
		node.free()
		return null
	_owned[int(handle.id)] = node
	for property in properties:
		if not set_property(int(handle.id), str(property), properties[property]):
			_forget_owned(int(handle.id), true)
			return null
	if not _staging:
		_page_root.add_child(node)
	return handle


func get_property(handle_id: int, property: String):
	if not _allow_call():
		return null
	var object := _object(handle_id)
	if object == null or BLOCKED_PROPERTIES.has(property) or not _has_property(object, property):
		return null
	var key := "%d:%s" % [handle_id, property]
	var value = _overrides.get(key, object.get(property))
	return value if _portable(value) else null


func set_property(handle_id: int, property: String, value) -> bool:
	if not _allow_call() or not _portable(value) or var_to_bytes(value).size() > MAX_VALUE_BYTES:
		return false
	var object := _object(handle_id)
	if object == null or BLOCKED_PROPERTIES.has(property) or not _has_property(object, property) \
			or not _compatible_property_value(object, property, value):
		return false
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_property(
			object.get_class(), property, var_to_str(value),
			{"source": "script", "script_id": script_id})):
		return false
	if _staging:
		_pending_sets.append({"node": object, "property": property, "value": value})
		_overrides["%d:%s" % [handle_id, property]] = value
		return true
	return _apply_set(object, property, value)


func call_method(handle_id: int, method: String, arguments: Array = []):
	if not _allow_call() or not SAFE_METHODS.has(method) or arguments.size() > 8:
		return null
	var node := _object(handle_id) as Node
	if node == null or not node.has_method(method):
		return null
	if _staging:
		return null
	return node.callv(method, arguments)


func on_event(handle_id: int, event_name: String, callback: Callable, hint := "") -> bool:
	if not _allow_call() or not callback.is_valid():
		return false
	var node := _object(handle_id) as Node
	if node == null or event_name != "activate":
		return false
	if _staging:
		_pending_events.append({"node": node, "name": event_name, "callback": callback,
			"hint": str(hint)})
		return true
	return _connect_event(node, event_name, callback, str(hint))


func destroy(handle_id: int) -> bool:
	if not _allow_call() or not _owned.has(handle_id):
		return false
	_forget_owned(handle_id, false)
	return true


func set_timeout(seconds: float, callback: Callable) -> int:
	return _timer(seconds, callback, false)


func set_interval(seconds: float, callback: Callable) -> int:
	return _timer(seconds, callback, true)


func on_update(callback: Callable) -> bool:
	if not _allow_call() or not callback.is_valid() \
			or _updates.size() + _pending_updates.size() >= MAX_UPDATE_CALLBACKS:
		return false
	if _staging:
		_pending_updates.append(callback)
	else:
		_updates.append(callback)
	return true


func update(delta: float, clock: Dictionary) -> void:
	if not _valid or _staging or not _invoke.is_valid():
		return
	var event := {
		"delta": delta,
		"local_time": float(clock.get("local_time", 0.0)),
		"authority_time": float(clock.get("authority_time", 0.0)),
		"authority_ready": bool(clock.get("authority_ready", false)),
	}
	for callback in _updates.duplicate():
		if _valid:
			_invoke.call(callback, event)


func begin_invocation() -> void:
	# Лимит host calls относится к одному контролируемому входу в VM. Иначе корректный
	# per-frame update неизбежно исчерпал бы пожизненный счётчик.
	_calls = 0


func local_time() -> float:
	return float(_clock().get("local_time", 0.0)) if _allow_call() else 0.0


func authority_time() -> float:
	return float(_clock().get("authority_time", 0.0)) if _allow_call() else 0.0


func authority_clock_ready() -> bool:
	return bool(_clock().get("authority_ready", false)) if _allow_call() else false


func make_vector3(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, y, z) if _allow_call() else Vector3.ZERO


func make_color(r: float, g: float, b: float, a := 1.0) -> Color:
	return Color(r, g, b, a) if _allow_call() else Color.TRANSPARENT


func cancel_timer(timer_id: int) -> bool:
	if not _timers.has(timer_id):
		return false
	var timer: Timer = _timers[timer_id]
	_timers.erase(timer_id)
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
	return true


func resolve_asset(path: String) -> String:
	if not _allow_call() or path.to_utf8_buffer().size() > 4096:
		return ""
	return PageFetcher.resolve_url(path, _base_url)


func player_get(property: String):
	if not _allow_call() or not is_instance_valid(_player):
		return null
	if property == "position" and _player is Node3D:
		return (_player as Node3D).global_position
	if property == "flying" and _player.has_method("is_flying"):
		return _player.call("is_flying")
	return null


func player_set_position(position: Vector3) -> bool:
	if not _allow_call() or not is_instance_valid(_player) or not _player.has_method("teleport_to"):
		return false
	_player.call("teleport_to", position)
	return true


func feature_has(feature: String) -> bool:
	return _valid and bool(CAPABILITIES.get(feature, false))


func feature_require(feature: String) -> bool:
	var available := feature_has(feature)
	if not available:
		push_warning("script:%s: required capability unavailable: %s" % [script_id, feature])
	return available


func log_debug(message) -> void:
	_log("DEBUG", message)


func log_info(message) -> void:
	_log("INFO", message)


func log_warning(message) -> void:
	if _valid:
		push_warning("script:%s:%s: %s" % [script_id, script_hash.left(12),
			str(message).left(4096)])


func log_error(message) -> void:
	if _valid:
		push_error("script:%s:%s: %s" % [script_id, script_hash.left(12),
			str(message).left(4096)])


func _handle_for(object: Object) -> Dictionary:
	var instance_id := object.get_instance_id()
	var handle_id := int(_reverse_handles.get(instance_id, 0))
	if handle_id == 0:
		if _handles.size() >= MAX_HANDLES:
			return {}
		handle_id = _next_handle
		_next_handle += 1
		_handles[handle_id] = object
		_reverse_handles[instance_id] = handle_id
	return {
		"id": handle_id,
		"get": func(property: String): return get_property(handle_id, property),
		"set": func(property: String, value): return set_property(handle_id, property, value),
		"call": func(method: String, arguments: Array = []): return call_method(handle_id, method, arguments),
		"on": func(event_name: String, callback: Callable, hint := ""): return on_event(
			handle_id, event_name, callback, hint),
		"destroy": func(): return destroy(handle_id),
	}


func _object(handle_id: int) -> Object:
	var object = _handles.get(handle_id)
	return object as Object if object is Object and is_instance_valid(object) else null


func _allow_call() -> bool:
	if not _valid:
		return false
	_calls += 1
	return _calls <= MAX_HOST_CALLS


func _has_property(node: Object, property: String) -> bool:
	for info in node.get_property_list():
		if str(info.name) == property and int(info.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 \
				and int(info.usage) & PROPERTY_USAGE_READ_ONLY == 0:
			return true
	return false


func _compatible_property_value(node: Object, property: String, value) -> bool:
	var expected := TYPE_NIL
	for info in node.get_property_list():
		if str(info.name) == property:
			expected = int(info.type)
			break
	var actual := typeof(value)
	if expected == actual:
		return true
	if expected == TYPE_FLOAT and actual == TYPE_INT:
		return true
	if expected == TYPE_STRING_NAME and actual == TYPE_STRING:
		return true
	if expected == TYPE_NODE_PATH and actual in [TYPE_STRING, TYPE_STRING_NAME]:
		return true
	return false


func _apply_set(node: Object, property: String, value) -> bool:
	if not is_instance_valid(node) or not _compatible_property_value(node, property, value):
		return false
	node.set(property, value)
	return true


func _clock() -> Dictionary:
	if _clock_snapshot.is_valid():
		var value = _clock_snapshot.call()
		if value is Dictionary:
			return value
	return {"local_time": 0.0, "authority_time": 0.0, "authority_ready": false}


func _forget_owned(handle_id: int, immediate: bool) -> void:
	var node: Node = _owned.get(handle_id)
	_owned.erase(handle_id)
	_handles.erase(handle_id)
	if is_instance_valid(node):
		_reverse_handles.erase(node.get_instance_id())
		if immediate and not node.is_inside_tree():
			node.free()
		else:
			node.queue_free()


func _connect_event(node: Node, _event_name: String, callback: Callable, hint: String) -> bool:
	var bridge := VrwebScriptInputBridge.new()
	bridge.setup(node, func(event):
		if _valid and _invoke.is_valid():
			_invoke.call(callback, event), hint)
	_input_bridges.append(bridge)
	return true


func _timer(seconds: float, callback: Callable, repeat: bool) -> int:
	if not _allow_call() or seconds <= 0.0 or not callback.is_valid() \
			or _timers.size() + _pending_timers.size() >= MAX_TIMERS:
		return 0
	if _staging:
		_pending_timers.append({"seconds": seconds, "callback": callback, "repeat": repeat})
		return -_pending_timers.size()
	return _start_timer(seconds, callback, repeat)


func _start_timer(seconds: float, callback: Callable, repeat: bool) -> int:
	var timer_id := _next_timer
	_next_timer += 1
	var timer := Timer.new()
	timer.one_shot = not repeat
	timer.wait_time = seconds
	_timers[timer_id] = timer
	_owner.add_child(timer)
	timer.timeout.connect(func():
		if _valid and _timers.has(timer_id) and _invoke.is_valid():
			_invoke.call(callback, {})
		if not repeat:
			cancel_timer(timer_id))
	timer.start()
	return timer_id


func _session_set(key: String, value) -> bool:
	if not _allow_call() or key.to_utf8_buffer().size() > 256 or not _portable(value):
		return false
	var next := session.duplicate(true)
	next[key] = value
	if var_to_bytes(next).size() > MAX_VALUE_BYTES:
		return false
	session = next
	return true


func _log(level: String, message) -> void:
	if _valid:
		print("script:%s:%s %s: %s" % [script_id, script_hash.left(12), level,
			str(message).left(4096)])


static func _portable(value, depth := 0) -> bool:
	if depth > 8:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_VECTOR2, TYPE_VECTOR2I, \
				TYPE_STRING_NAME, TYPE_NODE_PATH, \
				TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_COLOR, \
				TYPE_QUATERNION, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, \
				TYPE_PACKED_BYTE_ARRAY:
			return true
		TYPE_ARRAY:
			if value.size() > 256:
				return false
			for item in value:
				if not _portable(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			if value.size() > 256:
				return false
			for key in value:
				if typeof(key) != TYPE_STRING or not _portable(value[key], depth + 1):
					return false
			return true
	return false
