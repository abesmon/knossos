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


## Текстура картинки (или null): читаем материал лицевого меша — публичного геттера у
## ImagePanel нет, а заводить его ради теста не стоит.
func _panel_texture(panel: ImagePanel) -> Texture2D:
	var front := panel.get_node_or_null("Front") as MeshInstance3D
	if front == null:
		return null
	var material := front.material_override as StandardMaterial3D
	return material.albedo_texture if material != null else null


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

	var picker_log: Array = []   # когда именно открывался «диалог» (см. проверку ниже)

	# Настоящий PNG: импорт картинки проверяет формат по сигнатуре байтов, мусор он отвергнет.
	var source_image := Image.create_empty(24, 16, false, Image.FORMAT_RGBA8)
	source_image.fill(Color(0.2, 0.7, 0.4, 1.0))
	var picked_png := source_image.save_png_to_buffer()

	# Загрузчик картинок живёт в мире (как в main): без него <VRWebImage> останется заглушкой.
	var image_loader := ImageLoader.new()
	image_loader.name = "ImageLoader"
	world.add_child(image_loader)

	var view := EphemeralView.new()
	view.name = "EphemeralView"
	world.add_child(view)
	view.setup(func(_transition): return, {
		"base_url": "vrwebresource://item_tools_test.html",
		"content_policy": VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL),
		"player": player,
		"file_picker": func(_kind: String, done: Callable) -> void:
			picker_log.append("open")
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

	# Прицельное превью: луч и маркер видны у держателя и стоят в точке прицела.
	await get_tree().process_frame
	var beam: MeshInstance3D = null
	var marker: MeshInstance3D = null
	# Узлы из VRWML получают авто-имена — ищем по признакам превью: top_level + тип меша.
	for node in world.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if not mesh_node.top_level:
			continue
		if mesh_node.mesh is QuadMesh:
			marker = mesh_node
		elif mesh_node.mesh is BoxMesh:
			beam = mesh_node
	_check(marker != null and marker.visible, "маркер размещения виден у держателя")
	_check(beam != null and beam.visible, "луч прицеливания виден у держателя")
	if marker != null:
		var camera: Camera3D = player.get_node("Camera3D")
		var distance := marker.global_position.distance_to(camera.global_position)
		_check(distance > 0.2 and distance <= 1.6,
				"маркер на конце луча (%.2f м)" % distance)

		# Стена в пределах досягаемости луча (1.5 м): маркер должен прижаться к ней и
		# развернуться по её нормали (лицевая грань квада +Z смотрит на игрока).
		var wall := StaticBody3D.new()
		var wall_shape := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = Vector3(4, 4, 0.2)
		wall_shape.shape = wall_box
		wall.add_child(wall_shape)
		world.add_child(wall)
		wall.global_position = camera.global_position + Vector3(0, 0, -1.0)
		await get_tree().physics_frame
		await get_tree().process_frame
		await get_tree().process_frame

		var facing := marker.global_transform.basis.z.normalized()
		_check(facing.dot(Vector3.BACK) > 0.9,
				"на поверхности маркер развёрнут по нормали (back·z = %.2f)"
				% facing.dot(Vector3.BACK))
		var surface_z: float = camera.global_position.z - 0.9   # передняя грань стены
		_check(absf(marker.global_position.z - surface_z) < 0.06,
				"маркер прижат к поверхности (z = %.2f, ожидалось ≈ %.2f)"
				% [marker.global_position.z, surface_z])

		wall.queue_free()
		await get_tree().physics_frame
		await get_tree().process_frame

	# Диалог обязан открываться ВНЕ стека скрипта: модальное окно ОС крутит свой цикл событий,
	# и открытие прямо из host-вызова подвешивает приложение на том же lua_State.
	picker_log.clear()
	manager.use_held()
	_check(picker_log.is_empty(), "диалог не открывается из стека скрипта")
	await get_tree().process_frame
	_check(not picker_log.is_empty(), "диалог открылся следующим кадром")

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
		_check(str(attrs.get("transform", "")).begins_with("Transform3D("),
				"поза размещения — полный transform (%s)" % str(attrs.get("transform", "")).left(24))

	# Картинка должна ПОЯВИТЬСЯ в мире: узел материализован и текстура доехала из блоба.
	var panel: ImagePanel = null
	for node in view.find_children("*", "", true, false):
		if node is ImagePanel:
			panel = node
	_check(panel != null, "VRWebImage материализован в мире (ImagePanel)")
	var textured := false
	for i in 30:
		await get_tree().process_frame
		if panel != null and _panel_texture(panel) != null:
			textured = true
			break
	_check(textured, "текстура картинки загрузилась из блоба")

	# --- Слот 3 ещё раз: рамка убрана; превью гаснет ---
	belt.handle_slot(&"tool_slot_3")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(manager.local_held() == null, "слот 3 ещё раз: рука пуста")
	_check(marker == null or not is_instance_valid(marker) or not marker.visible,
			"маркер погас после уборки инструмента")

	get_tree().quit(1 if _failed else 0)
