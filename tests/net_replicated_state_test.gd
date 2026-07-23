extends Node

## End-to-end Replicated State по реальному WebRTC mesh. Процессы запускает
## tests/run_net_replicated_state_test.py в порядке leader → actor → late.
## Проверяет late join, команды двух клиентов, конфликт, сходимость и смену authority.

const SCHEMA := "test.replicated.counter"
const VERSION := 1
const OBJECT := "counter"

var _role := "leader"
var _states: Array[Dictionary] = []
var _became_authority := false
var _p2p_count := 0
var _peer_left_count := 0
var _acks := {} # request_id -> {accepted, code, revision}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if not args.is_empty() else "leader"
	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _role
	Settings.online_enabled = true

	NetworkManager.register_replicated_schema(SCHEMA, {
		"version": VERSION,
		"fields": {
			"value": {"type": "int", "default": -1, "min": -1, "max": 1000},
			"blob": {"type": "string", "default": "", "max_bytes": 4096},
		},
		"default_write_rule": {"rank": {"op": "lte", "value": NetworkManager.DEFAULT_RANK}},
		"commands": {"set": {"reducer": Callable(self, "_reduce_set")}},
	})
	NetworkManager.replicated_state_received.connect(_on_state)
	NetworkManager.replicated_command_result.connect(func(request_id, accepted, code, revision):
		_acks[request_id] = {"accepted": accepted, "code": code, "revision": revision}
		_log("ACK request=%d accepted=%s code=%s revision=%d" % [request_id, accepted, code, revision]))
	NetworkManager.p2p_peer_connected.connect(func(id):
		_p2p_count += 1
		_log("P2P %d" % id))
	NetworkManager.peer_left.connect(func(id):
		_peer_left_count += 1
		_log("PEER_LEFT %d" % id))
	NetworkManager.authority_changed.connect(func(id, is_me):
		_log("AUTHORITY id=%d me=%s" % [id, is_me])
		_ensure_object()
		if is_me and _role == "leader": _ensure_bulk()
		if is_me and _role != "leader":
			_became_authority = true)

	# Декларация до и после setup mesh: reset_session очищает объекты комнаты, schema остаётся.
	_ensure_object()
	NetworkManager.connect_to_server()
	NetworkManager.join_room("replicated-state-reconnect" if _role.begins_with("rejoin_")
			else "replicated-state-e2e")

	match _role:
		"leader": await _run_leader()
		"actor": await _run_actor()
		"late": await _run_late()
		"rejoin_stayer": await _run_rejoin_stayer()
		"rejoin_first": await _run_rejoin_first()
		"rejoin_second": await _run_rejoin_second()
		_: _finish(false, "unknown role")


func _ensure_object() -> void:
	NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": -1})


func _ensure_bulk() -> void:
	for i in range(24):
		NetworkManager.register_replicated_object("bulk-%d" % i, SCHEMA,
				{"value": i, "blob": "b".repeat(2048)})


func _reduce_set(_state: Dictionary, args: Dictionary, _context: Dictionary) -> Dictionary:
	if typeof(args.get("value")) != TYPE_INT:
		return {}
	return {"state": {"value": int(args["value"])}}


func _on_state(object_id: String, schema_id: String, state: Dictionary,
		_changed: Dictionary, revision: int) -> void:
	if object_id != OBJECT or schema_id != SCHEMA:
		return
	_states.append({"value": int(state.get("value", -999)), "revision": revision})
	_log("STATE value=%d revision=%d" % [state.get("value", -999), revision])


func _command_set(value: int) -> int:
	_log("COMMAND set=%d" % value)
	return NetworkManager.request_replicated_command(OBJECT, SCHEMA, VERSION, "set", {"value": value})


func _run_leader() -> void:
	# >32 KiB суммарно: late join обязан пройти через несколько snapshot chunks.
	_ensure_bulk()
	if not await _wait_for(func(): return NetworkManager.has_authority() and _p2p_count >= 1, 10.0):
		_finish(false, "leader did not get actor p2p")
		return
	_command_set(10)
	if not await _wait_value(10, 4.0):
		_finish(false, "leader command did not commit")
		return
	# Actor шлёт 20, затем почти одновременно оба клиента шлют конфликтующие 31/32.
	if not await _wait_value(20, 6.0):
		_finish(false, "actor command did not reach leader")
		return
	await get_tree().create_timer(1.0).timeout
	_command_set(31)
	await get_tree().create_timer(2.0).timeout
	_log("INTENTIONAL LEADER EXIT")
	get_tree().quit(0)


