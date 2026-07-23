class_name SceneChanges
extends RefCounted

const PolicyEvaluatorImpl = preload("res://scripts/network/policy_evaluator.gd")

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
##   { id, kind, parent, bindings:{creator:user_id}, ts, ttl, props }
##   parent: "" — корень мира | "<id>" — другой объект | "page:<nodeId>" — узел дерева страницы.

# --- Операции протокола ---
const OP_ADD := "add"
const OP_UPDATE := "update"
const OP_REMOVE := "remove"
const OP_REPARENT := "reparent"
const OP_UPDATE_CONFIG := "update-config"

# --- Конфигурация инстанса (не объекты и не persistence delta) ---
const CONFIG_MODE := "mode"
const MODE_COMBINE := "combine"
const MODE_EXCLUSIVE := "exclusive"

const PARENT_ROOT := ""
const PAGE_PREFIX := "page:"   # parent="page:<nodeId>" — якорь к узлу HTML-дерева страницы

# --- Лимиты политики (защита от спама/вечных объектов) ---
const MAX_OBJECTS := 256
const MAX_TTL := 600.0
const MAX_PROPS_BYTES := 8192   # грубый потолок размера props одного объекта

# --- Результат применения события (для followers) ---
enum Apply { APPLIED, IGNORED, GAP }

## Зарезервированные адреса — id узлов vrweb-слоя СТРАНИЦЫ (заполняет транспорт из индекса
## базы): add с таким id отклоняется, как и с занятым. Гарантия дедупликации персистенции:
## объект слоя с id из базы мог появиться единственным путём — это его же запечённая копия
## (см. docs/page-persistence.md, «Дедупликация»). Плоские данные, протокол не меняется.
var reserved_ids := {}

var _objects := {}        # id -> object (Dictionary)
var _config := {"attrs": {}, "by": ""} # allowlisted root attrs <vrwml>, состояние инстанса
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
##   sender_can_config — право менять корневую конфигурацию инстанса (сейчас rank <= 0)
func authority_commit(action: Dictionary, sender_user_id: String, sender_is_admin: bool,
		now: float, sender_can_config := false) -> Array:
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
		OP_UPDATE_CONFIG:
			return _commit_update_config(action, sender_user_id, sender_can_config)
	return []


## Корневая конфигурация не имеет object id/bindings: это единое состояние комнаты.
## Сейчас allowlist состоит только из mode; null снимает override и возвращает значение страницы.
func _commit_update_config(action: Dictionary, sender_user_id: String, can_config: bool) -> Array:
	if not can_config:
		return []
	var normalized := _normalize_config_patch(action.get("set", null))
	if not normalized.get("ok", false):
		return []
	var patch: Dictionary = normalized["set"]
	var attrs: Dictionary = _config["attrs"]
	var changed := false
	for key in patch:
		if patch[key] == null:
			changed = changed or attrs.has(key)
		else:
			changed = changed or not attrs.has(key) or attrs[key] != patch[key]
	if not changed:
		return []
	_apply_config_patch(patch, sender_user_id)
	return [_emit(OP_UPDATE_CONFIG, {"set": patch.duplicate(true), "by": sender_user_id})]


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


func _commit_add(action: Dictionary, creator: String, _is_admin: bool, now: float) -> Array:
	var id := str(action.get("id", ""))
	if id == "" or _objects.has(id) or reserved_ids.has(id):
		return []   # пустой id, занятый (анти-хайджек) или зарезервированный базой страницы
	if _objects.size() >= MAX_OBJECTS:
		return []
	var kind := str(action.get("kind", ""))
	if kind == "":
		return []
	var parent := str(action.get("parent", PARENT_ROOT))
	if not _parent_valid(parent):
		return []
	if not _can_add_into(parent, creator, _is_admin):
		return []
	var props = action.get("props", {})
	if typeof(props) != TYPE_DICTIONARY or not _props_ok(props):
		return []
	var ttl := float(action.get("ttl", 0.0))
	if ttl < 0.0 or ttl > MAX_TTL:
		return []
	var bindings := {"creator": creator} if not creator.is_empty() else {}
	var obj := {
		"id": id, "kind": kind, "parent": parent, "bindings": bindings,
		"ts": now, "ttl": ttl, "props": (props as Dictionary).duplicate(true),
	}
	_objects[id] = obj
	return [_emit(OP_ADD, {"id": id, "kind": kind, "parent": parent,
			"bindings": bindings.duplicate(true), "ts": now, "ttl": ttl,
			"props": obj["props"].duplicate(true)})]


func _commit_update(action: Dictionary, sender: String, is_admin: bool) -> Array:
	var id := str(action.get("id", ""))
	if not _objects.has(id):
		return []
	if not _can_control(_objects[id], sender, is_admin):
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
	if not _can_control(_objects[id], sender, is_admin):
		return []
	return _do_remove_cascade(id)


