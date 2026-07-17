extends Node

## Two-process WebRTC test for the normative WASM module descriptor gate. Both peers load identity
## from the built JavaScript .vrmod; the mismatch scenario changes only the follower hash.

const SCHEMA := "test.wasm.identity.counter"
const OBJECT := "counter"

var _scenario := "compatible"
var _role := "leader"
var _run_id := "0"
var _compatibility := "pending"
var _compatibility_code := "descriptor_pending"
var _compatibility_peer := 0
var _scene_resets := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and args[0] == "--vrweb-wasm-net-test":
		args.remove_at(0)
	_scenario = args[0] if args.size() > 0 else "compatible"
	_role = args[1] if args.size() > 1 else "leader"
	_run_id = args[2] if args.size() > 2 else "0"
	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = "%s-%s" % [_scenario, _role]
	Settings.online_enabled = true

	var package := _load_module()
	if package.is_empty():
		_finish(false, "could not load JavaScript vrmod")
		return
	var identity := ScriptingModuleIdentity.canonical([package])
	if _scenario == "mismatch" and _role == "follower":
		identity[0]["hash"] = "f".repeat(64)
	var required := ScriptingModuleIdentity.required_capabilities([package])
	NetworkManager.set_scripting_module_identity(identity, true, required, required)
	NetworkManager.register_replicated_schema(SCHEMA, {
		"version": 1,
		"fields": {"value": {"type": "int", "default": 0, "min": 0, "max": 100}},
		"default_write_rule": {"rank": {"op": "lte",
			"value": NetworkManager.DEFAULT_RANK}},
		"commands": {"set": {"reducer": func(_state, command, _context):
			return {"value": int(command.get("value", 0))}}},
	})
	NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": 0})
	NetworkManager.authority_changed.connect(func(_id, _is_me):
		NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": 0}))
	NetworkManager.scripting_module_compatibility_changed.connect(
			func(_peer_id: int, outcome: String, code: String):
				_compatibility_peer = _peer_id
				_compatibility = outcome
				_compatibility_code = code
				_log("COMPAT outcome=%s code=%s" % [outcome, code]))
	NetworkManager.replicated_command_result.connect(
			func(request_id, accepted, code, revision):
				_log("ACK request=%d accepted=%s code=%s revision=%d" % [
					request_id, accepted, code, revision]))
	NetworkManager.scene_reset.connect(func():
		_scene_resets += 1
		_log("SCENE_RESET count=%d" % _scene_resets))

	NetworkManager.connect_to_server()
	NetworkManager.join_room("wasm-identity-%s-%s" % [_scenario, _run_id])
	if not await _wait_for(func(): return _compatibility != "pending", 12.0):
		_finish(false, "descriptor outcome timed out")
		return
	if _scenario in ["compatible", "navigation", "navigation-race", "authority"]:
		await _run_compatible()
	else:
		await _run_mismatch()


func _load_module() -> Dictionary:
	var path := "res://sdk/javascript/dist/lifecycle.vrmod"
	if not FileAccess.file_exists(path): return {}
	var cached := ScriptingModuleCache.store(FileAccess.get_file_as_bytes(path))
	if not bool(cached.get("ok", false)): return {}
	var unpacked := ScriptingModulePackage.unpack({
		"id": "vrweb.example.javascript-lifecycle",
		"hash": cached.hash,
		"cache_path": cached.path,
	})
	return unpacked.module if bool(unpacked.get("ok", false)) else {}


func _run_compatible() -> void:
	if _compatibility != "compatible":
		_finish(false, "equal module identity was not compatible")
		return
	# Session setup resets room objects; recreate the fixture only after the descriptor gate opens.
	NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": 0})
	if _role == "follower":
		if not await _wait_for(func(): return NetworkManager.authority_id() != 0 \
				and not NetworkManager.has_authority(), 5.0):
			_finish(false, "follower did not discover authority")
			return
		await get_tree().create_timer(0.3).timeout
		# The initial authority snapshot may arrive just after the descriptor; recreate after it.
		_log("REGISTER follower=%s" % NetworkManager.register_replicated_object(
				OBJECT, SCHEMA, {"value": 0}))
		var request := NetworkManager.request_replicated_command(
				OBJECT, SCHEMA, 1, "set", {"value": 7})
		_log("COMMAND request=%d" % request)
	if not await _wait_for(func(): return int(NetworkManager.replicated_state(
			OBJECT, SCHEMA).get("value", 0)) == 7, 7.0):
		_finish(false, "compatible replicated command did not converge")
		return
	if _scenario in ["navigation", "navigation-race"]:
		await _run_navigation()
	elif _scenario == "authority":
		await _run_authority_change()
	else:
		_finish(true, "equal identity replicated value=7")


func _run_navigation() -> void:
	var transitions := 5 if _scenario == "navigation-race" else 1
	for index in range(transitions):
		var previous_peer := _compatibility_peer
		var previous_resets := _scene_resets
		_compatibility = "pending"
		_compatibility_code = "descriptor_pending"
		NetworkManager.join_room("wasm-identity-%s-%s-nav-%d" % [_scenario, _run_id, index])
		if not await _wait_for(func(): return _scene_resets > previous_resets, 5.0):
			_finish(false, "navigation did not reset room session")
			return
		var stale := NetworkManager.scripting_module_compatibility(previous_peer)
		if str(stale.outcome) != "pending" or str(stale.code) != "descriptor_pending":
			_finish(false, "navigation retained stale peer descriptor")
			return
		if int(NetworkManager.replicated_state(OBJECT, SCHEMA).get("value", 0)) != 0:
			_finish(false, "navigation retained replicated room state")
			return
		if not await _wait_for(func(): return _compatibility == "compatible", 12.0):
			_finish(false, "navigation did not complete a fresh descriptor handshake")
			return
		NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": 0})
		var expected := 13 + index
		if _role == "follower":
			await get_tree().create_timer(0.3).timeout
			NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": 0})
			NetworkManager.request_replicated_command(OBJECT, SCHEMA, 1, "set", {"value": expected})
		if not await _wait_for(func(): return int(NetworkManager.replicated_state(
				OBJECT, SCHEMA).get("value", 0)) == expected, 7.0):
			_finish(false, "post-navigation replicated command did not converge")
			return
	_finish(true, "navigation reset gate through %d transitions" % transitions)


func _run_authority_change() -> void:
	if _role == "leader":
		await get_tree().create_timer(0.8).timeout
		_finish(true, "initial authority left after compatible value=7")
		return
	if not await _wait_for(func(): return NetworkManager.has_authority(), 8.0):
		_finish(false, "follower did not become authority after leader exit")
		return
	NetworkManager.register_replicated_object(OBJECT, SCHEMA, {"value": 7})
	var request := NetworkManager.request_replicated_command(
			OBJECT, SCHEMA, 1, "set", {"value": 11})
	_log("AUTHORITY_COMMAND request=%d" % request)
	if not await _wait_for(func(): return int(NetworkManager.replicated_state(
			OBJECT, SCHEMA).get("value", 0)) == 11, 5.0):
		_finish(false, "new authority could not apply command after peer descriptor removal")
		return
	_finish(true, "authority changed after compatible handshake value=11")


func _run_mismatch() -> void:
	if _compatibility != "rejected" or _compatibility_code != "module_identity_mismatch":
		_finish(false, "hash mismatch did not produce normative rejection")
		return
	if _role == "follower":
		NetworkManager.request_replicated_command(OBJECT, SCHEMA, 1, "set", {"value": 9})
	await get_tree().create_timer(2.0).timeout
	var value := int(NetworkManager.replicated_state(OBJECT, SCHEMA).get("value", 0))
	_finish(value == 0, "mismatched command stayed blocked value=%d" % value)


func _wait_for(predicate: Callable, timeout: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout:
		if predicate.call(): return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05
	return false


func _finish(ok: bool, detail: String) -> void:
	_log("RESULT pass=%s %s" % [ok, detail])
	get_tree().quit(0 if ok else 1)


func _log(message: String) -> void:
	print("[WASM-NET-E2E %s/%s] %s" % [_scenario, _role, message])
