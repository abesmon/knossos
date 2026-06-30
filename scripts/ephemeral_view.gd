class_name EphemeralView
extends Node3D

## Материализует эфемерную сцену (NetworkManager) в 3D-объекты. Живёт внутри world (как
## RemotePlayersView): при навигации world сносится вместе с объектами, вьюха пересоздаётся для
## новой комнаты. main создаёт её в _rebuild_world и передаёт колбэк активации переходов (тот же
## _activate_transition, что у порталов).
##
## Реагирует на ГРАНУЛЯРНЫЕ сигналы транспорта (add/update/remove/reset) — не пересобирает всё на
## каждое изменение. Объекты — плоские данные { id, kind, parent, author, ts, ttl, props };
## вьюха материализует их по kind, не зная транспорта. Вложенность: объект с parent=<id> другого
## объекта монтируется как ребёнок его узла (наследует трансформ). Сейчас единственный kind —
## "bubble". Подробно — в docs/ephemeral-changes.md.

const BUBBLE := preload("res://actors/bubble/bubble.tscn")

var _activate_cb: Callable
var _nodes := {}   # id (String) -> Node3D


## activate_cb(transition: Dictionary) — обработчик переходов кликабельных объектов (пузырей),
## маршрутится в main._activate_transition.
func setup(activate_cb: Callable) -> void:
	_activate_cb = activate_cb
	NetworkManager.scene_object_added.connect(_on_added)
	NetworkManager.scene_object_updated.connect(_on_updated)
	NetworkManager.scene_object_removed.connect(_on_removed)
	NetworkManager.scene_reset.connect(_on_reset)
	_rebuild_all()   # состояние могло уже быть наполнено снимком до создания вьюхи


func _exit_tree() -> void:
	if NetworkManager.scene_object_added.is_connected(_on_added):
		NetworkManager.scene_object_added.disconnect(_on_added)
		NetworkManager.scene_object_updated.disconnect(_on_updated)
		NetworkManager.scene_object_removed.disconnect(_on_removed)
		NetworkManager.scene_reset.disconnect(_on_reset)


# --- Реакция на сигналы транспорта ---

func _on_added(id: String, object: Dictionary) -> void:
	_spawn(id, object)


func _on_updated(id: String, object: Dictionary) -> void:
	var node: Node3D = _nodes.get(id)
	if node == null:
		_spawn(id, object)   # не видели add (например, пришли мид-стрим) — создаём
		return
	# Сменился родитель — перемонтируем под новый узел; иначе обновляем на месте.
	if node.get_meta("parent_ref", "") != str(object.get("parent", "")):
		_reparent(node, object)
	_apply(node, object)


func _on_removed(id: String) -> void:
	var node: Node3D = _nodes.get(id)
	# Узел мог уже уйти Godot-стороной вместе с родителем (каскад) — снимаем ссылку.
	if is_instance_valid(node):
		node.queue_free()
	_nodes.erase(id)


func _on_reset() -> void:
	_rebuild_all()


# --- Построение ---

func _rebuild_all() -> void:
	for id in _nodes.keys():
		var n: Node = _nodes[id]
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	# Стабильный порядок не гарантирует, что родитель раньше ребёнка → _parent_for создаёт узел
	# под корнем, а второй проход не нужен: вложенность визуально доедет при следующем update/refresh.
	# Но чтобы дети сразу попали под родителей, монтируем в два прохода (родители первыми по глубине).
	var objects := NetworkManager.scene_objects()
	for id in _ordered_by_depth(objects):
		_spawn(id, objects[id])


## Порядок id по глубине родителя (корневые первыми) — чтобы при сборке узел родителя уже
## существовал к моменту монтажа ребёнка.
func _ordered_by_depth(objects: Dictionary) -> Array:
	var depth := {}
	for id in objects.keys():
		depth[id] = _depth_of(id, objects)
	var ids := objects.keys()
	ids.sort_custom(func(a, b): return depth[a] < depth[b])
	return ids


func _depth_of(id: String, objects: Dictionary, guard := 0) -> int:
	var parent := str(objects[id].get("parent", ""))
	if parent == "" or not objects.has(parent) or guard > 64:
		return 0
	return 1 + _depth_of(parent, objects, guard + 1)


func _spawn(id: String, object: Dictionary) -> void:
	if _nodes.has(id):
		return
	var node := _make_node(object)
	if node == null:
		return
	node.set_meta("parent_ref", str(object.get("parent", "")))
	_nodes[id] = node
	_parent_for(object).add_child(node)
	_apply(node, object)


## Узел-родитель для монтажа: если parent=<id> другого объекта и его узел есть — он; иначе корень
## вьюхи (root мира, "" или page:<…> пока резолвится в корень — якорь к узлу страницы будет позже).
func _parent_for(object: Dictionary) -> Node:
	var parent := str(object.get("parent", ""))
	var pnode: Node3D = _nodes.get(parent)
	return pnode if pnode != null else self


func _reparent(node: Node3D, object: Dictionary) -> void:
	var new_parent := _parent_for(object)
	if node.get_parent() == new_parent:
		return
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	node.set_meta("parent_ref", str(object.get("parent", "")))


## Применяет данные объекта к узлу: трансформ (позиция из props) — забота вьюхи; визуал по kind —
## забота узла (setup_object). Зовётся и при создании, и при update.
func _apply(node: Node3D, object: Dictionary) -> void:
	var props: Dictionary = object.get("props", {})
	if props.has("position"):
		node.position = _to_vec3(props["position"])
	if node.has_method("setup_object"):
		node.setup_object(object)


func _make_node(object: Dictionary) -> Node3D:
	match str(object.get("kind", "")):
		"bubble":
			var bubble := BUBBLE.instantiate()
			if _activate_cb.is_valid():
				bubble.activated.connect(_activate_cb)
			return bubble
	return null


## [x,y,z] -> Vector3 (объекты хранят позиции как массивы ради JSON-сериализуемости).
static func _to_vec3(arr) -> Vector3:
	if typeof(arr) == TYPE_ARRAY and arr.size() == 3:
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO
