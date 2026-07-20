class_name ItemToolbelt
extends Node

## Тонкая клиентская обвязка «модовой» модели инструментов (docs/space/portable-tools.md):
## хоткей слота спавнит СТАНДАРТНЫЙ item-инструмент (переносимый предмет из бандла,
## test_pages/items/*) и берёт его в руку; повторный хоткей циклит/убирает. Вся логика
## инструмента — в самом item (VRWML + Luau), клиент лишь достаёт и убирает предметы.
##
## Слот 2 циклит нет → карандаш → ластик → нет (преемственность старого DrawingTool);
## слот 3 — тумблер рамки картинок. Живёт в мире (пересоздаётся при навигации — предметы
## комнаты и так исчезают вместе с ней).

signal status_hint(text: String)

const SLOT2_CYCLE: Array[Dictionary] = [
	{"src": "vrwebresource://items/pencil.html",
		"hint": "Карандаш в руке — зажмите ЛКМ, чтобы рисовать; G — положить"},
	{"src": "vrwebresource://items/eraser.html",
		"hint": "Ластик в руке — зажмите ЛКМ, чтобы стирать свои штрихи; G — положить"},
]
const SLOT3_ITEM := {"src": "vrwebresource://items/image_frame.html",
	"hint": "Рамка в руке — ЛКМ: выбрать картинку и разместить в точке прицела; G — положить"}

## Сколько ждать материализации item'а до авто-захвата (локальный fetch + активация realm).
const GRAB_TIMEOUT := 5.0

var _manager: GrabManager = null
var _slot2_index := -1                 # -1 — слот пуст; иначе индекс в SLOT2_CYCLE
var _slot_objects: Dictionary = {}     # слот (int) -> id объекта vrweb-item
var _pending_grabs: Dictionary = {}    # id объекта -> дедлайн ожидания авто-захвата (msec)


func _ready() -> void:
	add_to_group("item_toolbelt")


func setup(manager: GrabManager) -> void:
	_manager = manager


## Хоткей слота (зовёт Player). Слот 2 — цикл, слот 3 — тумблер; чужой хоткей сначала
## убирает предмет другого слота (в руке место одно).
func handle_slot(action: StringName) -> void:
	match action:
		&"tool_slot_2":
			_clear_slot(3)
			_slot2_index += 1
			_clear_slot(2)
			if _slot2_index >= SLOT2_CYCLE.size():
				_slot2_index = -1
				status_hint.emit("Инструмент убран")
				return
			_spawn(2, SLOT2_CYCLE[_slot2_index])
		&"tool_slot_3":
			_clear_slot(2)
			_slot2_index = -1
			if _slot_objects.has(3):
				_clear_slot(3)
				status_hint.emit("Инструмент убран")
			else:
				_spawn(3, SLOT3_ITEM)


func _spawn(slot: int, item: Dictionary) -> void:
	if _manager == null or not is_instance_valid(_manager):
		return
	# Рука одна: держимый предмет (в т.ч. не-инструмент) отпускаем перед спавном.
	if _manager.local_held() != null:
		_manager.release_held()
	var id := NetworkManager.new_object_id()
	var position := _spawn_position()
	NetworkManager.request_scene_action({"op": SceneChanges.OP_ADD, "id": id,
		"kind": "vrweb-item", "parent": "", "ttl": 0.0,
		"props": {"src": str(item.get("src", "")),
			"position": [position.x, position.y, position.z]}})
	_slot_objects[slot] = id
	_pending_grabs[id] = Time.get_ticks_msec() + int(GRAB_TIMEOUT * 1000)
	status_hint.emit(str(item.get("hint", "")))


## Убрать предмет слота: отпустить, если в руке, и снять объект слоя (вместе с realm).
func _clear_slot(slot: int) -> void:
	var id = _slot_objects.get(slot)
	if id == null:
		return
	_slot_objects.erase(slot)
	_pending_grabs.erase(id)
	var held := _manager.local_held() if _manager != null else null
	if held != null and held.grab_id.begins_with("item-%s." % id):
		_manager.release_held()
	NetworkManager.request_scene_action({"op": SceneChanges.OP_REMOVE, "id": str(id)})


## Материализация item'а асинхронна (fetch документа) — ждём появления его grabbable и
## берём в руку. Не дождались (битый src, потолок realm'ов) — просто перестаём ждать,
## объект остаётся лежать/отсутствовать.
func _process(_delta: float) -> void:
	if _pending_grabs.is_empty() or _manager == null:
		return
	var now := Time.get_ticks_msec()
	for id in _pending_grabs.keys():
		var g := _find_item_grabbable(str(id))
		if g != null:
			_pending_grabs.erase(id)
			_manager.request_grab(g)
		elif now > int(_pending_grabs[id]):
			_pending_grabs.erase(id)
			Log.warn("toolbelt", "item «%s» не материализовался — авто-захват отменён" % id)


func _find_item_grabbable(object_id: String) -> Grabbable:
	var prefix := "item-%s." % object_id
	for node in get_tree().get_nodes_in_group(Grabbable.GROUP):
		if node is Grabbable and (node as Grabbable).grab_id.begins_with(prefix):
			return node
	return null


## Точка спавна предмета — перед игроком (предмет тут же уедет в руку авто-захватом).
func _spawn_position() -> Vector3:
	var player := _manager.player() if _manager != null else null
	if player != null:
		var base := player.global_transform
		return base.origin - base.basis.z * 1.0 + Vector3(0, 1.2, 0)
	return Vector3(0, 1.2, 0)
