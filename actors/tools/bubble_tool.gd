class_name BubbleTool
extends PlayerTool

## Системный инструмент «пузырь»: не имеет слота и не выбирается игроком — вызывается программно
## навигацией (main._drop_leave_bubble при состоявшемся переходе). Артефакт — временный портал
## «ушёл сюда» (kind="bubble", актор Bubble) в точке, где стоял игрок. Живёт в системе инструментов,
## чтобы весь спавн артефактов игрока шёл одним путём. См. docs/ephemeral-changes.md и
## docs/client/tools.md.

## TTL пузыря — временного портала «ушёл сюда».
const BUBBLE_TTL := 30.0


func tool_id() -> StringName:
	return &"bubble"


func descriptor() -> Dictionary:
	return {"kind": "tool-bubble", "props": {"ttl": BUBBLE_TTL}}


## Запрашивает эфемерное изменение kind="bubble": временный портал в текущей точке игрока,
## указывающий на URL назначения. Только онлайн и находясь в комнате; навигационные проверки
## (переход состоялся, комната сменилась) — на вызывающем (main). Позиция хранится как [x,y,z]
## ради JSON-сериализуемости журнала.
func drop(target_url: String) -> void:
	if not (Settings.online_enabled and NetworkManager.in_room()):
		return
	var p := _player.global_position
	# Действие add: инициатор описывает только нужную мутацию. id — наш адрес объекта (для будущих
	# правок/удаления своего пузыря). parent="" — корень мира (детерминированные координаты).
	NetworkManager.request_scene_action({
		"op": "add",
		"id": NetworkManager.new_object_id(),
		"kind": "bubble",
		"parent": "",
		"ttl": BUBBLE_TTL,
		"props": {
			"url": target_url,
			"position": [p.x, p.y, p.z],
			"label": Settings.nick,
		},
	})
