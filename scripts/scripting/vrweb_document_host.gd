class_name VrwebDocumentHost
extends RefCounted

## Narrow, engine-independent capability surface exposed to one Luau script.

const MAX_HANDLES := 256
const MAX_TIMERS := 64
const MAX_UPDATE_CALLBACKS := 8
const MAX_HOST_CALLS := 10_000
const MAX_VALUE_BYTES := 64 * 1024
const ASSETS_SCRIPT := preload("res://scripts/scripting/vrweb_script_assets.gd")
const RENDER_SCRIPT := preload("res://scripts/scripting/vrweb_script_render.gd")
const CREATE_CLASSES := {
	"Node3D": true, "MeshInstance3D": true, "StaticBody3D": true, "Area3D": true,
	"CollisionShape3D": true, "Label3D": true, "OmniLight3D": true,
	"DirectionalLight3D": true, "SpotLight3D": true, "CSGBox3D": true,
	"CSGSphere3D": true,
}
const SAFE_METHODS := {"show": true, "hide": true, "play": true, "stop": true}
## Методы видео-плеера (capability vrweb/video/1) поверх общего SAFE_METHODS: доступны только
## на handle VrwebVideoPlayer. Значение — список ожидаемых типов аргументов (int сходит за
## float). set_source дополнительно резолвит и проверяет URL (_allowed_media_url).
const VIDEO_PLAYER_METHODS := {
	"play": [], "pause": [], "toggle": [],
	"seek": [TYPE_FLOAT], "set_volume": [TYPE_FLOAT],
	"set_source": [TYPE_STRING], "source": [],
	"position": [], "duration": [],
	"is_playing": [], "is_buffering": [], "last_error": [],
}
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
	"vrweb/assets/2": true,
	"vrweb/clock/1": true,
	"vrweb/log/1": true,
	"vrweb/render-shaders/1": true,
	"vrweb/video/1": true,
	"vrweb/scene-objects/1": true,
	"vrweb/aim/1": true,
	"vrweb/files/1": true,
	"vrweb/grabbable/1": true,
}

## Методы grabbable-предмета (capability vrweb/grabbable/1) на handle <VRWebGrabbable>:
## имя -> ожидаемые типы аргументов. «drop» схемы называется release — имя `drop` занято
## одноимённым сигналом узла.
const GRABBABLE_METHODS := {
	"release": [], "holder": [], "held_hand": [],
	"set_enabled": [TYPE_BOOL], "is_enabled": [],
}

## Максимум байт файла, который files.pick вернёт скрипту инлайном (bytes); файл целиком в
## любом случае уезжает в BlobStore и доступен по vrwebblob:// URL.
const MAX_PICK_INLINE_BYTES := 2 * 1024 * 1024
const MAX_PICK_FILE_BYTES := 32 * 1024 * 1024

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
var _signal_connections: Array[Dictionary] = []
var _timers: Dictionary = {}
var _updates: Array[Callable] = []
var _next_timer := 1
var _state := VrwebScriptState.new()
var _remote := VrwebScriptRemote.new()
var _players := VrwebScriptPlayers.new()
var _scene := VrwebScriptScene.new()
## Провайдер выбора файла (инжектирует владелец runtime; main показывает OS-диалог):
## file_picker.call(kind: String, done: Callable(ok, name, bytes)).
var file_picker: Callable = Callable()
var _pick_pending := false
var _assets = ASSETS_SCRIPT.new()
var _render = RENDER_SCRIPT.new()
var _pending_resource_applies: Array[Dictionary] = []
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
	_scene.setup(script_id, _invoke)
	_assets.setup(script_id, _base_url, _owner, _invoke, _apply_asset, _policy)
	_render.setup(script_id, _apply_runtime_resource, _policy)


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
		"scene": _scene.api(),
		"files": {"pick": files_pick},
		"assets": _assets.api(),
		"render": _render.api(),
		"clock": {"local_time": local_time, "authority_time": authority_time,
			"authority_ready": authority_clock_ready, "set_timeout": set_timeout,
			"set_interval": set_interval, "cancel": cancel_timer},
		"on_update": on_update,
		"values": {"vector3": make_vector3, "color": make_color},
		"player": {"get": player_get, "set_position": player_set_position, "aim": player_aim},
		"log": {"debug": log_debug, "info": log_info, "warning": log_warning,
			"error": log_error},
		"features": {"has": feature_has, "require": feature_require},
	}


