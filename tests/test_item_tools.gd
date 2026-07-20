extends Node

## Headless-тест «модовых» инструментов (docs/space/portable-tools.md): ItemToolbelt спавнит
## переносимые предметы из бандла и берёт в руку; карандаш рисует штрих в эфемерный слой
## (use + aim + use_end), ластик стирает свои штрихи, рамка размещает картинку через
## files.pick. Логика инструментов — целиком в item-документах (test_pages/items/*).
## Запуск: godot --headless tests/test_item_tools.tscn

const PLAYER_SCENE := preload("res://actors/player/player.tscn")

var _failed := false


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  OK  ", what)
	else:
		_failed = true
		printerr("FAIL  ", what)


func _ready() -> void:
	await get_tree().create_timer(60.0).timeout
	if is_inside_tree():
		printerr("ITEM TOOLS TEST: WATCHDOG"); get_tree().quit(2)


func _init() -> void:
	call_deferred("_run")


func _held_id(manager: GrabManager) -> String:
	var g := manager.local_held()
	return g.grab_id if g != null else ""


func _strokes() -> Array:
	var out: Array = []
	var objects := NetworkManager.scene_objects()
	for id in objects:
		if str(objects[id].get("kind", "")) == "stroke":
			out.append(objects[id])
	return out


func _run() -> void:
	Settings.online_enabled = false

	var world := Node3D.new()
	world.name = "world"
	add_child(world)
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
	for i in 12:
		await get_tree().physics_frame
	player.velocity = Vector3.ZERO
	player.set_physics_process(false)

	var manager := GrabManager.new()
	manager.name = "GrabManager"
	world.add_child(manager)
	manager.setup(player, null)

	var belt := ItemToolbelt.new()
	belt.name = "ItemToolbelt"
	world.add_child(belt)
	belt.setup(manager)

	var picked_png := "fake-image-bytes".to_utf8_buffer()
	var view := EphemeralView.new()
	view.name = "EphemeralView"
	world.add_child(view)
	view.setup(func(_transition): return, {
		"base_url": "vrwebresource://item_tools_test.html",
		"content_policy": VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL),
		"player": player,
		"file_picker": func(_kind: String, done: Callable) -> void:
			done.call(true, "poster.png", picked_png),
	})
	await get_tree().process_frame

	# --- Слот 2: карандаш в руке ---
	belt.handle_slot(&"tool_slot_2")
	for i in 12:
		await get_tree().process_frame
	_check(_held_id(manager).ends_with(".pencil-item"), "слот 2: карандаш в руке (%s)"
			% _held_id(manager))

	# --- Рисование: use → ведение поворотом камеры → use_end ---
	manager.use_held()
	for i in 6:
		player.rotate_y(0.12)
		await get_tree().process_frame
	manager.use_held_end()
	await get_tree().process_frame
	await get_tree().process_frame
	var strokes := _strokes()
	_check(strokes.size() == 1, "карандаш оставил один штрих в слое (%d)" % strokes.size())
	if strokes.size() == 1:
		var props: Dictionary = strokes[0].get("props", {})
		_check((props.get("points", []) as Array).size() >= 6, "штрих содержит точки")
		_check(str(strokes[0].get("author", "")) == Settings.user_id, "автор штриха — мы")
	var stroke_actors := get_tree().get_nodes_in_group(StrokeActor.GROUP)
	_check(stroke_actors.size() >= 1, "штрих материализован StrokeActor")
	# Превью-точки сняты при финализации.
	var leftover_csg := 0
	for node in world.find_children("*", "CSGSphere3D", true, false):
		leftover_csg += 1
	_check(leftover_csg == 0, "превью-точки карандаша сняты (%d)" % leftover_csg)

	# Вернуть прицел к середине нарисованной дуги — для ластика.
	player.rotate_y(-0.36)

	# --- Слот 2 ещё раз: ластик; зажатый use стирает свой штрих ---
	belt.handle_slot(&"tool_slot_2")
	for i in 12:
		await get_tree().process_frame
	_check(_held_id(manager).ends_with(".eraser-item"), "слот 2 ещё раз: ластик в руке (%s)"
			% _held_id(manager))
	manager.use_held()
	for i in 30:
		await get_tree().process_frame
	manager.use_held_end()
	await get_tree().process_frame
	_check(_strokes().is_empty(), "ластик стёр свой штрих (%d осталось)" % _strokes().size())

	# --- Слот 2 третий раз: инструмент убран, предметы сняты ---
	belt.handle_slot(&"tool_slot_2")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(manager.local_held() == null, "слот 2 третий раз: рука пуста")
	var item_count := 0
	for id in NetworkManager.scene_objects():
		if str(NetworkManager.scene_objects()[id].get("kind", "")) == "vrweb-item":
			item_count += 1
	_check(item_count == 0, "инструменты слота убраны из слоя (%d)" % item_count)

	# --- Слот 3: рамка; use → files.pick → VRWebImage в слое ---
	belt.handle_slot(&"tool_slot_3")
	for i in 12:
		await get_tree().process_frame
	_check(_held_id(manager).ends_with(".image-frame-item"), "слот 3: рамка в руке (%s)"
			% _held_id(manager))
	manager.use_held()
	await get_tree().process_frame
	await get_tree().process_frame
	var image_object: Dictionary = {}
	for id in NetworkManager.scene_objects():
		var object: Dictionary = NetworkManager.scene_objects()[id]
		if str(object.get("kind", "")) == "vrweb-node" \
				and str((object.get("props", {}) as Dictionary).get("tag", "")) == "VRWebImage":
			image_object = object
	_check(not image_object.is_empty(), "рамка добавила VRWebImage в слой")
	if not image_object.is_empty():
		var attrs: Dictionary = (image_object.get("props", {}) as Dictionary).get("attrs", {})
		_check(str(attrs.get("src", "")).begins_with("vrwebblob://"),
				"картинка адресуется блобом (%s)" % str(attrs.get("src", "")))
		_check(str(attrs.get("alt", "")) == "poster.png", "alt — имя выбранного файла")
	_check(BlobStore.has_hex(BlobProtocol.hash_bytes(picked_png)), "байты картинки в BlobStore")

	# --- Слот 3 ещё раз: рамка убрана ---
	belt.handle_slot(&"tool_slot_3")
	await get_tree().process_frame
	_check(manager.local_held() == null, "слот 3 ещё раз: рука пуста")

	get_tree().quit(1 if _failed else 0)
