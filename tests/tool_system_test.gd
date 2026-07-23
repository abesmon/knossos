extends Node

## Headless смоук-тест системных инструментов (docs/client/tools.md): ToolManager теперь
## держит только системный пузырь — пользовательские инструменты стали переносимыми
## предметами (ItemToolbelt, docs/space/portable-tools.md; их тест — test_item_tools.tscn).
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
	var bubble: BubbleTool = tools.get_tool(&"bubble")
	_check(bubble != null, "системный пузырь зарегистрирован")
	_check(not tools.is_tool_active(), "старт: нет активного инструмента")

	player.capture_mouse(true)

	# Слотов у системного менеджера больше нет: хоткеи — за ItemToolbelt.
	tools.handle_slot_action(&"tool_slot_2")
	_check(not tools.is_tool_active(), "слоты не активируют системный менеджер")

	# ЛКМ без активного инструмента не поглощается (уходит взаимодействию/grabbable).
	_check(not tools.handle_primary_pressed(), "ЛКМ без инструмента не поглощена")

	# Системный пузырь: офлайн — no-op без падений (guard на in_room).
	bubble.drop("https://example.com/")
	_check(true, "BubbleTool.drop офлайн не падает")

	print("TOOL SYSTEM TEST: ", "FAILED" if _failed else "PASSED")
	get_tree().quit(1 if _failed else 0)
