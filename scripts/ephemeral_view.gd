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
## объекта монтируется как ребёнок его узла (наследует трансформ); parent="page:<node_id>" —
## как ребёнок РЕАЛЬНОГО узла vrweb-слоя страницы (реестр targets из main).
##
## Kind'ы: "bubble" (портал-метка), "stroke" (штрих карандаша) и оверлей vrweb
## (см. docs/space-console.md):
##   "vrweb-node"  — добавленный узел сцены: строится VrwebBuilder.build_element;
##   "vrweb-patch" — правка узла СТРАНИЦЫ (id "vpatch:<node_id>"): применяет props.set к живому
##                   узлу (с запоминанием оригиналов для отката), props.removed скрывает его.
## Подробно — в docs/ephemeral-changes.md.

const BUBBLE := preload("res://actors/bubble/bubble.tscn")
const STROKE := preload("res://actors/stroke/stroke.tscn")

var _activate_cb: Callable
var _nodes := {}           # id (String) -> Node (объектные kind'ы; патчи сюда не попадают)
var _targets := {}         # node_id страницы -> Object (узлы/ресурсы vrweb; реестр из main)
var _resources := {}       # id -> Resource (суб-ресурсы страницы для резолва ссылок)
var _base_url := ""
var _patched := {}         # patch id -> { target: Object, originals: {prop: Variant} }


## activate_cb(transition) — обработчик переходов кликабельных объектов (маршрут в
## main._activate_transition). vrweb — привязка к слою страницы:
## { targets: {node_id -> Object}, resources: {id -> Resource}, base_url: String }.
func setup(activate_cb: Callable, vrweb: Dictionary = {}) -> void:
	_activate_cb = activate_cb
	_targets = vrweb.get("targets", {})
	_resources = vrweb.get("resources", {})
	_base_url = str(vrweb.get("base_url", ""))
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
	if str(object.get("kind", "")) == SceneHtml.KIND_PATCH:
		_apply_patch(id, object)
		return
	_spawn(id, object)


func _on_updated(id: String, object: Dictionary) -> void:
	if str(object.get("kind", "")) == SceneHtml.KIND_PATCH:
		_apply_patch(id, object)
		return
	var node: Node = _nodes.get(id)
	if node == null:
		_spawn(id, object)   # не видели add (например, пришли мид-стрим) — создаём
		return
	# Сменился родитель — перемонтируем под новый узел; иначе обновляем на месте.
	if node.get_meta("parent_ref", "") != str(object.get("parent", "")):
		_reparent(node, object)
	_apply(node, object)


func _on_removed(id: String) -> void:
	if _patched.has(id):
		_revert_patch(id)
		return
	var node: Node = _nodes.get(id)
	# Узел мог уже уйти Godot-стороной вместе с родителем (каскад) — снимаем ссылку.
	if is_instance_valid(node):
		node.queue_free()
	_nodes.erase(id)


func _on_reset() -> void:
	_rebuild_all()


# --- Построение ---

func _rebuild_all() -> void:
	for id in _patched.keys():
		_revert_patch(id)
	for id in _nodes.keys():
		var n: Node = _nodes[id]
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	# Монтируем в порядке глубины родителя (родители первыми), чтобы к моменту монтажа
	# ребёнка узел родителя уже существовал.
	var objects := NetworkManager.scene_objects()
	for id in _ordered_by_depth(objects):
		var object: Dictionary = objects[id]
		if str(object.get("kind", "")) == SceneHtml.KIND_PATCH:
			_apply_patch(str(id), object)
		else:
			_spawn(str(id), object)


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
	# Дедупликация персистенции: vrweb-node, чей id уже есть среди узлов СТРАНИЦЫ, — его же
	# запечённая флашем копия (занять id из базы новым add нельзя — reserved_ids в SceneChanges).
	# База уже построила узел — второй раз не строим; у пиров со старой базой объект строится
	# как раньше. См. docs/page-persistence.md («Дедупликация»).
	if str(object.get("kind", "")) == SceneHtml.KIND_NODE and _targets.has(id):
		return
	var node := _make_node(object)
	if node == null:
		return
	node.set_meta("parent_ref", str(object.get("parent", "")))
	_nodes[id] = node
	_parent_for(object).add_child(node)
	_apply(node, object)


## Узел-родитель для монтажа: parent=<id> другого объекта — его узел; parent="page:<node_id>" —
## реальный узел vrweb-слоя страницы (реестр _targets); иначе корень вьюхи (root мира).
func _parent_for(object: Dictionary) -> Node:
	var parent := str(object.get("parent", ""))
	if parent.begins_with(SceneChanges.PAGE_PREFIX):
		var t = _targets.get(parent.substr(SceneChanges.PAGE_PREFIX.length()))
		return t if t is Node else self
	var pnode: Node = _nodes.get(parent)
	return pnode if pnode != null else self


