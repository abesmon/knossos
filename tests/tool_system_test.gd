extends Node

## Headless смоук-тест системы инструментов (docs/client/tools.md): игрок + ToolManager.
## Проверяет контракт офлайн (вне комнаты): запрос активации по слотам (вложенный цикл
## рисования, тумблер картинки), приоритет ЛКМ у активного инструмента, офлайн-штрих и ластик,
## переключение инструментов чужим хоткеем, отмена по потере захвата мыши.
## Запуск: godot --headless tests/tool_system_test.tscn
## Выход 0 — все проверки прошли, иначе 1 (2 — ватчдог).

const PLAYER_SCENE := preload("res://actors/player/player.tscn")

var _failed := false


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  OK  ", what)
	else:
		_failed = true
		printerr("FAIL  ", what)


func _ready() -> void:
	_watchdog()
	_run()


## Если прогон завис/упал посреди await — выйти с ошибкой, а не крутиться вечно.
func _watchdog() -> void:
	await get_tree().create_timer(30.0).timeout
	printerr("TOOL SYSTEM TEST: WATCHDOG TIMEOUT")
	get_tree().quit(2)


func _run() -> void:
	var world := Node3D.new()
	world.name = "world"
	add_child(world)
	var player: Player = PLAYER_SCENE.instantiate()
	world.add_child(player)
	await get_tree().process_frame

	var tools: ToolManager = player.tools
	_check(tools != null, "ToolManager создан")
	var drawing: DrawingTool = tools.get_tool(&"drawing")
	var image: ImagePlacementTool = tools.get_tool(&"image")
	var bubble: BubbleTool = tools.get_tool(&"bubble")
	_check(drawing != null and image != null and bubble != null, "все три инструмента зарегистрированы")
	_check(not tools.is_tool_active(), "старт: нет активного инструмента")

	player.capture_mouse(true)

	# --- Слот 2: вложенный цикл рисования ---
	tools.handle_slot_action(&"tool_slot_2")
	_check(tools.is_tool_active() and drawing._mode == DrawingTool.Mode.PENCIL, "слот 2: карандаш")
	_check(drawing._held != null, "карандаш: визуал в руке")

	# Офлайн-штрих: press → движение камеры пару физ-кадров → release.
	_check(tools.handle_primary_pressed(), "ЛКМ поглощена инструментом")
	_check(drawing._drawing, "карандаш: штрих начат")
	for i in 4:
		player.rotate_y(0.4)
		await get_tree().physics_frame
	tools.handle_primary_released()
	await get_tree().process_frame
	var strokes := get_tree().get_nodes_in_group(StrokeActor.GROUP)
	_check(strokes.size() == 1, "офлайн-штрих остался в мире (%d)" % strokes.size())

	tools.handle_slot_action(&"tool_slot_2")
	_check(tools.is_tool_active() and drawing._mode == DrawingTool.Mode.ERASER, "слот 2 ещё раз: ластик")
	if strokes.size() > 0:
		var s: StrokeActor = strokes[0]
		drawing._erase_at(s._points[0])
		await get_tree().process_frame
		_check(get_tree().get_nodes_in_group(StrokeActor.GROUP).is_empty(), "ластик стёр офлайн-штрих")

	tools.handle_slot_action(&"tool_slot_2")
	_check(not tools.is_tool_active() and drawing._mode == DrawingTool.Mode.NONE,
			"слот 2 третий раз: инструмент убран")

	# --- Слот 3: тумблер картинки ---
	tools.handle_slot_action(&"tool_slot_3")
	_check(tools.is_tool_active() and image._state == ImagePlacementTool.State.AIMING, "слот 3: прицеливание")
	# physics_frame эмитится ДО _physics_process нод — ждём два кадра, чтобы превью успело обновиться.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(image._preview.visible, "прицеливание: превью видно")
	_check(tools.handle_secondary_pressed(), "ПКМ поглощена")
	_check(not tools.is_tool_active() and image._state == ImagePlacementTool.State.IDLE,
			"ПКМ: прицеливание отменено")

	# --- Переключение между инструментами чужим хоткеем ---
	tools.handle_slot_action(&"tool_slot_2")
	_check(drawing._mode == DrawingTool.Mode.PENCIL, "снова карандаш")
	tools.handle_slot_action(&"tool_slot_3")
	_check(tools.is_tool_active() and image._state == ImagePlacementTool.State.AIMING \
			and drawing._mode == DrawingTool.Mode.NONE,
			"слот 3 при карандаше: карандаш снят, прицеливание включено")
	tools.handle_slot_action(&"tool_slot_2")
	_check(drawing._mode == DrawingTool.Mode.PENCIL and image._state == ImagePlacementTool.State.IDLE,
			"слот 2 при прицеливании: прицеливание снято, карандаш достат")

	# Потеря захвата мыши посреди штриха — штрих отменяется, инструмент остаётся в руке.
	tools.handle_primary_pressed()
	player.capture_mouse(false)
	_check(not drawing._drawing and drawing._mode == DrawingTool.Mode.PENCIL,
			"потеря захвата посреди штриха: штрих отменён, карандаш в руке")

	# Системный пузырь: офлайн — no-op без падений (guard на in_room).
	bubble.drop("https://example.com/")
	_check(true, "BubbleTool.drop офлайн не падает")

	print("TOOL SYSTEM TEST: ", "FAILED" if _failed else "PASSED")
	get_tree().quit(1 if _failed else 0)
