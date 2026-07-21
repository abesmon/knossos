extends Node

## Два реальных WebRTC-клиента запускают creator-facing demo. Проверяется direct SAMPLE от
## binding simulator, proxy movement и передача simulator follower-у через page API.

const ROOM := "networked-rigidbody-e2e"

var _role := "authority"
var _runtime: VrwebLuauRuntime
var _page_root: Node
var _ball: RigidBody3D
var _p2p := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if not args.is_empty() else "authority"
	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _role
	Settings.online_enabled = true
	NetworkManager.p2p_peer_connected.connect(func(id):
		_p2p += 1
		_log("P2P %d" % id))
	NetworkManager.connect_to_server()
	NetworkManager.join_room(ROOM)
	if _role == "authority":
		await _run_authority()
	else:
		await _run_follower()


func _build_demo() -> bool:
	var html := FileAccess.get_file_as_string("res://test_pages/networked_rigidbody.html")
	var doc := HtmlParser.parse(html)
	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var built := VrwebBuilder.build(doc, "vrwebresource://networked_rigidbody.html", policy)
	_page_root = built.root
	add_child(_page_root)
	var targets := {}
	var index := SceneHtml.build_page_index(doc)
	for node_id in index.get("nodes", {}):
		var record: Dictionary = index.nodes[node_id]
		var node = (built.nodes as Dictionary).get(record.elem)
		if node != null:
			targets[node_id] = node
	for resource_id in built.get("resources", {}):
		targets[resource_id] = built.resources[resource_id]
	_ball = targets.get("default-ball")
	var declarations := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://networked_rigidbody.html")
	_runtime = VrwebLuauRuntime.new()
	add_child(_runtime)
	_runtime.setup(_page_root, targets, "vrwebresource://networked_rigidbody.html", null, policy)
	var activated := _runtime.activate(declarations.scripts)
	_log("DEMO activated=%s" % str(activated))
	return bool(activated.ok) and _ball != null


func _run_authority() -> void:
	if not await _wait_for(func(): return NetworkManager.has_authority(), 10.0) or not _build_demo():
		_finish(false, "authority setup failed")
		return
	var oid := "demo.networked-rigidbody/default_ball"
	var sid := "demo.networked-rigidbody/physics_default_ball"
	if not await _wait_for(func(): return NetworkManager.replicated_bindings(oid, sid) \
			.get("simulator") == Settings.user_id, 8.0):
		_finish(false, "authority did not become initial simulator")
		return
	# Создаём видимый поток до takeover follower-а.
	_ball.apply_central_impulse(Vector3(2, 4, -3))
	if not await _wait_for(func(): return _p2p >= 1, 12.0):
		_finish(false, "follower did not connect")
		return
	if not await _wait_for(func(): return str(NetworkManager.replicated_bindings(oid, sid) \
			.get("simulator", "")) != Settings.user_id, 15.0):
		_finish(false, "authority never observed simulator handoff")
		return
	if not await _wait_for(func(): return _ball.freeze, 4.0):
		_finish(false, "old simulator did not become proxy")
		return
	await get_tree().create_timer(1.0).timeout
	_finish(true, "authority accepted follower simulator and became proxy")


func _run_follower() -> void:
	if not await _wait_for(func(): return _p2p >= 1 and not NetworkManager.has_authority(), 12.0):
		_finish(false, "follower did not join")
		return
	if not _build_demo():
		_finish(false, "follower demo setup failed")
		return
	var oid := "demo.networked-rigidbody/default_ball"
	var sid := "demo.networked-rigidbody/physics_default_ball"
	if not await _wait_for(func(): return not str(NetworkManager.replicated_bindings(oid, sid) \
			.get("simulator", "")).is_empty(), 10.0):
		_finish(false, "follower did not restore simulator binding")
		return
	if not _ball.freeze:
		_finish(false, "follower is not proxy before takeover")
		return
	var start := _ball.global_position
	if not await _wait_for(func(): return _ball.global_position.distance_to(start) > 0.05, 8.0):
		_finish(false, "proxy did not consume direct simulator samples")
		return
	var bridge = _ball.get_meta(VrwebScriptInputBridge.META, null)
	if not (bridge is VrwebScriptInputBridge) or not bridge.dispatch(_ball.global_position):
		_finish(false, "page activation did not request handoff")
		return
	if not await _wait_for(func(): return NetworkManager.replicated_bindings(oid, sid) \
			.get("simulator") == Settings.user_id, 10.0):
		_finish(false, "follower did not receive simulator binding")
		return
	_finish(not _ball.freeze, "follower received local simulation after handoff")


func _wait_for(predicate: Callable, timeout: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout:
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05
	return false


func _finish(ok: bool, detail: String) -> void:
	_log("RESULT pass=%s %s" % [ok, detail])
	get_tree().quit(0 if ok else 1)


func _log(message: String) -> void:
	print("[RIGIDBODY-E2E %s t=%d] %s" % [_role, Time.get_ticks_msec(), message])