func _reparent(node: Node, object: Dictionary) -> void:
	var new_parent := _parent_for(object)
	if node.get_parent() == new_parent:
		return
	node.get_parent().remove_child(node)
	new_parent.add_child(node)
	node.set_meta("parent_ref", str(object.get("parent", "")))


## Применяет данные объекта к узлу: трансформ (позиция из props) — забота вьюхи; визуал по kind —
## забота узла (setup_object). Зовётся и при создании, и при update. Для vrweb-node вместо этого
## накатываются сырые атрибуты (как при сборке страницы). Ключи, УБРАННЫЕ из attrs при update,
## остаются с прежними значениями — принятое упрощение (см. docs/space-console.md).
func _apply(node: Node, object: Dictionary) -> void:
	var props: Dictionary = object.get("props", {})
	if str(object.get("kind", "")) == SceneHtml.KIND_NODE:
		var attrs: Dictionary = props.get("attrs", {})
		for k in attrs:
			node.set(str(k), VrwebBuilder.resolve_attr_value(str(attrs[k]), _resources))
		return
	if props.has("position") and node is Node3D:
		node.position = _to_vec3(props["position"])
	if node.has_method("setup_object"):
		node.setup_object(object)


func _make_node(object: Dictionary) -> Node:
	match str(object.get("kind", "")):
		"bubble":
			var bubble := BUBBLE.instantiate()
			if _activate_cb.is_valid():
				bubble.activated.connect(_activate_cb)
			return bubble
		"stroke":
			# Штрих карандаша: один меш-труба по точкам (см. StrokeActor). Не кликабелен —
			# колбэк активации не нужен; данные ставит вьюха через setup_object в _apply.
			return STROKE.instantiate()
		SceneHtml.KIND_NODE:
			# Добавленный узел vrweb-слоя: строится тем же путём, что узлы страницы
			# (тот же принятый ClassDB-риск, см. docs/vrweb-tags.md). Дети приходят
			# отдельными объектами и монтируются обычной вложенностью.
			var props: Dictionary = object.get("props", {})
			return VrwebBuilder.build_element(str(props.get("tag", "")),
				props.get("attrs", {}), _resources, _base_url)
	return null


# --- Патчи узлов страницы (kind="vrweb-patch") ---

## Накатывает патч на живой узел страницы: props.set — оверрайды свойств (оригиналы
## запоминаются для отката), props.removed — скрыть узел (вместе с поддеревом). Update
## replace-семантикой: оверрайды, ушедшие из set, откатываются к оригиналу.
func _apply_patch(id: String, object: Dictionary) -> void:
	var target = _targets.get(id.trim_prefix(SceneHtml.PATCH_PREFIX))
	if target == null or not is_instance_valid(target):
		return   # узла нет у этой страницы (или патч приехал раньше мира) — флаш-онли
	var props: Dictionary = object.get("props", {})
	var set_map: Dictionary = props.get("set", {})
	var rec: Dictionary = _patched.get(id, {"target": target, "originals": {}})
	var originals: Dictionary = rec["originals"]
	# Откатываем оверрайды, которых больше нет в set (replace-семантика патча).
	for prop in originals.keys():
		if prop != "__visible" and not set_map.has(prop):
			target.set(prop, originals[prop])
			originals.erase(prop)
	for k in set_map:
		var prop := str(k)
		if not originals.has(prop):
			originals[prop] = target.get(prop)
		target.set(prop, VrwebBuilder.resolve_attr_value(str(set_map[k]), _resources))
	# removed: скрываем и выключаем обработку (вместе с физикой поддерева); откат — восстановление.
	var removed: bool = props.get("removed", false)
	if target is Node:
		var node := target as Node
		if removed and not originals.has("__visible"):
			originals["__visible"] = node.get("visible")
			node.set("visible", false)
			node.process_mode = Node.PROCESS_MODE_DISABLED
		elif not removed and originals.has("__visible"):
			node.set("visible", originals["__visible"])
			node.process_mode = Node.PROCESS_MODE_INHERIT
			originals.erase("__visible")
	rec["originals"] = originals
	_patched[id] = rec


## Снятие патча: все тронутые свойства возвращаются к оригиналам страницы.
func _revert_patch(id: String) -> void:
	var rec: Dictionary = _patched.get(id, {})
	_patched.erase(id)
	var target = rec.get("target")
	if target == null or not is_instance_valid(target):
		return
	var originals: Dictionary = rec.get("originals", {})
	for prop in originals:
		if prop == "__visible":
			target.set("visible", originals[prop])
			if target is Node:
				(target as Node).process_mode = Node.PROCESS_MODE_INHERIT
		else:
			target.set(prop, originals[prop])


## [x,y,z] -> Vector3 (объекты хранят позиции как массивы ради JSON-сериализуемости).
static func _to_vec3(arr) -> Vector3:
	if typeof(arr) == TYPE_ARRAY and arr.size() == 3:
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO
