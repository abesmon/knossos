class_name ToolManager
extends Node

## Держатель инструментов игрока: создаёт их, маршрутизирует ввод от Player и следит, чтобы
## активен был максимум один. Хоткей слота — «запрос активации» инструменту: тот сам решает,
## что происходит (вложенный цикл режимов у рисования, тумблер у картинки). Нажатие чужого
## хоткея снимает текущий инструмент. Системные инструменты (bubble) не имеют слота и
## вызываются программно. См. docs/client/tools.md.

## Сменился активный инструмент: tool_id ("drawing"/"image"/…), "" — все инструменты убраны.
signal tool_changed(tool_id: String)
## Подсказка для строки статуса (ретрансляция PlayerTool.hint_changed) — main пишет в _set_status.
signal status_hint(text: String)
## Инструменту размещения нужен файл: main открывает диалог и возвращает результат через
## get_tool(&"image").provide_file(ok, path). Пикер — UI, он остаётся у main; спавн — у инструмента.
signal image_pick_requested(filters: PackedStringArray)

var _active: PlayerTool = null
var _slots: Dictionary = {}   # имя input-действия (StringName) -> PlayerTool
var _tools: Dictionary = {}   # tool_id (StringName) -> PlayerTool


## Player зовёт после добавления в дерево: создаёт инструменты и раздаёт им контекст.
func setup(camera: Camera3D, world_root: Node3D, player: Player) -> void:
	var drawing := DrawingTool.new()
	var image := ImagePlacementTool.new()
	var bubble := BubbleTool.new()
	for t: PlayerTool in [drawing, image, bubble]:
		t.name = String(t.tool_id()).to_pascal_case() + "Tool"
		add_child(t)
		t.setup(camera, world_root, player)
		t.hint_changed.connect(status_hint.emit)
		t.finished.connect(_on_tool_finished.bind(t))
		_tools[t.tool_id()] = t
	image.pick_requested.connect(image_pick_requested.emit)
	_slots = {&"tool_slot_2": drawing, &"tool_slot_3": image}


func get_tool(id: StringName) -> PlayerTool:
	return _tools.get(id)


func is_tool_active() -> bool:
	return _active != null


# --- Маршрутизация ввода (зовёт Player._unhandled_input) ---

## Нажат хоткей слота. Инструмент слота сам интерпретирует запрос (цикл/тумблер); менеджер
## лишь снимает предыдущий активный и синхронизирует equip/unequip с ответом инструмента.
func handle_slot_action(action: StringName) -> void:
	var tool: PlayerTool = _slots.get(action)
	if tool == null:
		return
	if _active != null and _active != tool:
		_deactivate_current()   # чужой хоткей снимает текущий инструмент
	if tool.activation_request():
		if _active != tool:
			_active = tool
			tool.equip()
			tool_changed.emit(String(tool.tool_id()))
	elif _active == tool:
		_deactivate_current()


## ЛКМ press. Возврат true — поглощено активным инструментом (иначе Player отдаёт клик порталам).
func handle_primary_pressed() -> bool:
	if _active == null:
		return false
	_active.primary_pressed()
	return true


func handle_primary_released() -> void:
	if _active != null:
		_active.primary_released()


## ПКМ. Возврат true — поглощено активным инструментом.
func handle_secondary_pressed() -> bool:
	return _active != null and _active.secondary_pressed()


## Захват мыши сменился (Esc, потеря фокуса, файловый диалог) — форвард активному инструменту.
func on_mouse_capture_changed(captured: bool) -> void:
	if _active != null:
		_active.on_mouse_capture_changed(captured)


## Инструмент сам завершился (finished) — деактивируем, если он был активным.
func _on_tool_finished(tool: PlayerTool) -> void:
	if _active == tool:
		_deactivate_current()


func _deactivate_current() -> void:
	var tool := _active
	_active = null
	tool.unequip()
	tool_changed.emit("")