func _commit_reparent(action: Dictionary, sender: String, is_admin: bool) -> Array:
	var id := str(action.get("id", ""))
	if not _objects.has(id):
		return []
	if not _can_control(_objects[id], sender, is_admin):
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
	if str(event.get("op", "")) == OP_UPDATE_CONFIG:
		var normalized := _normalize_config_patch(event.get("set", null))
		# Даже некорректное событие от transport-authority занимает свой seq: локально оно не
		# влияет на config, но и не превращает весь последующий поток в вечный GAP.
		_seq = e_seq
		if not normalized.get("ok", false):
			return Apply.IGNORED
		_apply_config_patch(normalized["set"], str(event.get("by", "")))
		return Apply.APPLIED
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
				"bindings": (event.get("bindings", {}) as Dictionary).duplicate(true),
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
	return {"epoch": _epoch, "seq": _seq, "objects": _objects.duplicate(true),
		"config": _config.duplicate(true)}


func load_snapshot(snap: Dictionary) -> void:
	if typeof(snap) != TYPE_DICTIONARY:
		return
	var objs = snap.get("objects", {})
	_objects = (objs as Dictionary).duplicate(true) if typeof(objs) == TYPE_DICTIONARY else {}
	_config = {"attrs": {}, "by": ""}
	var incoming_config = snap.get("config", {})
	if typeof(incoming_config) == TYPE_DICTIONARY:
		var attrs = incoming_config.get("attrs", {})
		var normalized := _normalize_config_snapshot(attrs)
		if normalized.get("ok", false):
			_config = {"attrs": normalized["attrs"], "by": str(incoming_config.get("by", ""))}
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


## Эффективные override-атрибуты корня (без значений базовой страницы).
func config_attrs() -> Dictionary:
	return (_config["attrs"] as Dictionary).duplicate(true)


func config() -> Dictionary:
	return _config.duplicate(true)


func epoch() -> int:
	return _epoch


# ============================================================================
#  Права: общая policy проверяет binding creator либо явный moderator override транспорта.
# ============================================================================

## Назначен ли actor creator объекта (или имеет moderator override).
func _can_control(obj: Dictionary, sender_user_id: String, is_admin: bool) -> bool:
	return PolicyEvaluatorImpl.evaluate({"any_of": [
		{"assigned": "creator"}, {"rank": {"op": "lte", "value": 0}},
	]}, {"actor_user_id": sender_user_id, "rank": 0 if is_admin else 1 << 30,
		"bindings": obj.get("bindings", {})})


## Можно ли добавить ребёнка в данного родителя. Корень и узлы страницы — открыты; вложение в
## ЧУЖОЙ эфемерный объект — только владельцу того объекта или админу.
func _can_add_into(parent: String, sender_user_id: String, is_admin: bool) -> bool:
	if parent == PARENT_ROOT or parent.begins_with(PAGE_PREFIX):
		return true
	if not _objects.has(parent):
		return false
	return _can_control(_objects[parent], sender_user_id, is_admin)


# --- Валидаторы структуры ---

func _parent_valid(parent: String) -> bool:
	if parent == PARENT_ROOT or parent.begins_with(PAGE_PREFIX):
		return true
	return _objects.has(parent)


func _props_ok(props: Dictionary) -> bool:
	# Грубая оценка размера через JSON — заодно гарантия, что props сериализуемы.
	return JSON.stringify(props).length() <= MAX_PROPS_BYTES


## Валидация patch корневой конфигурации. Возвращаем структуру с ok, чтобы отличить
## корректный пустой результат от отказа. V1: единственный ключ mode, null = снять override.
func _normalize_config_patch(value) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY or (value as Dictionary).is_empty():
		return {"ok": false}
	var out := {}
	for raw_key in (value as Dictionary).keys():
		var key := str(raw_key)
		if key != CONFIG_MODE:
			return {"ok": false}
		var raw = value[raw_key]
		if raw == null:
			out[key] = null
			continue
		var mode := str(raw).to_lower()
		if mode != MODE_COMBINE and mode != MODE_EXCLUSIVE:
			return {"ok": false}
		out[key] = mode
	return {"ok": true, "set": out}


## Snapshot хранит итоговые attrs, поэтому null в нём недопустим.
func _normalize_config_snapshot(value) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {"ok": false}
	if (value as Dictionary).is_empty():
		return {"ok": true, "attrs": {}}
	var normalized := _normalize_config_patch(value)
	if not normalized.get("ok", false):
		return {"ok": false}
	for v in (normalized["set"] as Dictionary).values():
		if v == null:
			return {"ok": false}
	return {"ok": true, "attrs": (normalized["set"] as Dictionary).duplicate(true)}


func _apply_config_patch(patch: Dictionary, by: String) -> void:
	var attrs: Dictionary = _config["attrs"]
	for key in patch:
		if patch[key] == null:
			attrs.erase(key)
		else:
			attrs[key] = patch[key]
	_config["by"] = by


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
