extends Node

## Headless смоук-тест grabbable-системы (docs/client/grabbable.md): материализация тега
## <VRWebGrabbable> билдером, авто-коллайдер, офлайн-цикл grab → follow → use → release через
## GrabManager (standalone authority Replicated State) и портируемые события grab/drop/use.
## Запуск: godot --headless tests/test_grabbable.tscn
## Выход 0 — все проверки прошли, иначе 1 (2 — ватчдог).

const PLAYER_SCENE := preload("res://actors/player/player.tscn")

const PAGE := """
<html><body>
<vrwml mode="exclusive">
  <Resource id="BallMesh" type="SphereMesh" radius="0.2" height="0.4"/>
  <VRWebGrabbable id="ball" transform="Transform3D(1,0,0, 0,1,0, 0,0,1, 2,1,0)">
    <MeshInstance3D mesh="SubResource:::BallMesh"/>
  </VRWebGrabbable>
  <VRWebGrabbable id="statue" theft="deny" transform="Transform3D(1,0,0, 0,1,0, 0,0,1, -2,1,0)">
    <MeshInstance3D mesh="SubResource:::BallMesh"/>
  </VRWebGrabbable>
  <VRWebGrabbable id="crate" mode="adjustable" transform="Transform3D(1,0,0, 0,1,0, 0,0,1, 0,1,-2)">
    <MeshInstance3D mesh="SubResource:::BallMesh"/>
  </VRWebGrabbable>
</vrwml>
</body></html>
"""

var _failed := false
var _events: Array = []


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  OK  ", what)
	else:
		_failed = true
		printerr("FAIL  ", what)


func _ready() -> void:
	_watchdog()
	_run()


func _watchdog() -> void:
	await get_tree().create_timer(30.0).timeout
	printerr("GRABBABLE TEST: WATCHDOG TIMEOUT")
	get_tree().quit(2)


func _run() -> void:
	Settings.online_enabled = false  # standalone authority: команды коммитятся локально

	var world := Node3D.new()
	world.name = "world"
	add_child(world)

	# Пол обязателен: без него игрок падает от гравитации, и позиционные проверки
	# («предмет в якоре руки») становятся флаки — якорь смещается между кадрами.
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(60, 1, 60)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)

	var player: Player = PLAYER_SCENE.instantiate()
	world.add_child(player)
	player.global_position = Vector3(0, 1.0, 0)
	# Даём телу встать на пол и затем ГАСИМ его физику: иначе игрок продолжает двигаться в
	# _physics_process, предмет подтягивается к якорю в _process, и позиционные сравнения
	# становятся флаки (читаем позу игрока и предмета между разными фазами кадра).
	for i in 12:
		await get_tree().physics_frame
	player.velocity = Vector3.ZERO
	player.set_physics_process(false)

	var manager := GrabManager.new()
	manager.name = "GrabManager"
	world.add_child(manager)
	manager.setup(player, null)

	# --- Материализация страницы ---
	var doc := HtmlParser.parse(PAGE)
	var built := VrwebBuilder.build(doc, "https://example.test/")
	_check(built.get("found", false) and built.get("root") != null, "vrwml-блок собрался")
	world.add_child(built["root"])
	await get_tree().process_frame
	await get_tree().process_frame

	var ball: Grabbable = null
	var statue: Grabbable = null
	var crate: Grabbable = null
	for g in get_tree().get_nodes_in_group(Grabbable.GROUP):
		if g.grab_id == "ball":
			ball = g
		elif g.grab_id == "statue":
			statue = g
		elif g.grab_id == "crate":
			crate = g
	_check(ball != null and statue != null and crate != null, "все <VRWebGrabbable> материализованы")
	if ball == null or statue == null or crate == null:
		get_tree().quit(1)
		return
	_check(not statue.theft_allowed, "theft=\"deny\" разобран")
	_check(not ball.adjustable and crate.adjustable, "mode=\"adjustable\" разобран (default fixed)")
	_check(ball.collision_layer == 2 and ball.collision_mask == 0, "слой клик-луча (2), маска 0")
	var auto_shape := false
	for child in ball.get_children():
		if child is CollisionShape3D:
			auto_shape = true
	_check(auto_shape, "авто-коллайдер построен из AABB содержимого")

	var oid := "grab:ball"
	_check(NetworkManager.replicated_revision(oid, GrabStateSchema.ID) == 0,
			"hold-объект зарегистрирован в Replicated State")

	ball.grab.connect(func(u, h): _events.append(["grab", u, h]))
	ball.drop.connect(func(u, h): _events.append(["drop", u, h]))
	ball.use.connect(func(u, h): _events.append(["use", u, h]))

	# --- Grab ---
	_check(manager.can_local_grab(ball), "свободный предмет доступен для взятия")
	manager.request_grab(ball)
	await get_tree().process_frame
	var state := NetworkManager.replicated_state(oid, GrabStateSchema.ID)
	_check(str(NetworkManager.replicated_bindings(oid, GrabStateSchema.ID).get("holder", "")) \
			== Settings.user_id, "holder = локальный игрок")
	_check(str(state.get("hand")) == "right", "hand = right (десктоп)")
	_check(manager.local_held() == ball, "manager видит предмет в руке")
	_check(_events.size() == 1 and _events[0][0] == "grab", "событие grab эмитировано")
	_check(not manager.can_local_grab(ball), "свой держимый предмет повторно не берётся")

	# --- Follow: предмет следует за якорем руки (под камерой) ---
	await get_tree().process_frame
	var camera: Camera3D = player.get_node("Camera3D")
	var expected: Vector3 = (camera.global_transform \
			* Transform3D(Basis.IDENTITY, GrabManager.LOCAL_HAND_OFFSET)).origin
	_check(ball.global_position.distance_to(expected) < 0.01,
			"предмет в якоре руки (%.3f м)" % ball.global_position.distance_to(expected))

	player.global_position += Vector3(3, 0, 1)
	await get_tree().process_frame
	_check(ball.global_position.distance_to(expected) > 1.0, "предмет следует за игроком")

	# Пока правая рука занята — второй предмет не берётся.
	manager.request_grab(statue)
	await get_tree().process_frame
	_check(str(NetworkManager.replicated_bindings("grab:statue", GrabStateSchema.ID) \
			.get("holder", "")) == "", "второй предмет в занятую руку не берётся")

	# --- Use (transient, только у держателя) ---
	manager.use_held()
	_check(_events.size() == 2 and _events[1][0] == "use", "событие use эмитировано")

	# --- Release: предмет остаётся ТАМ, ГДЕ БЫЛ В РУКЕ (без телепорта в точку прицела) ---
	var held_at := ball.global_position
	manager.release_held()
	await get_tree().process_frame
	state = NetworkManager.replicated_state(oid, GrabStateSchema.ID)
	_check(str(NetworkManager.replicated_bindings(oid, GrabStateSchema.ID).get("holder", "")) \
			== "", "release: предмет свободен")
	_check(manager.local_held() == null, "рука пуста")
	_check(_events.size() == 3 and _events[2][0] == "drop", "событие drop эмитировано")
	var rest := GrabStateSchema.unpack_transform(state.get("rest"))
	_check(ball.global_position.distance_to(rest.origin) < 0.01, "предмет лёг в канонический rest")
	_check(ball.global_position.distance_to(held_at) < 0.01,
			"release на месте удержания (сдвиг %.3f м)" % ball.global_position.distance_to(held_at))

	await _test_adjustable(manager, crate, player)
	get_tree().quit(1 if _failed else 0)


## Режим adjustable: хват берётся из фактической позы (без снапа), дальше держатель
## подстраивает дистанцию/поворот, а канон догоняет throttled-командами adjust.
func _test_adjustable(manager: GrabManager, crate: Grabbable, player: Player) -> void:
	var oid := "grab:crate"
	var before_grab := crate.global_position
	var camera: Camera3D = player.get_node("Camera3D")
	var anchor := camera.global_transform * Transform3D(Basis.IDENTITY, GrabManager.LOCAL_HAND_OFFSET)

	manager.request_grab(crate)
	await get_tree().process_frame
	_check(manager.local_held() == crate, "adjustable: предмет взят")
	_check(manager.holding_adjustable(), "adjustable: манипуляция доступна")
	# Естественный хват: предмет не прыгнул в позу под камерой, а сохранил своё место.
	_check(crate.global_position.distance_to(before_grab) < 0.01,
			"adjustable: предмет НЕ прыгнул в фикс-позу (сдвиг %.3f м)"
			% crate.global_position.distance_to(before_grab))
	var fixed_slot: Vector3 = anchor.origin
	_check(crate.global_position.distance_to(fixed_slot) > 0.3,
			"adjustable: хват сохранил исходный офсет, а не слот fixed")

	# Дистанция: колесо вниз (steps < 0) придвигает, вверх (steps > 0) отодвигает.
	var dist_before := crate.global_position.distance_to(camera.global_position)
	manager.adjust_distance(-1.0)
	await get_tree().process_frame
	var dist_near := crate.global_position.distance_to(camera.global_position)
	_check(dist_near < dist_before,
			"adjustable: колесо придвинуло предмет (%.2f → %.2f м)" % [dist_before, dist_near])
	manager.adjust_distance(1.0)
	await get_tree().process_frame
	_check(crate.global_position.distance_to(camera.global_position) > dist_near,
			"adjustable: колесо в обратную сторону отодвинуло предмет")

	# Ближний предел: сколько ни крути, предмет не влезает в камеру.
	for i in 40:
		manager.adjust_distance(-1.0)
	await get_tree().process_frame
	_check(crate.global_position.distance_to(camera.global_position) > 0.2,
			"adjustable: ближний предел дистанции соблюдён")

	# Вращение: средняя кнопка + мышь крутят предмет в слоте, не поворачивая взгляд.
	# Сравниваем именно ОРИЕНТАЦИЮ: позиция игрока в тестовом мире (без пола) плывёт от
	# гравитации, и сравнение полного трансформа камеры было бы флаки.
	var basis_before := crate.global_transform.basis
	var cam_basis_before := camera.global_transform.basis
	var yaw_before := player.rotation.y
	manager.adjust_rotation(Vector2(40, 0))
	await get_tree().process_frame
	_check(not crate.global_transform.basis.is_equal_approx(basis_before),
			"adjustable: предмет повернулся в слоте")
	_check(camera.global_transform.basis.is_equal_approx(cam_basis_before) \
			and is_equal_approx(player.rotation.y, yaw_before),
			"adjustable: вращение предмета не поворачивает взгляд")

	# Канон догнал подстройку (throttled commit форсится при release).
	manager.release_held()
	await get_tree().process_frame
	var state := NetworkManager.replicated_state(oid, GrabStateSchema.ID)
	_check(str(NetworkManager.replicated_bindings(oid, GrabStateSchema.ID).get("holder", "")) \
			== "", "adjustable: предмет отпущен")
	# Подстройка доехала до канона: release форсит отложенный commit хвата.
	var canonical_grip := GrabStateSchema.unpack_transform(state.get("grip"))
	_check(not canonical_grip.is_equal_approx(Transform3D.IDENTITY),
			"adjustable: подстроенный хват попал в канон")
