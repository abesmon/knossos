class_name SceneChanges
extends RefCounted

## Движок-агностичный слой эфемерных изменений сцены: ЧИСТАЯ машина состояний + контракт
## протокола. Не знает про Godot-сцену, 3D, RPC, WebRTC — оперирует только плоскими данными
## (Dictionary/Array примитивов), чтобы тот же контракт могла реализовать не-Godot сторона.
## Транспорт и материализацию делает код выше (NetworkManager, EphemeralView).
## Полное описание протокола — в docs/ephemeral-changes.md.
##
## Модель — команда/событие (command/event sourcing):
##   • Инициатор шлёт АВТОРИТЕТУ ДЕЙСТВИЕ (action) — намерение «добавь/измени/удали/перемести».
##     Действие описывает ТОЛЬКО нужную мутацию и НЕ претендует на состояние.
##   • Авторитет — единственная точка сериализации: валидирует против СВОЕГО состояния и прав,
##     присваивает порядковый номер (epoch, seq), мутирует состояние и рассылает СОБЫТИЕ (event).
##   • Все применяют события строго по порядку. Рассинхрон у инициатора не ломает валидацию:
##     авторитет проверяет своё состояние, а не заявленное инициатором.
##
## Объект состояния (плоский, JSON-сериализуемый):
##   { id, kind, parent, author, ts, ttl, props }
##   parent: "" — корень мира | "<id>" — другой объект | "page:<nodeId>" — узел дерева страницы.

# --- Операции протокола ---
const OP_ADD := "add"
const OP_UPDATE := "update"
const OP_REMOVE := "remove"
const OP_REPARENT := "reparent"

const PARENT_ROOT := ""
const PAGE_PREFIX := "page:"   # parent="page:<nodeId>" — якорь к узлу HTML-дерева страницы

# --- Лимиты политики (защита от спама/вечных объектов) ---
const MAX_OBJECTS := 256
const MAX_TTL := 600.0
const MAX_PROPS_BYTES := 8192   # грубый потолок размера props одного объекта

# --- Результат применения события (для followers) ---
enum Apply { APPLIED, IGNORED, GAP }

var _objects := {}        # id -> object (Dictionary)
var _epoch := 0           # эпоха авторитета (растёт при смене авторитета)
var _seq := 0             # порядковый в пределах эпохи (последний применённый/выданный)
var _last_seen_epoch := 0 # max эпоха, что мы вообще видели — для begin_authority


# ============================================================================
#  Сторона АВТОРИТЕТА: валидация действия и коммит в события
# ============================================================================

## Стать авторитетом: поднять эпоху строго выше всего виденного и обнулить seq, чтобы наши
## события были заведомо новее любых прошлых. Состояние (_objects) сохраняется — преемник
## продолжает с тёплой копии. Зовётся, когда роль авторитета переходит к нам.
func begin_authority() -> void:
	_epoch = _last_seen_epoch + 1
	_seq = 0


## Авторитет: провалидировать действие против СВОЕГО состояния и прав, применить и вернуть
## УПОРЯДОЧЕННЫЙ список событий для рассылки (пусто = отклонено). Транзакция (каскадное удаление)
## выражается несколькими атомарными событиями. Мутирует состояние.
##   action            — намерение инициатора { op, id, kind?, parent?, props?, ttl? }
##   sender_user_id    — стабильный id инициатора (авторитет доверяет ему как источнику)
##   sender_is_admin   — есть ли у инициатора админ-право (обходит проверку владения)
##   now               — настенные часы авторитета (штамп ts)
func authority_commit(action: Dictionary, sender_user_id: String, sender_is_admin: bool, now: float) -> Array:
	if typeof(action) != TYPE_DICTIONARY:
		return []
	match str(action.get("op", "")):
		OP_ADD:
			return _commit_add(action, sender_user_id, sender_is_admin, now)
		OP_UPDATE:
			return _commit_update(action, sender_user_id, sender_is_admin)
		OP_REMOVE:
			return _commit_remove(action, sender_user_id, sender_is_admin)
		OP_REPARENT:
			return _commit_reparent(action, sender_user_id, sender_is_admin)
	return []


## Авторитет: истечь объекты с прошедшим TTL (каскадно с детьми) и вернуть события удаления.
func expire(now: float) -> Array:
	var events: Array = []
	for id in _objects.keys():
		if not _objects.has(id):
			continue  # мог быть снят каскадом на этой же итерации
		var obj: Dictionary = _objects[id]
		var ttl := float(obj.get("ttl", 0.0))
		if ttl > 0.0 and now - float(obj.get("ts", now)) >= ttl:
			events.append_array(_do_remove_cascade(id))
	return events