func _run_actor() -> void:
	if not await _wait_for(func(): return _p2p_count >= 1 and not NetworkManager.has_authority(), 10.0):
		_finish(false, "actor did not connect as follower")
		return
	if not await _wait_value(10, 5.0):
		_finish(false, "actor missed leader state")
		return
	# Явные отказы: неизвестная команда приходит ACK, oversized отсекается ещё до RPC.
	var unknown := NetworkManager.request_replicated_command(OBJECT, SCHEMA, VERSION, "missing", {})
	if not await _wait_ack(unknown, false, "unknown_command", 3.0):
		_finish(false, "missing command ACK is wrong")
		return
	var oversized := NetworkManager.request_replicated_command(OBJECT, SCHEMA, VERSION, "set",
			{"value": 20, "padding": "x".repeat(NetworkManager.MAX_REPLICATED_COMMAND_BYTES)})
	if not await _wait_ack(oversized, false, "too_large", 3.0):
		_finish(false, "oversized command ACK is wrong")
		return
	var set20 := _command_set(20)
	if not await _wait_ack(set20, true, "accepted", 3.0):
		_finish(false, "accepted command ACK is missing")
		return
	if not await _wait_value(20, 4.0):
		_finish(false, "actor command did not converge")
		return
	await get_tree().create_timer(1.0).timeout
	_command_set(32)
	# После выхода leader actor — следующий старейший и обязан продолжить canonical stream.
	if not await _wait_for(func(): return _became_authority and NetworkManager.has_authority(), 8.0):
		_finish(false, "authority handoff did not happen")
		return
	_command_set(99)
	if not await _wait_value(99, 4.0):
		_finish(false, "new authority could not commit")
		return
	await get_tree().create_timer(2.0).timeout # дать late получить delta
	_finish(true, "commands+conflict+handoff")


func _run_late() -> void:
	if not await _wait_for(func(): return _p2p_count >= 1, 10.0):
		_finish(false, "late did not connect to mesh")
		return
	# Late ничего не командует: первое не-default состояние может прийти только snapshot/delta.
	if not await _wait_for(func(): return _saw_non_default(), 5.0):
		_finish(false, "late join did not restore canonical state")
		return
	if int(NetworkManager.replicated_metrics().get("snapshot_last_chunks", 0)) < 2:
		_finish(false, "late snapshot was not chunked")
		return
	if not await _wait_value(99, 12.0):
		_finish(false, "late did not follow authority handoff")
		return
	_finish(true, "late-join+handoff delta")


func _run_rejoin_stayer() -> void:
	if not await _wait_for(func(): return _p2p_count >= 1, 10.0):
		_finish(false, "rejoin first did not connect")
		return
	_command_set(7)
	if not await _wait_value(7, 3.0):
		_finish(false, "could not establish pre-disconnect state")
		return
	if not await _wait_for(func(): return _peer_left_count >= 1, 8.0):
		_finish(false, "first rejoin client did not leave")
		return
	_command_set(8) # изменение, которое вернувшийся клиент мог получить только snapshot
	if not await _wait_for(func(): return _p2p_count >= 2, 10.0):
		_finish(false, "second rejoin client did not connect")
		return
	if not await _wait_value(9, 6.0):
		_finish(false, "rejoined client command did not commit")
		return
	_finish(true, "disconnect+snapshot+rejoin command")


func _run_rejoin_first() -> void:
	if not await _wait_for(func(): return _p2p_count >= 1, 10.0) or not await _wait_value(7, 5.0):
		_finish(false, "first session missed state 7")
		return
	_log("INTENTIONAL REJOIN DISCONNECT")
	get_tree().quit(0)


func _run_rejoin_second() -> void:
	if not await _wait_for(func(): return _p2p_count >= 1, 10.0):
		_finish(false, "second session did not reconnect")
		return
	if not await _wait_value(8, 5.0):
		_finish(false, "reconnect snapshot missed offline state 8")
		return
	_command_set(9)
	if not await _wait_value(9, 4.0):
		_finish(false, "reconnect command did not converge")
		return
	_finish(true, "restored 8 then committed 9")


func _saw_non_default() -> bool:
	for state in _states:
		if int(state["value"]) >= 10:
			return true
	return false


func _wait_value(value: int, timeout: float) -> bool:
	return await _wait_for(func():
		var state := NetworkManager.replicated_state(OBJECT, SCHEMA)
		return int(state.get("value", -999)) == value, timeout)


func _wait_ack(request_id: int, accepted: bool, code: String, timeout: float) -> bool:
	return await _wait_for(func():
		if not _acks.has(request_id): return false
		var ack: Dictionary = _acks[request_id]
		return bool(ack["accepted"]) == accepted and str(ack["code"]) == code, timeout)


func _wait_for(predicate: Callable, timeout: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout:
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05
	return false


func _finish(ok: bool, detail: String) -> void:
	_log("RESULT pass=%s %s final=%s rev=%d" % [ok, detail,
			NetworkManager.replicated_state(OBJECT, SCHEMA),
			NetworkManager.replicated_revision(OBJECT, SCHEMA)])
	_log("METRICS %s" % NetworkManager.replicated_metrics())
	get_tree().quit(0 if ok else 1)


func _log(message: String) -> void:
	print("[RS-E2E %s t=%d] %s" % [_role, Time.get_ticks_msec(), message])
