extends Node

## End-to-end late join предмета по реальному WebRTC mesh: holder заходит первым, спавнит
## item-инструмент и берёт его в руку; late заходит позже и обязан увидеть предмет В РУКЕ
## держателя, а не висящим в воздухе. Процессы запускает tests/run_net_grabbable_test.py.

# Takeover path needs the default theft="allow" contract; pencil intentionally declares deny.
const ITEM_SRC := "vrwebresource://items/color_cube.html"
const ROOM := "grabbable-late-join-e2e"

var _role := "holder"
var _world: Node3D
var _player: Player
var _manager: GrabManager
var _remote_view: RemotePlayersView
var _view: EphemeralView
var _item_id := ""
var _p2p := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if not args.is_empty() else "holder"
	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _role
	Settings.online_enabled = true

	# У holder мир уже загружен. Late намеренно подключается БЕЗ мира/GrabManager: в настоящем
	# клиенте WebRTC snapshot способен обогнать fetch и materialization страницы.
	if _role == "holder":
		_build_world()
	NetworkManager.p2p_peer_connected.connect(func(id):
		_p2p += 1
		_log("P2P %d" % id))
	NetworkManager.connect_to_server()
	NetworkManager.join_room(ROOM)

	match _role:
		"holder": await _run_holder()
		"late": await _run_late()
		_: _finish(false, "unknown role")


## Мир как в main._rebuild_world: игрок, вид чужих игроков, менеджер предметов, вьюха слоя.
func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "world"
	add_child(_world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(60, 1, 60)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	_world.add_child(floor_body)

	_player = preload("res://actors/player/player.tscn").instantiate()
	_world.add_child(_player)
	_player.global_position = Vector3(0, 1.0, 0)

	_remote_view = RemotePlayersView.new()
	_remote_view.name = "RemotePlayersView"
	_world.add_child(_remote_view)
	_remote_view.setup(_player)

	_manager = GrabManager.new()
	_manager.name = "GrabManager"
	_world.add_child(_manager)
	_manager.setup(_player, _remote_view)

	_view = EphemeralView.new()
	_view.name = "EphemeralView"
	_world.add_child(_view)
	_view.setup(func(_t): return, {
		"base_url": "vrwebresource://net_grabbable_test.html",
		"content_policy": VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL),
		"player": _player, "file_picker": Callable(),
	})


func _run_holder() -> void:
	if not await _wait_for(func(): return NetworkManager.has_authority(), 10.0):
		_finish(false, "holder did not become authority")
		return
	_item_id = NetworkManager.new_object_id()
	NetworkManager.request_scene_action({"op": SceneChanges.OP_ADD, "id": _item_id,
		"kind": "vrweb-item", "parent": "", "ttl": 0.0,
		"props": {"src": ITEM_SRC, "position": [0.0, 1.0, -2.0]}})
	if not await _wait_for(func(): return _find_item() != null, 8.0):
		_finish(false, "holder did not materialize item")
		return
	var cube := _find_item()
	_manager.request_grab(cube)
	if not await _wait_for(func(): return _manager.local_held() == cube, 5.0):
		_finish(false, "holder could not grab item")
		return
	_log("HOLDING %s" % cube.grab_id)
	# Late joiner затем перехватывает theft=allow предмет. Оба клиента обязаны сойтись на нём,
	# а не только authority (исходный баг показывал новый holder лишь первому пользователю).
	if not await _wait_for(func(): return _manager.holder_of(cube) != Settings.user_id, 16.0):
		_finish(false, "holder never observed late joiner takeover")
		return
	var takeover_holder := _manager.holder_of(cube)
	# Дать reliable DELTA/ACK физически уйти в сокет до завершения процесса authority.
	await get_tree().create_timer(2.0).timeout
	_finish(_manager.local_held() != cube and takeover_holder != "",
			"authority released local hand and observed late joiner takeover")


func _run_late() -> void:
	if not await _wait_for(func(): return _p2p >= 1 and not NetworkManager.has_authority(), 12.0):
		_finish(false, "late did not connect as follower")
		return
	if not await _wait_for(func(): return int(NetworkManager.replicated_metrics() \
			.get("snapshot_applied_count", 0)) >= 1, 8.0):
		_finish(false, "late did not receive pre-page replicated snapshot")
		return
	_log("PRE-PAGE SNAPSHOT APPLIED")
	_build_world()
	if not await _wait_for(func(): return _find_item() != null, 10.0):
		_finish(false, "late did not materialize item")
		return
	var hold_id := "grab:" + _find_item().grab_id
	_log("ITEM %s rev_at_materialize=%d" % [_find_item().grab_id,
			NetworkManager.replicated_revision(hold_id, GrabStateSchema.ID)])

	# Каноническое hold-состояние должно ДОЖИТЬ до этого момента: раньше пересборка вьюхи по
	# снимку сцены снимала локальный узел и вместе с ним стирала объект в Store.
	if not await _wait_for(func(): return str(NetworkManager.replicated_bindings(hold_id,
			GrabStateSchema.ID).get("holder", "")) != "", 10.0):
		_finish(false, "late never received hold state (state=%s rev=%d)" % [
			NetworkManager.replicated_state(hold_id, GrabStateSchema.ID),
			NetworkManager.replicated_revision(hold_id, GrabStateSchema.ID)])
		return
	var holder := str(NetworkManager.replicated_bindings(hold_id, GrabStateSchema.ID).get("holder", ""))
	_log("HOLD STATE holder=%s" % holder)

	# И менеджер обязан отслеживать предмет как держимый ЧУЖИМ участником. Узел предмета
	# вьюха может пересоздать (снимок сцены), поэтому ищем его заново на каждой попытке.
	var tracked := await _wait_for(func():
		var node := _find_item()
		return node != null and _manager.holder_of(node) == holder, 8.0)
	if not tracked:
		var node := _find_item()
		_finish(false, "manager does not track remote holder (holder_of=%s, rev=%d)" % [
			"none" if node == null else _manager.holder_of(node),
			NetworkManager.replicated_revision(hold_id, GrabStateSchema.ID)])
		return
	var item := _find_item()
	if not _manager.can_local_grab(item):
		_finish(false, "theft=allow item unexpectedly cannot be taken")
		return
	_manager.request_grab(item)
	if not await _wait_for(func():
		var node := _find_item()
		return node != null and _manager.local_held() == node, 8.0):
		_finish(false, "takeover committed on authority but not on late joiner")
		return
	# Визуальная привязка к чужому якорю покрыта headless-тестом; здесь проверяется полная
	# последовательность репликации до и после пользовательского Equip/«Забрать».
	_finish(true, "late joiner restored hold state and then equipped item locally")


func _find_item() -> Grabbable:
	for node in get_tree().get_nodes_in_group(Grabbable.GROUP):
		if node is Grabbable and (node as Grabbable).grab_id.begins_with("item-"):
			return node
	return null


func _capsule_count() -> int:
	var count := 0
	for peer_id in NetworkManager.peer_ids():
		if _remote_view.capsule_for_user(NetworkManager.user_id_of(peer_id)) != null:
			count += 1
	return count


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
	print("[GRAB-E2E %s t=%d] %s" % [_role, Time.get_ticks_msec(), message])