func _commit_add(action: Dictionary, author: String, _is_admin: bool, now: float) -> Array:
	var id := str(action.get("id", ""))
	if id == "" or _objects.has(id):
		return []   # пустой id или попытка занять существующий (анти-хайджек)
	if _objects.size() >= MAX_OBJECTS:
		return []
	var kind := str(action.get("kind", ""))
	if kind == "":
		return []
	var parent := str(action.get("parent", PARENT_ROOT))
	if not _parent_valid(parent):
		return []
	if not _can_add_into(parent, author, _is_admin):
		return []
	var props = action.get("props", {})
	if typeof(props) != TYPE_DICTIONARY or not _props_ok(props):
		return []
	var ttl := float(action.get("ttl", 0.0))
	if ttl < 0.0 or ttl > MAX_TTL:
		return []
	var obj := {
		"id": id, "kind": kind, "parent": parent, "author": author,
		"ts": now, "ttl": ttl, "props": (props as Dictionary).duplicate(true),
	}
	_objects[id] = obj
	return [_emit(OP_ADD, {"id": id, "kind": kind, "parent": parent, "author": author, "ts": now, "ttl": ttl, "props": obj["props"].duplicate(true)})]


func _commit_update(action: Dictionary, sender: String, is_admin: bool) -> Array:
	var id := str(action.get("id", ""))
	if not _objects.has(id):
		return []
	if not _owns(_objects[id], sender, is_admin):
		return []
	var patch = action.get("props", {})
	if typeof(patch) != TYPE_DICTIONARY:
		return []
	# Проверяем размер на КОПИИ до мутации — иначе отказ оставил бы состояние раздутым.
	var merged: Dictionary = _objects[id]["props"].duplicate(true)
	_apply_props_patch(merged, patch)
	if not _props_ok(merged):
		return []   # патч раздул props сверх лимита — отклоняем, состояние не тронуто
	_objects[id]["props"] = merged
	return [_emit(OP_UPDATE, {"id": id, "props": (patch as Dictionary).duplicate(true)})]


func _commit_remove(action: Dictionary, sender: String, is_admin: bool) -> Array:
	var id := str(action.get("id", ""))
	if not _objects.has(id):
		return []
	if not _owns(_objects[id], sender, is_admin):
		return []
	return _do_remove_cascade(id)


func _commit_reparent(action: Dictionary, sender: String, is_admin: bool) -> Array:
	var id := str(action.get("id", ""))
	if not _objects.has(id):
		return []
	if not _owns(_objects[id], sender, is_admin):
		return []
	var new_parent := str(action.get("parent", PARENT_ROOT))
	if not _parent_valid(new_parent):
		return []
	# Запрет цикла: новый родитель не должен быть самим объектом или его потомком.
	if new_parent == id or _is_descendant(new_parent, id):
		return []
	if not _can_add_into(new_parent, sender, is_admin):
		return []
	_objects[id]["parent"] = new_parent
	return [_emit(OP_REPARENT, {"id": id, "parent": new_parent})]


## Удалить объект и всех потомков. Возвращает события удаления: СНАЧАЛА потомки, ПОТОМ сам узел
## (получатель снимает листья раньше — никаких висячих ссылок). Мутирует состояние.
func _do_remove_cascade(id: String) -> Array:
	var events: Array = []
	for child_id in _children_of(id):
		events.append_array(_do_remove_cascade(child_id))
	if _objects.erase(id):
		events.append(_emit(OP_REMOVE, {"id": id}))
	return events


## Сформировать событие: проштамповать (epoch, seq) и op. fields — релевантные op поля.
func _emit(op: String, fields: Dictionary) -> Dictionary:
	_seq += 1
	var e := {"epoch": _epoch, "seq": _seq, "op": op}
	e.merge(fields)
	return e


# ============================================================================
#  Сторона ПОЛУЧАТЕЛЯ (follower): применение событий по порядку
# ============================================================================

## Применить событие от авторитета. Возвращает Apply: APPLIED — применили (вызывающий эмитит
## сигнал по op), IGNORED — устаревшее/дубликат (дроп), GAP — пропуск/новая эпоха (нужен ресинк
## снимком). Доверие к ОТПРАВИТЕЛЮ (что он авторитет) проверяет вызывающий до этого.
func apply_event(event: Dictionary) -> int:
	if typeof(event) != TYPE_DICTIONARY:
		return Apply.IGNORED
	var e_epoch := int(event.get("epoch", 0))
	var e_seq := int(event.get("seq", 0))
	if e_epoch > _last_seen_epoch:
		_last_seen_epoch = e_epoch
	if e_epoch < _epoch:
		return Apply.IGNORED        # из старой эпохи (запоздавший экс-авторитет)
	if e_epoch > _epoch:
		return Apply.GAP            # новая эпоха раньше снимка — ресинк
	if e_seq <= _seq:
		return Apply.IGNORED        # дубликат
	if e_seq != _seq + 1:
		return Apply.GAP            # пропуск в последовательности — ресинк
	_apply_op(event)
	_seq = e_seq
	return Apply.APPLIED