func commit() -> bool:
	if not _valid or not is_instance_valid(_page_root):
		return false
	if not _state.commit():
		return false
	if not _remote.commit() or not _players.commit() or not _assets.commit():
		return false
	if not _scene.commit():
		return false
	for handle_id in _owned:
		var node: Node = _owned[handle_id]
		if is_instance_valid(node) and node.get_parent() == null:
			_page_root.add_child(node)
	for operation in _pending_sets:
		_apply_set(operation.node, operation.property, operation.value)
	for operation in _pending_resource_applies:
		_apply_set(operation.object, operation.property, operation.value)
	for event in _pending_events:
		_connect_event(event.node, event.name, event.callback, event.hint)
	for timer in _pending_timers:
		_start_timer(float(timer.seconds), timer.callback, bool(timer.repeat))
	_updates.append_array(_pending_updates)
	_pending_sets.clear()
	_pending_resource_applies.clear()
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
	for record in _signal_connections:
		var object := record.get("object") as Object
		var signal_name := StringName(str(record.get("signal", "")))
		var callable: Callable = record.get("callable", Callable())
		if is_instance_valid(object) and object.is_connected(signal_name, callable):
			object.disconnect(signal_name, callable)
	_signal_connections.clear()
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
	_scene.close()
	_assets.close()
	_render.close()
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


func call_method(handle_id: int, method: String, arguments = []):
	# Пустая Luau-таблица неотличима от массива и может приехать пустым Dictionary —
	# принимаем её (и nil) как «без аргументов»; непустой словарь аргументами не считается.
	var args: Array = []
	if arguments is Array:
		args = arguments
	elif arguments != null and not (arguments is Dictionary and (arguments as Dictionary).is_empty()):
		return null
	if not _allow_call() or args.size() > 8:
		return null
	var node := _object(handle_id) as Node
	if node == null or not node.has_method(method):
		return null
	if node is VrwebVideoPlayer and VIDEO_PLAYER_METHODS.has(method):
		return null if _staging else _call_video_method(node as VrwebVideoPlayer, method, args)
	if node is Grabbable and GRABBABLE_METHODS.has(method):
		return null if _staging else _call_typed_method(node, GRABBABLE_METHODS, method, args)
	if not SAFE_METHODS.has(method):
		return null
	if _staging:
		return null
	return node.callv(method, args)


## Типизированный вызов метода по объявленной сигнатуре (grabbable и будущие поверхности):
## число и типы аргументов проверяются до callv, int сходит за float.
func _call_typed_method(node: Node, table: Dictionary, method: String, arguments: Array):
	var expected: Array = table[method]
	if arguments.size() != expected.size():
		return null
	var args := []
	for index in expected.size():
		var value = arguments[index]
		if int(expected[index]) == TYPE_FLOAT and typeof(value) == TYPE_INT:
			value = float(value)
		if typeof(value) != int(expected[index]):
			return null
		args.append(value)
	return node.callv(method, args)


## Транспорт видео-плеера из скрипта (vrweb/video/1). Аргументы проверяются по объявленной
## сигнатуре VIDEO_PLAYER_METHODS (не полагаемся на строгую типизацию callv). На synced-плеере
## play/pause/seek эмитят transport_changed и уходят в стандартную синхронизацию как обычный
## клик игрока; на sync="none" — чисто локальны.
func _call_video_method(player: VrwebVideoPlayer, method: String, arguments: Array):
	var expected: Array = VIDEO_PLAYER_METHODS[method]
	if arguments.size() != expected.size():
		return null
	var args := []
	for index in expected.size():
		var value = arguments[index]
		if int(expected[index]) == TYPE_FLOAT and typeof(value) == TYPE_INT:
			value = float(value)
		if typeof(value) != int(expected[index]):
			return null
		args.append(value)
	if method == "set_source":
		# URL резолвится относительно страницы и проходит те же схемные ограничения, что
		# document.assets: локальные схемы доступны только локальному документу.
		var url := _allowed_media_url(str(args[0]))
		return player.set_source(url) if url != "" else false
	return player.callv(method, args)


## Разрешённый URL медиа-источника для set_source (та же модель, что VrwebScriptAssets):
## http(s) — всем; vrweblocal://vrwebresource:// — только документу той же локальной схемы.
func _allowed_media_url(path: String) -> String:
	if path.to_utf8_buffer().size() > 4096:
		return ""
	var url := PageFetcher.resolve_url(path, _base_url)
	var allowed := url.begins_with("http://") or url.begins_with("https://")
	if url.begins_with(PageFetcher.LOCAL_SCHEME):
		allowed = _base_url.begins_with(PageFetcher.LOCAL_SCHEME)
	elif url.begins_with(PageFetcher.RESOURCE_SCHEME):
		allowed = _base_url.begins_with(PageFetcher.RESOURCE_SCHEME)
	if not allowed:
		return ""
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_operation(
			"script_video_source", {"url": url},
			{"source": "script", "script_id": script_id})):
		return ""
	return url


func on_event(handle_id: int, event_name: String, callback: Callable, hint := "") -> bool:
	if not _allow_call() or not callback.is_valid():
		return false
	var object := _object(handle_id)
	if object == null or (event_name == "activate" and not (object is Node)) \
			or (event_name != "activate" and not object.has_signal(event_name)):
		return false
	if _staging:
		_pending_events.append({"node": object, "name": event_name, "callback": callback,
			"hint": str(hint)})
		return true
	return _connect_event(object, event_name, callback, str(hint))


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
	_render.update_clock(clock)
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


## Прицел игрока (capability vrweb/aim/1): {hit, position, normal, distance, target?}.
## target — html id узла под лучом, если он адресуем скриптом (поднимаемся к предкам до
## первого известного target). Poll-модель: скрипт зовёт из on_update/по use — handles на
## каждый кадр не создаются (бюджет 256 handles не расходуется).
func player_aim() -> Dictionary:
	if not _allow_call() or not is_instance_valid(_player) or not _player.has_method("aim_info"):
		return {"hit": false}
	var info: Dictionary = _player.call("aim_info")
	var result := {
		"hit": bool(info.get("hit", false)),
		"origin": info.get("origin", Vector3.ZERO),
		"direction": info.get("direction", Vector3.FORWARD),
		"position": info.get("position", Vector3.ZERO),
		"normal": info.get("normal", Vector3.UP),
		"distance": float(info.get("distance", 0.0)),
	}
	var collider = info.get("collider")
	if collider is Node:
		var target_id := _target_id_of(collider as Node)
		if target_id != "":
			result["target"] = target_id
	return result


## html id адресуемого предка коллайдера (или ""): коллайдер часто — служебное тело внутри
## целевого узла (StaticBody3D под MeshInstance3D), поэтому ищем вверх по дереву.
func _target_id_of(node: Node) -> String:
	var reverse := {}
	for key in _targets:
		var object = _targets[key]
		if object is Node and is_instance_valid(object):
			reverse[(object as Node).get_instance_id()] = str(key)
	var current: Node = node
	var guard := 0
	while current != null and guard < 32:
		if reverse.has(current.get_instance_id()):
			return str(reverse[current.get_instance_id()])
		current = current.get_parent()
		guard += 1
	return ""


## Выбор файла пользователем (capability vrweb/files/1): OS-диалог показывает владелец
## runtime (провайдер file_picker), сам выбор — явное согласие пользователя (модель
## <input type="file">). callback: {ok, name, size, url, bytes?}; url — vrwebblob:// адрес
## (файл уезжает в BlobStore и готов для vrweb-node/realtime-ресурсов), bytes — инлайн для
## небольших файлов (decode в скрипте).
func files_pick(kind: String, callback: Callable) -> bool:
	if not _allow_call() or not callback.is_valid() or _pick_pending \
			or not file_picker.is_valid() or _staging:
		return false
	_pick_pending = true
	file_picker.call(str(kind), func(ok: bool, name: String, bytes: PackedByteArray) -> void:
		_pick_pending = false
		if not _valid or not _invoke.is_valid():
			return
		if not ok or bytes.size() == 0 or bytes.size() > MAX_PICK_FILE_BYTES:
			_invoke.call(callback, {"ok": false, "name": str(name), "size": bytes.size(),
				"url": ""})
			return
		var hex := BlobProtocol.hash_bytes(bytes)
		if not BlobStore.has_hex(hex):
			BlobStore.ingest(hex, bytes)
		var event := {"ok": true, "name": str(name), "size": bytes.size(),
			"url": BlobProtocol.url_of(hex)}
		if bytes.size() <= MAX_PICK_INLINE_BYTES:
			event["bytes"] = bytes
		_invoke.call(callback, event))
	return true


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
		"call": func(method: String, arguments = []): return call_method(handle_id, method, arguments),
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
	var expected_class := ""
	for info in node.get_property_list():
		if str(info.name) == property:
			expected = int(info.type)
			expected_class = str(info.get("class_name", ""))
			break
	var actual := typeof(value)
	if expected == actual:
		if expected == TYPE_OBJECT and value is Object and not expected_class.is_empty():
			# Godot 4.6 exposes union resource constraints as a comma-separated class_name
			# (for example BaseMaterial3D,ShaderMaterial on material_override).
			for allowed_class in expected_class.split(",", false):
				if (value as Object).is_class(allowed_class.strip_edges()):
					return true
			return false
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


func _apply_asset(resource_id: int, target: Dictionary, property: String) -> bool:
	if not _allow_call() or not target.has("id") or BLOCKED_PROPERTIES.has(property):
		return false
	var object := _object(int(target.get("id", 0)))
	var value: Resource = _assets.resource(resource_id)
	if object == null or value == null or not _has_property(object, property) \
			or not _compatible_property_value(object, property, value):
		return false
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_property(
			object.get_class(), property, "OpaqueResource",
			{"source": "script", "script_id": script_id})):
		return false
	return _apply_set(object, property, value)


func _apply_runtime_resource(value: Resource, target: Dictionary, property: String) -> bool:
	if not _allow_call() or value == null or not target.has("id") \
			or BLOCKED_PROPERTIES.has(property):
		return false
	var object := _object(int(target.get("id", 0)))
	if object == null or not _has_property(object, property) \
			or not _compatible_property_value(object, property, value):
		return false
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_property(
			object.get_class(), property, "OpaqueRuntimeResource",
			{"source": "script", "script_id": script_id})):
		return false
	if _staging:
		_pending_resource_applies.append({"object": object, "property": property, "value": value})
		return true
	return _apply_set(object, property, value)


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


func _connect_event(object: Object, event_name: String, callback: Callable, hint: String) -> bool:
	if event_name == "activate":
		var bridge := VrwebScriptInputBridge.new()
		bridge.setup(object as Node, func(event):
			if _valid and _invoke.is_valid():
				_invoke.call(callback, event), hint)
		_input_bridges.append(bridge)
		return true
	var info := _signal_info(object, event_name)
	if info.is_empty():
		return false
	var arg_names: Array = []
	for arg in info.get("args", []):
		arg_names.append(str(arg.get("name", "")))
	var dispatch := func(values: Array): _dispatch_signal(callback, event_name, arg_names, values)
	var connection: Callable
	match arg_names.size():
		0: connection = func(): dispatch.call([])
		1: connection = func(a): dispatch.call([a])
		2: connection = func(a, b): dispatch.call([a, b])
		3: connection = func(a, b, c): dispatch.call([a, b, c])
		4: connection = func(a, b, c, d): dispatch.call([a, b, c, d])
		_: return false
	object.connect(event_name, connection)
	_signal_connections.append({"object": object, "signal": event_name, "callable": connection})
	return true


func _signal_info(object: Object, event_name: String) -> Dictionary:
	for info in object.get_signal_list():
		if str(info.get("name", "")) == event_name:
			return info
	return {}


func _dispatch_signal(callback: Callable, event_name: String, names: Array, values: Array) -> void:
	if not _valid or not _invoke.is_valid():
		return
	var event := {"type": event_name, "args": []}
	for index in values.size():
		var value = _portable_signal_value(values[index])
		(event.args as Array).append(value)
		if index < names.size() and str(names[index]) != "":
			event[str(names[index])] = value
	_invoke.call(callback, event)


func _portable_signal_value(value):
	if _portable(value):
		return value
	if value is Object and is_instance_valid(value) and _reverse_handles.has(value.get_instance_id()):
		return _handle_for(value)
	return null


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
