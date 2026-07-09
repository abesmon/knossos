class_name PlayerTool
extends Node3D

## Базовый класс инструмента игрока. Инструмент — то, чем действует игрок; артефакт (штрих,
## картинка, пузырь) — то, что инструмент оставляет в мире (эфемерный объект). Каждый инструмент —
## отдельный класс, вся логика (визуал «в руке», превью, действия, спавн артефактов) инкапсулирована
## в нём. Владеет и маршрутизирует ввод ToolManager: активен максимум один инструмент.
## Полное описание системы — docs/client/tools.md.

## Подсказка для строки статуса (main ретранслирует в _set_status через ToolManager.status_hint).
@warning_ignore("unused_signal")   # эмитят наследники
signal hint_changed(text: String)
## Инструмент сам решил завершиться (напр. картинка размещена/отменена) — менеджер деактивирует.
@warning_ignore("unused_signal")   # эмитят наследники
signal finished

## Положение «кисти» (основания инструмента) относительно камеры: правее/ниже центра и слегка
## дальше от лица.
const HAND_OFFSET := Vector3(0.14, -0.14, -0.55)

var _cam: Camera3D
var _world: Node3D       # корень мира: куда вешать превью/офлайн-артефакты (гибнут при навигации)
var _player: Player
var _held: Node3D        # визуал инструмента в руке (под камерой); null — нет визуала
var _equipped := false


func _ready() -> void:
	# Пер-кадровая логика (ведение штриха, луч размещения) нужна только активному инструменту.
	set_physics_process(false)


## ToolManager зовёт после добавления в дерево: камера для прицела/визуала, world — корень мира.
func setup(camera: Camera3D, world_root: Node3D, player: Player) -> void:
	_cam = camera
	_world = world_root
	_player = player


## Стабильный идентификатор инструмента ("drawing"/"image"/"bubble") — для ToolManager.get_tool
## и сигнала tool_changed.
func tool_id() -> StringName:
	return &""


## Хоткей слота нажат. Инструмент САМ решает, что происходит (вложенный цикл режимов, тумблер…).
## Возврат: true — инструмент активен (остаётся активным), false — деактивировался/не активировался.
## Менеджер гарантирует: перед вызовом на НЕактивном инструменте текущий активный уже unequip'нут.
func activation_request() -> bool:
	return false


## Инструмент «достали»: базовая реализация вешает визуал под камеру и включает пер-кадровую логику.
func equip() -> void:
	_equipped = true
	set_physics_process(true)
	_refresh_held_visual()


## Инструмент «убрали» (деактивация менеджером): снять визуал, сбросить внутреннее состояние.
func unequip() -> void:
	_equipped = false
	set_physics_process(false)
	_clear_held()
	_on_unequip()


## Точка сброса внутреннего состояния подкласса при деактивации (virtual).
func _on_unequip() -> void:
	pass


# --- Действия (зовёт ToolManager, только на активном инструменте) ---

func primary_pressed() -> void:
	pass


func primary_released() -> void:
	pass


## Второстепенное действие (ПКМ). Возврат true — событие поглощено инструментом.
func secondary_pressed() -> bool:
	return false


## Захват мыши включён/выключен (Esc, потеря фокуса окна, файловый диалог). Инструмент сам
## решает, что отменять (незавершённый штрих, прицеливание…).
func on_mouse_capture_changed(_captured: bool) -> void:
	pass


# --- Визуал «в руке» ---

## Процедурный визуал инструмента для руки (virtual). null — у инструмента нет визуала.
func make_held_node() -> Node3D:
	return null


## Пересобрать визуал в руке (смена внутреннего режима на уже экипированном инструменте).
func _refresh_held_visual() -> void:
	_clear_held()
	if _cam == null:
		return
	_held = make_held_node()
	if _held != null:
		_cam.add_child(_held)
		_held.position = HAND_OFFSET


func _clear_held() -> void:
	if is_instance_valid(_held):
		_held.queue_free()
	_held = null


# --- Задел под «инструмент как эфемерный объект» (см. docs/client/tools.md) ---

## Сериализуемый дескриптор инструмента в стиле эфемерного слоя (kind+props): по нему в будущем
## инструмент можно будет заспавнить в эфемерный слой как подбираемый предмет (pickable), чтобы
## другие игроки видели его и могли сохранить себе. Сейчас никуда не отправляется.
func descriptor() -> Dictionary:
	return {"kind": "", "props": {}}