func _apply_op(event: Dictionary) -> void:
	var id := str(event.get("id", ""))
	match str(event.get("op", "")):
		OP_ADD:
			_objects[id] = {
				"id": id, "kind": str(event.get("kind", "")),
				"parent": str(event.get("parent", PARENT_ROOT)),
				"author": str(event.get("author", "")),
				"ts": float(event.get("ts", 0.0)), "ttl": float(event.get("ttl", 0.0)),
				"props": (event.get("props", {}) as Dictionary).duplicate(true),
			}
		OP_UPDATE:
			if _objects.has(id):
				_apply_props_patch(_objects[id]["props"], event.get("props", {}))
		OP_REPARENT:
			if _objects.has(id):
				_objects[id]["parent"] = str(event.get("parent", PARENT_ROOT))
		OP_REMOVE:
			_objects.erase(id)


# ============================================================================
#  Снимок (ресинк для новичка / при смене авторитета)
# ============================================================================

func snapshot() -> Dictionary:
	return {"epoch": _epoch, "seq": _seq, "objects": _objects.duplicate(true)}


func load_snapshot(snap: Dictionary) -> void:
	if typeof(snap) != TYPE_DICTIONARY:
		return
	var objs = snap.get("objects", {})
	_objects = (objs as Dictionary).duplicate(true) if typeof(objs) == TYPE_DICTIONARY else {}
	_epoch = int(snap.get("epoch", 0))
	_seq = int(snap.get("seq", 0))
	if _epoch > _last_seen_epoch:
		_last_seen_epoch = _epoch


# --- Доступ к состоянию (только чтение; копии) ---

func objects() -> Dictionary:
	return _objects.duplicate(true)


func get_object(id: String) -> Dictionary:
	var o = _objects.get(id, {})
	return (o as Dictionary).duplicate(true) if typeof(o) == TYPE_DICTIONARY else {}


func has_object(id: String) -> bool:
	return _objects.has(id)


func epoch() -> int:
	return _epoch


# ============================================================================
#  Права (ФУНДАМЕНТ). Сейчас: владение по author + админ-обход. Сюда же ляжет будущая
#  система прав (capabilities, политика по kind, пороги рангов). См. docs/ephemeral-changes.md.
# ============================================================================

## Владеет ли отправитель объектом (или он админ). Базово править/удалять можно только своё.
func _owns(obj: Dictionary, sender_user_id: String, is_admin: bool) -> bool:
	if is_admin:
		return true
	var author := str(obj.get("author", ""))
	return author != "" and author == sender_user_id


## Можно ли добавить ребёнка в данного родителя. Корень и узлы страницы — открыты; вложение в
## ЧУЖОЙ эфемерный объект — только владельцу того объекта или админу.
func _can_add_into(parent: String, sender_user_id: String, is_admin: bool) -> bool:
	if parent == PARENT_ROOT or parent.begins_with(PAGE_PREFIX):
		return true
	if not _objects.has(parent):
		return false
	return _owns(_objects[parent], sender_user_id, is_admin)


# --- Валидаторы структуры ---

func _parent_valid(parent: String) -> bool:
	if parent == PARENT_ROOT or parent.begins_with(PAGE_PREFIX):
		return true
	return _objects.has(parent)


func _props_ok(props: Dictionary) -> bool:
	# Грубая оценка размера через JSON — заодно гарантия, что props сериализуемы.
	return JSON.stringify(props).length() <= MAX_PROPS_BYTES


func _children_of(id: String) -> Array:
	var out: Array = []
	for cid in _objects.keys():
		if str(_objects[cid].get("parent", "")) == id:
			out.append(cid)
	return out


func _is_descendant(id: String, ancestor: String) -> bool:
	var cur := id
	var guard := 0
	while _objects.has(cur) and guard < MAX_OBJECTS:
		var p := str(_objects[cur].get("parent", PARENT_ROOT))
		if p == ancestor:
			return true
		cur = p
		guard += 1
	return false


## Мердж патча в props: ключ со значением null удаляет ключ, иначе перезаписывает (мелкий мердж).
func _apply_props_patch(props: Dictionary, patch) -> void:
	if typeof(patch) != TYPE_DICTIONARY:
		return
	for k in patch.keys():
		if patch[k] == null:
			props.erase(k)
		else:
			props[k] = patch[k]
