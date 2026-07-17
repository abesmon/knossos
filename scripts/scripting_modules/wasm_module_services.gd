class_name WasmModuleServices
extends RefCounted

const MAX_EVENTS := 256
const MAX_TIMERS := 64
const MAX_STATE_KEYS := 256
const MAX_LOG_BYTES := 4096
const MAX_TIMER_MS := 60 * 60 * 1000

var _module_id: String
var _assets: Dictionary
var _features: Dictionary = {}
var _state: Dictionary = {}
var _subscriptions: Dictionary = {}
var _subscription_seq := 1
var _timers: Dictionary = {}
var _timer_seq := 1
var _input_kinds: Dictionary = {}
var _events: Array[Dictionary] = []
var _conformance_trace: Array[String] = []
var _dropped_events := 0
var _closed := false


func _init(module_id: String, module: Dictionary, capabilities: Array[String],
		shared_state: Dictionary = {}) -> void:
	_module_id = module_id
	_state = shared_state
	_assets = (module.get("manifest", {}) as Dictionary).get("assets", {}).duplicate(true)
	for capability in capabilities:
		_features[capability] = true


func wasm_host_call(operation: String, id: int, payload: PackedByteArray,
		_nested: Array) -> Variant:
	if _closed: return "instance_stopped"
	if _conformance_trace.size() < MAX_EVENTS:
		_conformance_trace.append(operation)
	match operation:
		"features.has": return _features.has(_utf8(payload))
		"assets.lookup": return _asset_lookup(_utf8(payload))
		"timers.start": return _timer_start(payload)
		"timers.cancel":
			_timers.erase(id)
			return null
		"input.enable": return _input_enable(payload)
		"state.read": return _state_read(payload)
		"state.command": return _state_command(payload)
		"state.subscribe": return _state_subscribe(payload)
		"state.unsubscribe":
			_subscriptions.erase(id)
			return null
		"log.write": return _log_write(payload)
	return "unknown_host_operation"


func poll(now_ms: int = Time.get_ticks_msec()) -> void:
	if _closed: return
	for timer_id in _timers.keys().duplicate():
		var timer: Dictionary = _timers[timer_id]
		if now_ms < int(timer.due): continue
		_enqueue({"kind": "timer", "timer": int(timer_id)})
		if bool(timer.repeat):
			timer.due = now_ms + int(timer.delay)
		else:
			_timers.erase(timer_id)


func enqueue_input(kind: String, value: Dictionary) -> bool:
	if _closed or not _input_kinds.has(kind): return false
	var encoded := WasmValueCodec.encode(value)
	if not bool(encoded.ok): return false
	_enqueue({"kind": "input", "input": kind, "value": encoded.value})
	return true


func drain_events(limit: int = MAX_EVENTS) -> Array[Dictionary]:
	var count := mini(maxi(limit, 0), _events.size())
	var result: Array[Dictionary] = []
	for _index in count:
		result.append(_events.pop_front())
	return result


func dropped_event_count() -> int:
	return _dropped_events


func conformance_trace() -> Array[String]:
	return _conformance_trace.duplicate()


func close() -> void:
	_closed = true
	_timers.clear()
	_subscriptions.clear()
	_input_kinds.clear()
	_events.clear()


func _asset_lookup(name: String) -> Variant:
	if not _assets.has(name): return "asset_not_found"
	var spec: Dictionary = _assets[name]
	return JSON.stringify({"uri": "vrweb-asset://%s/%s" % [_module_id, name],
		"type": str(spec.get("type", ""))}).to_utf8_buffer()


func _timer_start(payload: PackedByteArray) -> Variant:
	if _timers.size() >= MAX_TIMERS: return "timer_quota"
	var delay: int
	var repeat := false
	if payload.size() == 5:
		delay = int(payload.decode_u32(0))
		repeat = payload[4] != 0
	else:
		var request: Variant = _json_object(payload)
		if request is String: return request
		delay = int(request.get("delay_ms", 0))
		repeat = bool(request.get("repeat", false))
	if delay < 1 or delay > MAX_TIMER_MS: return "invalid_timer_delay"
	var timer_id := _timer_seq
	_timer_seq += 1
	_timers[timer_id] = {"due": Time.get_ticks_msec() + delay, "delay": delay,
		"repeat": repeat}
	return timer_id


func _input_enable(payload: PackedByteArray) -> Variant:
	var kind: String
	var enabled: bool
	if payload.size() >= 2 and payload[0] <= 1:
		enabled = payload[0] != 0
		kind = payload.slice(1).get_string_from_utf8()
	else:
		var request: Variant = _json_object(payload)
		if request is String: return request
		kind = str(request.get("kind", ""))
		enabled = bool(request.get("enabled", false))
	if kind not in ["activate", "hover", "axis", "text"]: return "input_kind_forbidden"
	if enabled:
		_input_kinds[kind] = true
	else:
		_input_kinds.erase(kind)
	return PackedByteArray()


func _state_read(payload: PackedByteArray) -> Variant:
	var key := _utf8(payload)
	if key.is_empty(): return "state_key_invalid"
	return JSON.stringify(_state.get(key, null)).to_utf8_buffer()


func _state_command(payload: PackedByteArray) -> Variant:
	var request: Variant = _json_object(payload)
	if request is String: return request
	var key := str(request.get("key", ""))
	var command := str(request.get("command", ""))
	if key.is_empty() or (not _state.has(key) and _state.size() >= MAX_STATE_KEYS):
		return "state_key_invalid"
	var value: Variant
	match command:
		"set": value = request.get("value")
		"toggle": value = not bool(_state.get(key, false))
		_: return "state_command_unknown"
	var checked := WasmValueCodec.encode(value)
	if not bool(checked.ok): return str(checked.error)
	_state[key] = value
	for subscription in _subscriptions:
		if str(_subscriptions[subscription]) == key:
			_enqueue({"kind": "state", "subscription": int(subscription), "key": key,
				"value": checked.value})
	return PackedByteArray()


func _state_subscribe(payload: PackedByteArray) -> Variant:
	var key := _utf8(payload)
	if key.is_empty(): return "state_key_invalid"
	var subscription := _subscription_seq
	_subscription_seq += 1
	_subscriptions[subscription] = key
	return subscription


func _log_write(payload: PackedByteArray) -> Variant:
	if payload.size() > MAX_LOG_BYTES: return "log_too_large"
	var request: Variant = _json_object(payload)
	if request is String: return request
	var level := str(request.get("level", "info"))
	var message := str(request.get("message", ""))
	if message.to_utf8_buffer().size() > MAX_LOG_BYTES: return "log_too_large"
	var tree := Engine.get_main_loop() as SceneTree
	var logger := tree.root.get_node_or_null("Log") if tree != null else null
	if logger == null: return "log_unavailable"
	match level:
		"info": logger.call("info", "wasm/%s" % _module_id, message)
		"warn": logger.call("warn", "wasm/%s" % _module_id, message)
		"error": logger.call("err", "wasm/%s" % _module_id, message)
		_: return "log_level_invalid"
	return PackedByteArray()


func _json_object(payload: PackedByteArray) -> Variant:
	if payload.size() > WasmValueCodec.MAX_BYTE_BUFFER: return "wire_too_large"
	var json := JSON.new()
	if json.parse(_utf8(payload)) != OK or not (json.data is Dictionary):
		return "wire_malformed_json"
	return json.data


func _utf8(payload: PackedByteArray) -> String:
	if payload.size() > WasmValueCodec.MAX_BYTE_BUFFER: return ""
	if not WasmValueCodec.is_valid_utf8(payload): return ""
	return payload.get_string_from_utf8()


func _enqueue(event: Dictionary) -> void:
	if _events.size() >= MAX_EVENTS:
		_dropped_events += 1
		return
	_events.append(event)
