class_name SceneHtml
extends RefCounted

## HTML-представление эфемерного слоя сцены: блок <ephemeral> + дифф в действия протокола.
## ЧИСТЫЙ модуль (без сети/3D/Godot-сцены): сериализует плоское состояние SceneChanges
## (id -> { kind, parent, ttl, props }) в HTML, разбирает отредактированный блок обратно
## и вычисляет МИНИМАЛЬНЫЙ набор действий add/update/remove/reparent. Никакой реконструкции
## из геометрии: источник истины — журнал эфемерных изменений. Используется консолью
## пространства (docs/space-console.md, docs/ephemeral-changes.md).
##
## Формат элемента: <kind id="…" ttl="…" prop="…"/>. Вложенность элементов = parent-дерево
## объектов; якорь к узлу страницы (parent="page:<nodeId>") — атрибутом на верхнем уровне.

const TAG := "ephemeral"

## Тег единого документа сцены (слитый слой): vrweb страницы + эфемерные дельты поверх.
const SCENE_TAG := "vrwml"
const MODE_COMBINE := "combine"
const MODE_EXCLUSIVE := "exclusive"

## Kind'ы эфемерного ОВЕРЛЕЯ vrweb (дельты, из которых собирается слитый слой):
##   vrweb-node  — добавленный узел сцены: props { "tag": String, "attrs": {имя: raw-строка} }
##   vrweb-patch — правка/удаление УЗЛА СТРАНИЦЫ: props { "set": {имя: raw}, "removed": bool };
##                 id детерминированный "vpatch:<node_id>" — анти-хайджек протокола даром даёт
##                 «узел страницы одновременно правит один пользователь».
## Значения атрибутов vrweb всегда остаются СЫРЫМИ строками (литералы Godot) — модуль их не
## интерпретирует; типизация props (PROP_TYPES) относится только к мировым kind'ам.
const KIND_NODE := "vrweb-node"
const KIND_PATCH := "vrweb-patch"
const PATCH_PREFIX := "vpatch:"

## Типы известных props (имя атрибута -> тип): "vec" — массив чисел через пробел,
## "num" — число, "str" — строка. Неизвестные атрибуты разбираются эвристикой
## (см. _parse_prop_value). Новый kind с особыми props расширяет эту таблицу.
const PROP_TYPES := {
	"position": "vec", "points": "vec", "color": "vec",
	"width": "num", "url": "str", "label": "str",
}

## Атрибуты со структурной ролью — не props объекта.
const RESERVED_ATTRS := {"id": true, "ttl": true, "parent": true}

## Допуск сравнения чисел в диффе: сериализация пишет 4 знака (см. _fmt_num), всё что
## ближе — артефакт форматирования, а не правка пользователя.
const NUM_EPS := 0.001


# ============================================================================
#  Сериализация: состояние -> HTML-блок
# ============================================================================

## Собирает блок <ephemeral> из снимка состояния (id -> object). Порядок стабильный
## (по ts, затем id), вложенность — по parent. Объект с parent="page:…" или с висячим
## parent (родителя нет в снимке) выходит на верхний уровень с атрибутом parent.
static func serialize(objects: Dictionary) -> String:
	var kids := {}   # parent id ("" — верхний уровень) -> [ids]
	for id in objects.keys():
		var parent := str(objects[id].get("parent", ""))
		var key := parent if objects.has(parent) else ""
		if not kids.has(key):
			kids[key] = []
		kids[key].append(id)
	for key in kids:
		kids[key].sort_custom(func(a, b) -> bool:
			var ta := float(objects[a].get("ts", 0.0))
			var tb := float(objects[b].get("ts", 0.0))
			return ta < tb if ta != tb else str(a) < str(b))
	var lines: PackedStringArray = ["<%s>" % TAG]
	for id in kids.get("", []):
		_serialize_object(str(id), objects, kids, 1, lines)
	lines.append("</%s>" % TAG)
	return "\n".join(lines)


static func _serialize_object(id: String, objects: Dictionary, kids: Dictionary,
		indent: int, lines: PackedStringArray) -> void:
	var obj: Dictionary = objects[id]
	var pad := "  ".repeat(indent)
	var attrs := " id=\"%s\"" % HtmlNode.escape_attr(id)
	var ttl := float(obj.get("ttl", 0.0))
	if ttl > 0.0:
		attrs += " ttl=\"%s\"" % _fmt_num(ttl)
	# Якорь к узлу страницы (или висячий parent) не выражается вложенностью — атрибутом.
	var parent := str(obj.get("parent", ""))
	if parent != "" and not objects.has(parent):
		attrs += " parent=\"%s\"" % HtmlNode.escape_attr(parent)
	var props: Dictionary = obj.get("props", {})
	var names := props.keys()
	names.sort()
	for name in names:
		attrs += " %s=\"%s\"" % [name, HtmlNode.escape_attr(_fmt_prop_value(props[name]))]
	var child_ids: Array = kids.get(id, [])
	var kind := str(obj.get("kind", ""))
	if child_ids.is_empty():
		lines.append("%s<%s%s />" % [pad, kind, attrs])
		return
	lines.append("%s<%s%s>" % [pad, kind, attrs])
	for cid in child_ids:
		_serialize_object(str(cid), objects, kids, indent + 1, lines)
	lines.append("%s</%s>" % [pad, kind])


## Значение prop -> текст атрибута: массив чисел — через пробел, число — компактно,
## строка — как есть, прочее (Dictionary/bool/…) — JSON.
static func _fmt_prop_value(v) -> String:
	match typeof(v):
		TYPE_STRING:
			return v
		TYPE_FLOAT, TYPE_INT:
			return _fmt_num(float(v))
		TYPE_ARRAY:
			var parts: PackedStringArray = []
			for item in v:
				if typeof(item) == TYPE_FLOAT or typeof(item) == TYPE_INT:
					parts.append(_fmt_num(float(item)))
				else:
					return JSON.stringify(v)   # не числовой массив — честный JSON
			return " ".join(parts)
	return JSON.stringify(v)


## Число компактно: целое — без десятичной части, дробное — 4 знака (хвостовые нули
## String.num срезает сам).
static func _fmt_num(v: float) -> String:
	if v == floorf(v) and absf(v) < 1e15:
		return str(int(v))
	return String.num(v, 4)


# ============================================================================
#  Разбор: HTML-дерево -> записи объектов
# ============================================================================

## Достаёт записи объектов из блока <ephemeral> распарсенного документа.
## Возвращает { ok, error, entries }, где entries — Array[Dictionary] в порядке документа
## (pre-order: родитель всегда раньше ребёнка):
##   { id: String ("" — новый, без id), kind, ttl: float, props: Dictionary,
##     parent_entry: int (индекс записи-родителя или -1), parent: String (для -1: ""/page:…) }
## Ошибки структуры (нет блока, дубликат id) — отказ целиком: правка явно не то, что
## пользователь хотел отправить.
static func parse_block(root: HtmlNode) -> Dictionary:
	var block := root.find_descendant(TAG)
	if root.tag == TAG:
		block = root
	if block == null:
		return {"ok": false, "error": "нет блока <%s>" % TAG, "entries": []}
	var entries: Array = []
	var seen := {}
	var err := _parse_children(block, -1, entries, seen)
	if err != "":
		return {"ok": false, "error": err, "entries": []}
	return {"ok": true, "error": "", "entries": entries}


static func _parse_children(node: HtmlNode, parent_entry: int, entries: Array, seen: Dictionary) -> String:
	for c in node.children:
		if c.is_text():
			if c.text.strip_edges() != "":
				return "текст внутри <%s> не поддерживается: «%s»" % [TAG, c.text.strip_edges().left(40)]
			continue
		var id := c.get_attr("id").strip_edges()
		if id != "":
			if seen.has(id):
				return "дубликат id «%s»" % id
			seen[id] = true
		var props := {}
		for attr_name in c.attributes:
			if RESERVED_ATTRS.has(attr_name):
				continue
			props[attr_name] = _parse_prop_value(attr_name, str(c.attributes[attr_name]))
		var parent := ""
		if parent_entry == -1:
			parent = c.get_attr("parent").strip_edges()
		entries.append({
			"id": id,
			"kind": c.tag,
			"ttl": float(c.get_attr("ttl", "0")),
			"props": props,
			"parent_entry": parent_entry,
			"parent": parent,
		})
		var err := _parse_children(c, entries.size() - 1, entries, seen)
		if err != "":
			return err
	return ""


## Текст атрибута -> значение prop. Известные props — по таблице типов; неизвестные —
## эвристикой: число/JSON-массив/JSON-объект, иначе строка.
static func _parse_prop_value(name: String, text: String):
	match PROP_TYPES.get(name, ""):
		"str":
			return text
		"num":
			return text.to_float()
		"vec":
			return _parse_vec(text)
	# Неизвестный prop: пробуем как число, как список чисел, как JSON; иначе строка.
	if text.is_valid_float():
		return text.to_float()
	var stripped := text.strip_edges()
	if stripped.begins_with("[") or stripped.begins_with("{"):
		var parsed = JSON.parse_string(stripped)
		if parsed != null:
			return parsed
	if _looks_like_vec(stripped):
		return _parse_vec(stripped)
	return text


static func _parse_vec(text: String) -> Array:
	var out: Array = []
	for part in text.split(" ", false):
		out.append(part.to_float())
	return out


static func _looks_like_vec(s: String) -> bool:
	if s == "":
		return false
	var parts := s.split(" ", false)
	if parts.size() < 2:
		return false
	for p in parts:
		if not p.is_valid_float():
			return false
	return true


# ============================================================================
#  Дифф: (текущее состояние, отредактированные записи) -> действия протокола
# ============================================================================

## Сравнивает текущее состояние (id -> object) с записями из отредактированного блока и
## возвращает { ok, error, actions } — упорядоченный список действий протокола:
## add (родители раньше детей — порядок записей pre-order), reparent, update, remove.
## make_id — генератор id для новых объектов (NetworkManager.new_object_id).
## Неизменяемое протоколом (смена kind существующего id, правка ttl) — ошибка, а не
## тихий пропуск: пользователь должен знать, что именно не уедет.
static func diff(current: Dictionary, entries: Array, make_id: Callable) -> Dictionary:
	var actions: Array = []
	# 1. Раздаём id новым записям и резолвим parent каждой записи в строку протокола.
	var ids: Array = []           # индекс записи -> итоговый id
	var edited_ids := {}          # id -> индекс записи (для removes)
	for e in entries:
		var id: String = e["id"]
		if id == "":
			id = str(make_id.call())
		ids.append(id)
		edited_ids[id] = true
	var parents: Array = []       # индекс записи -> parent-строка протокола
	for i in entries.size():
		var e: Dictionary = entries[i]
		var pe := int(e["parent_entry"])
		parents.append(str(ids[pe]) if pe >= 0 else str(e["parent"]))

	# 2. add / reparent / update.
	for i in entries.size():
		var e: Dictionary = entries[i]
		var id: String = ids[i]
		if not current.has(id):
			actions.append({
				"op": SceneChanges.OP_ADD, "id": id, "kind": e["kind"],
				"parent": parents[i], "ttl": e["ttl"], "props": e["props"],
			})
			continue
		var obj: Dictionary = current[id]
		if str(obj.get("kind", "")) != str(e["kind"]):
			return _err("смена kind объекта «%s» (%s → %s) не поддерживается — удалите id, чтобы создать новый объект" % [id, obj.get("kind", ""), e["kind"]])
		if absf(float(obj.get("ttl", 0.0)) - float(e["ttl"])) > NUM_EPS:
			return _err("ttl объекта «%s» менять нельзя (истечение — забота авторитета)" % id)
		# reparent раньше update и remove: ребёнок, вынесенный из удаляемого родителя,
		# должен уехать до каскадного удаления.
		if parents[i] != str(obj.get("parent", "")):
			actions.append({"op": SceneChanges.OP_REPARENT, "id": id, "parent": parents[i]})
		var patch := _props_patch(obj.get("props", {}), e["props"])
		if not patch.is_empty():
			actions.append({"op": SceneChanges.OP_UPDATE, "id": id, "props": patch})

	# 3. remove: есть в состоянии, нет в правке. Потомков удаляемых пропускаем — авторитет
	# снимает их каскадно, а явный remove вслед за каскадом был бы отклонён (объекта уже нет).
	for id in current.keys():
		if edited_ids.has(id):
			continue
		if _ancestor_removed(str(id), current, edited_ids):
			continue
		actions.append({"op": SceneChanges.OP_REMOVE, "id": id})

	return {"ok": true, "error": "", "actions": actions}


static func _err(message: String) -> Dictionary:
	return {"ok": false, "error": message, "actions": []}


## Есть ли у объекта предок, который тоже удаляется (нет среди отредактированных id).
static func _ancestor_removed(id: String, current: Dictionary, edited_ids: Dictionary) -> bool:
	var cur := str(current[id].get("parent", ""))
	var guard := 0
	while current.has(cur) and guard < SceneChanges.MAX_OBJECTS:
		if not edited_ids.has(cur):
			return true
		cur = str(current[cur].get("parent", ""))
		guard += 1
	return false


## Патч props (мердж-семантика протокола): изменённые/новые ключи — значением,
## удалённые — null. Пустой словарь = нет изменений.
static func _props_patch(old: Dictionary, new: Dictionary) -> Dictionary:
	var patch := {}
	for k in new:
		if not old.has(k) or not _values_equal(old[k], new[k]):
			patch[k] = new[k]
	for k in old:
		if not new.has(k):
			patch[k] = null
	return patch


## Сравнение значений props с допуском по числам: round-trip через текст не должен
## порождать фантомные правки из-за форматирования float.
static func _values_equal(a, b) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if (ta == TYPE_FLOAT or ta == TYPE_INT) and (tb == TYPE_FLOAT or tb == TYPE_INT):
		return absf(float(a) - float(b)) <= NUM_EPS
	if ta == TYPE_ARRAY and tb == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _values_equal(a[i], b[i]):
				return false
		return true
	if ta != tb:
		return false
	return a == b


# ============================================================================
#  ЕДИНЫЙ ДОКУМЕНТ СЦЕНЫ: слитый <vrwml> (страница + эфемерный оверлей)
#  Пользователь редактирует сцену как одну сущность, не думая, что часть запечена в
#  страницу, а часть — эфемерная дельта. Наружу при сохранении уходит ТОЛЬКО дельта
#  (vrweb-node/vrweb-patch/мировые объекты). См. docs/space-console.md.
# ============================================================================

## Индекс узлов страницы из блока <vrwml> документа: каждому элементу — детерминированный
## id (авторский атрибут id, иначе структурный "n<путь>", напр. "n0-2") — одинаковый у всех
## пиров, т.к. страница детерминирована по URL. Возвращает:
##   { found, attrs (атрибуты самого блока), top: [id...],
##     nodes: { id -> { tag (raw), attrs: {имя: raw-строка, без id}, parent: id|"",
##              children: [id...], elem: HtmlNode } } }
static func build_page_index(doc: HtmlNode) -> Dictionary:
	var block := doc if doc.tag == SCENE_TAG else doc.find_descendant(SCENE_TAG)
	var index := {"found": block != null, "attrs": {}, "top": [], "nodes": {}}
	if block == null:
		return index
	index["attrs"] = block.attributes.duplicate()
	_index_children(block, "", [], index)
	return index


static func _index_children(elem: HtmlNode, parent_id: String, path: Array, index: Dictionary) -> void:
	var i := 0
	for c in elem.children:
		if c.is_text():
			continue
		var child_path := path.duplicate()
		child_path.append(i)
		var id := c.get_attr("id").strip_edges()
		if id == "" or index["nodes"].has(id):
			# Без авторского id (или при коллизии) — структурный: путь индексов в дереве.
			var parts: PackedStringArray = []
			for p in child_path:
				parts.append(str(p))
			id = "n" + "-".join(parts)
		var attrs := {}
		for k in c.attributes:
			if k != "id":
				attrs[k] = str(c.attributes[k])
		index["nodes"][id] = {"tag": c.raw_tag, "attrs": attrs, "parent": parent_id,
			"children": [], "elem": c}
		if parent_id == "":
			index["top"].append(id)
		else:
			index["nodes"][parent_id]["children"].append(id)
		_index_children(c, id, child_path, index)
		i += 1


## Слитый документ сцены: узлы страницы (с применёнными патчами; удалённые скрыты) +
## добавленные vrweb-node + (include_world) мировые объекты. У каждого элемента виден его
## id — по нему дифф отличает узел страницы от эфемерного объекта и от нового элемента.
## include_world=false даёт «флаш» — будущий <vrwml> страницы для персистенции на сервере.
static func serialize_scene(index: Dictionary, objects: Dictionary, include_world := true,
		config_attrs: Dictionary = {}) -> String:
	# Патчи по целевому узлу и объекты по родителю ("", "<id>", "page:<node_id>").
	var patches := {}
	var by_parent := {}
	for oid in objects.keys():
		var o: Dictionary = objects[oid]
		var kind := str(o.get("kind", ""))
		if kind == KIND_PATCH:
			patches[str(oid).trim_prefix(PATCH_PREFIX)] = o.get("props", {})
			continue
		if not include_world and kind != KIND_NODE:
			continue
		var parent := str(o.get("parent", ""))
		var key := parent
		if parent.begins_with(SceneChanges.PAGE_PREFIX):
			if not index["nodes"].has(parent.substr(SceneChanges.PAGE_PREFIX.length())):
				key = ""   # висячий якорь — на верхний уровень (сам якорь останется атрибутом)
		elif parent != "" and not objects.has(parent):
			key = ""
		if not by_parent.has(key):
			by_parent[key] = []
		by_parent[key].append(oid)
	for key in by_parent:
		by_parent[key].sort_custom(func(a, b) -> bool:
			var ta := float(objects[a].get("ts", 0.0))
			var tb := float(objects[b].get("ts", 0.0))
			return ta < tb if ta != tb else str(a) < str(b))

	var open := "<" + SCENE_TAG
	# include_world=false — persistence/debug view базы: instance config туда принципиально
	# не протекает, даже если вызывающий передал его по ошибке.
	var battrs := effective_block_attrs(index, config_attrs if include_world else {})
	for k in battrs:
		open += " %s=\"%s\"" % [k, HtmlNode.escape_attr(str(battrs[k]))]
	var lines: PackedStringArray = [open + ">"]
	for id in index.get("top", []):
		_emit_page_node(str(id), index, patches, by_parent, objects, 1, lines)
	for oid in by_parent.get("", []):
		_emit_scene_object(str(oid), objects, by_parent, 1, lines)
	lines.append("</%s>" % SCENE_TAG)
	return "\n".join(lines)


## Эффективные attrs корня для консоли/runtime: база страницы + allowlisted config инстанса.
## mode всегда показываем явно и нормализованно, даже если страница полагалась на combine default.
static func effective_block_attrs(index: Dictionary, config_attrs: Dictionary = {}) -> Dictionary:
	var attrs: Dictionary = (index.get("attrs", {}) as Dictionary).duplicate()
	var mode := _normalized_mode(str(attrs.get("mode", MODE_COMBINE)))
	if config_attrs.has("mode"):
		var override := str(config_attrs["mode"]).to_lower()
		if override == MODE_COMBINE or override == MODE_EXCLUSIVE:
			mode = override
	attrs["mode"] = mode
	return attrs


static func _emit_page_node(id: String, index: Dictionary, patches: Dictionary,
		by_parent: Dictionary, objects: Dictionary, indent: int, lines: PackedStringArray) -> void:
	var rec: Dictionary = index["nodes"][id]
	var patch: Dictionary = patches.get(id, {})
	if patch.get("removed", false):
		return   # затомбстоненный узел скрыт вместе с поддеревом (флаш его удалит)
	var attrs: Dictionary = rec["attrs"].duplicate()
	var set_map: Dictionary = patch.get("set", {})
	var extra: Array = []
	for k in set_map:
		if not attrs.has(k):
			extra.append(k)
		attrs[k] = str(set_map[k])
	extra.sort()
	var attr_str := " id=\"%s\"" % HtmlNode.escape_attr(id)
	for k in attrs:
		if extra.has(k):
			continue   # новые (патчевые) атрибуты — в конце, стабильным порядком
		attr_str += " %s=\"%s\"" % [k, HtmlNode.escape_attr(str(attrs[k]))]
	for k in extra:
		attr_str += " %s=\"%s\"" % [k, HtmlNode.escape_attr(str(attrs[k]))]
	var pad := "  ".repeat(indent)
	var page_kids: Array = rec["children"]
	var obj_kids: Array = by_parent.get(SceneChanges.PAGE_PREFIX + id, [])
	if page_kids.is_empty() and obj_kids.is_empty():
		lines.append("%s<%s%s />" % [pad, rec["tag"], attr_str])
		return
	lines.append("%s<%s%s>" % [pad, rec["tag"], attr_str])
	for cid in page_kids:
		_emit_page_node(str(cid), index, patches, by_parent, objects, indent + 1, lines)
	for oid in obj_kids:
		_emit_scene_object(str(oid), objects, by_parent, indent + 1, lines)
	lines.append("%s</%s>" % [pad, rec["tag"]])


## Эфемерный объект в слитом документе: vrweb-node — как узел сцены (тег = props.tag,
## атрибуты сырыми строками), мировой kind — как в блоке <ephemeral> (тег = kind, ttl,
## типизированные props).
static func _emit_scene_object(oid: String, objects: Dictionary, by_parent: Dictionary,
		indent: int, lines: PackedStringArray) -> void:
	var o: Dictionary = objects[oid]
	var pad := "  ".repeat(indent)
	var kind := str(o.get("kind", ""))
	var tag := kind
	var attr_str := " id=\"%s\"" % HtmlNode.escape_attr(oid)
	if kind == KIND_NODE:
		var props: Dictionary = o.get("props", {})
		tag = str(props.get("tag", "Node3D"))
		var attrs: Dictionary = props.get("attrs", {})
		var names := attrs.keys()
		names.sort()
		for k in names:
			attr_str += " %s=\"%s\"" % [k, HtmlNode.escape_attr(str(attrs[k]))]
	else:
		var ttl := float(o.get("ttl", 0.0))
		if ttl > 0.0:
			attr_str += " ttl=\"%s\"" % _fmt_num(ttl)
		var parent := str(o.get("parent", ""))
		if parent.begins_with(SceneChanges.PAGE_PREFIX) or (parent != "" and not objects.has(parent)):
			# Висячий/страничный якорь, не выраженный вложенностью, — атрибутом.
			if not by_parent.get(parent, []).has(oid):
				attr_str += " parent=\"%s\"" % HtmlNode.escape_attr(parent)
		var props: Dictionary = o.get("props", {})
		var names := props.keys()
		names.sort()
		for k in names:
			attr_str += " %s=\"%s\"" % [k, HtmlNode.escape_attr(_fmt_prop_value(props[k]))]
	var kids: Array = by_parent.get(oid, [])
	if kids.is_empty():
		lines.append("%s<%s%s />" % [pad, tag, attr_str])
		return
	lines.append("%s<%s%s>" % [pad, tag, attr_str])
	for cid in kids:
		_emit_scene_object(str(cid), objects, by_parent, indent + 1, lines)
	lines.append("%s</%s>" % [pad, tag])


## Разбор отредактированного единого документа. Возвращает { ok, error, block_attrs,
## entries }: записи в pre-order (родитель раньше ребёнка):
##   { id, tag (raw), ttl: float, attrs: {имя: raw-строка, без id/ttl/parent},
##     parent_entry: int|-1, parent: String (для -1: ""/page:…) }
static func parse_scene(root: HtmlNode) -> Dictionary:
	var block := root if root.tag == SCENE_TAG else root.find_descendant(SCENE_TAG)
	if block == null:
		return {"ok": false, "error": "нет блока <%s>" % SCENE_TAG, "block_attrs": {}, "entries": []}
	var entries: Array = []
	var seen := {}
	var err := _parse_scene_children(block, -1, entries, seen)
	if err != "":
		return {"ok": false, "error": err, "block_attrs": {}, "entries": []}
	return {"ok": true, "error": "", "block_attrs": block.attributes.duplicate(), "entries": entries}


static func _parse_scene_children(node: HtmlNode, parent_entry: int, entries: Array, seen: Dictionary) -> String:
	for c in node.children:
		if c.is_text():
			if c.text.strip_edges() != "":
				return "текст внутри <%s> не поддерживается: «%s»" % [SCENE_TAG, c.text.strip_edges().left(40)]
			continue
		var id := c.get_attr("id").strip_edges()
		if id != "":
			if seen.has(id):
				return "дубликат id «%s»" % id
			seen[id] = true
		var attrs := {}
		for attr_name in c.attributes:
			if RESERVED_ATTRS.has(attr_name):
				continue
			attrs[attr_name] = str(c.attributes[attr_name])
		var parent := ""
		if parent_entry == -1:
			parent = c.get_attr("parent").strip_edges()
		entries.append({
			"id": id,
			"tag": c.raw_tag,
			"ttl": float(c.get_attr("ttl", "0")),
			"attrs": attrs,
			"parent_entry": parent_entry,
			"parent": parent,
		})
		var err := _parse_scene_children(c, entries.size() - 1, entries, seen)
		if err != "":
			return err
	return ""


## Дифф единого документа: (индекс страницы, текущее состояние, записи правки) -> дельта.
## Правки узлов СТРАНИЦЫ становятся vrweb-patch (id "vpatch:<узел>"), новые PascalCase-теги —
## vrweb-node, новые lowercase-теги — мировые kind'ы (bubble/stroke/будущие). Наружу уходит
## ТОЛЬКО дельта — сами узлы страницы никуда не отправляются.
static func diff_scene(index: Dictionary, objects: Dictionary, parsed: Dictionary,
		make_id: Callable, config_attrs: Dictionary = {}) -> Dictionary:
	# Root attrs страницы остаются immutable, кроме allowlisted instance config. V1 разрешает
	# только mode; отсутствие mode в правке трактуется как стандартный combine.
	var parsed_attrs: Dictionary = parsed.get("block_attrs", {})
	var base_attrs: Dictionary = index.get("attrs", {})
	for key in base_attrs:
		if str(key) == "mode":
			continue
		if not parsed_attrs.has(key) or str(parsed_attrs[key]) != str(base_attrs[key]):
			return _err("атрибуты самого блока <%s>, кроме mode, менять нельзя" % SCENE_TAG)
	for key in parsed_attrs:
		if str(key) == "mode":
			continue
		if not base_attrs.has(key) or str(parsed_attrs[key]) != str(base_attrs[key]):
			return _err("атрибуты самого блока <%s>, кроме mode, менять нельзя" % SCENE_TAG)
	var edited_mode := str(parsed_attrs.get("mode", MODE_COMBINE)).to_lower()
	if edited_mode != MODE_COMBINE and edited_mode != MODE_EXCLUSIVE:
		return _err("mode блока <%s> должен быть combine или exclusive" % SCENE_TAG)
	var base_mode := _normalized_mode(str(base_attrs.get("mode", MODE_COMBINE)))
	var current_mode := base_mode
	if config_attrs.has("mode"):
		var override := str(config_attrs["mode"]).to_lower()
		if override == MODE_COMBINE or override == MODE_EXCLUSIVE:
			current_mode = override
	var entries: Array = parsed["entries"]
	var page_nodes: Dictionary = index["nodes"]

	# 1. Итоговые id записей (новым — сгенерированные) и родители в терминах протокола.
	var ids: Array = []
	var edited := {}
	for e in entries:
		var id: String = e["id"]
		if id == "":
			id = str(make_id.call())
		ids.append(id)
		edited[id] = true
	var parents: Array = []
	for i in entries.size():
		var e: Dictionary = entries[i]
		var pe := int(e["parent_entry"])
		if pe < 0:
			parents.append(str(e["parent"]))
		elif page_nodes.has(ids[pe]):
			parents.append(SceneChanges.PAGE_PREFIX + str(ids[pe]))
		else:
			parents.append(str(ids[pe]))

	var actions: Array = []
	if edited_mode != current_mode:
		actions.append({"op": SceneChanges.OP_UPDATE_CONFIG,
			"set": {"mode": null if edited_mode == base_mode else edited_mode}})
	# 2. Записи: узел страницы -> патч; эфемерный объект -> как раньше; новый -> add.
	for i in entries.size():
		var e: Dictionary = entries[i]
		var id: String = ids[i]
		if page_nodes.has(id):
			var err := _diff_page_node(id, e, parents[i], page_nodes, objects, actions)
			if err != "":
				return _err(err)
		elif objects.has(id):
			var err2 := _diff_existing_object(id, e, parents[i], objects, actions)
			if err2 != "":
				return _err(err2)
		else:
			_diff_new_entry(id, e, parents[i], actions)

	# 3. Пропавшие узлы страницы -> tombstone-патч (только верхние: поддерево скроет/удалит
	# патч родителя). Пропавшие эфемерные объекты -> remove (потомков удаляемых — каскад).
	for id in page_nodes.keys():
		if edited.has(id) or _page_ancestor_missing(str(id), page_nodes, edited):
			continue
		var pid := PATCH_PREFIX + str(id)
		if objects.has(pid):
			actions.append({"op": SceneChanges.OP_UPDATE, "id": pid, "props": {"removed": true}})
		else:
			actions.append({"op": SceneChanges.OP_ADD, "id": pid, "kind": KIND_PATCH,
				"parent": "", "ttl": 0.0, "props": {"set": {}, "removed": true}})
	for oid in objects.keys():
		if str(objects[oid].get("kind", "")) == KIND_PATCH:
			continue   # патчи управляются выше (по записям и tombstone'ам)
		if edited.has(oid):
			continue
		if _ancestor_removed(str(oid), objects, edited):
			continue
		actions.append({"op": SceneChanges.OP_REMOVE, "id": str(oid)})
	return {"ok": true, "error": "", "actions": actions}


static func _normalized_mode(value: String) -> String:
	return MODE_EXCLUSIVE if value.to_lower() == MODE_EXCLUSIVE else MODE_COMBINE


## Правка узла страницы: атрибуты сравниваются с БАЗОЙ (не с эффективным видом) — оверрайды,
## совпавшие с базой, уходят из патча сами. Возвращает текст ошибки или "".
static func _diff_page_node(id: String, e: Dictionary, parent: String,
		page_nodes: Dictionary, objects: Dictionary, actions: Array) -> String:
	var rec: Dictionary = page_nodes[id]
	var expected := "" if str(rec["parent"]) == "" else SceneChanges.PAGE_PREFIX + str(rec["parent"])
	if parent != expected:
		return "перемещение узла страницы «%s» не поддерживается" % id
	if str(e["tag"]) != str(rec["tag"]):
		return "смена класса узла страницы «%s» (%s → %s) не поддерживается" % [id, rec["tag"], e["tag"]]
	if float(e["ttl"]) != 0.0:
		return "у узла страницы «%s» не может быть ttl" % id
	var base: Dictionary = rec["attrs"]
	var new_set := {}
	for k in e["attrs"]:
		var v := str(e["attrs"][k])
		if not base.has(k) or v != str(base[k]):
			new_set[k] = v
	for k in base:
		if not e["attrs"].has(k):
			return "нельзя убрать атрибут «%s» узла страницы «%s» — верните его или задайте другое значение" % [k, id]
	var pid := PATCH_PREFIX + id
	var patch_props: Dictionary = objects.get(pid, {}).get("props", {})
	var old_set: Dictionary = patch_props.get("set", {})
	var was_removed: bool = patch_props.get("removed", false)
	if not objects.has(pid):
		if not new_set.is_empty():
			actions.append({"op": SceneChanges.OP_ADD, "id": pid, "kind": KIND_PATCH,
				"parent": "", "ttl": 0.0, "props": {"set": new_set}})
	elif new_set.is_empty() and not was_removed:
		actions.append({"op": SceneChanges.OP_REMOVE, "id": pid})   # оверрайдов не осталось
	elif not _same_string_map(new_set, old_set) or was_removed:
		# Узел присутствует в правке — «removed» снимается; set замещается целиком.
		actions.append({"op": SceneChanges.OP_UPDATE, "id": pid,
			"props": {"set": new_set, "removed": null}})
	return ""


## Правка существующего эфемерного объекта (vrweb-node или мировой kind).
static func _diff_existing_object(id: String, e: Dictionary, parent: String,
		objects: Dictionary, actions: Array) -> String:
	var obj: Dictionary = objects[id]
	var kind := str(obj.get("kind", ""))
	if kind == KIND_PATCH:
		return "id «%s» принадлежит служебному объекту-патчу" % id
	if kind == KIND_NODE:
		var props: Dictionary = obj.get("props", {})
		if str(e["tag"]) != str(props.get("tag", "")):
			return "смена класса узла «%s» не поддерживается — удалите id, чтобы создать новый" % id
		if float(e["ttl"]) != 0.0:
			return "у узла сцены «%s» не может быть ttl" % id
		if parent != str(obj.get("parent", "")):
			actions.append({"op": SceneChanges.OP_REPARENT, "id": id, "parent": parent})
		if not _same_string_map(e["attrs"], props.get("attrs", {})):
			actions.append({"op": SceneChanges.OP_UPDATE, "id": id, "props": {"attrs": e["attrs"]}})
		return ""
	# Мировой kind: тег = kind, props типизированы.
	if str(e["tag"]).to_lower() != kind:
		return "смена kind объекта «%s» (%s → %s) не поддерживается — удалите id, чтобы создать новый объект" % [id, kind, e["tag"]]
	if absf(float(obj.get("ttl", 0.0)) - float(e["ttl"])) > NUM_EPS:
		return "ttl объекта «%s» менять нельзя (истечение — забота авторитета)" % id
	if parent != str(obj.get("parent", "")):
		actions.append({"op": SceneChanges.OP_REPARENT, "id": id, "parent": parent})
	var patch := _props_patch(obj.get("props", {}), _typed_props(e["attrs"]))
	if not patch.is_empty():
		actions.append({"op": SceneChanges.OP_UPDATE, "id": id, "props": patch})
	return ""


## Новая запись: PascalCase-тег — узел сцены (vrweb-node), lowercase — мировой kind.
static func _diff_new_entry(id: String, e: Dictionary, parent: String, actions: Array) -> void:
	var tag := str(e["tag"])
	if tag != tag.to_lower():
		actions.append({"op": SceneChanges.OP_ADD, "id": id, "kind": KIND_NODE,
			"parent": parent, "ttl": 0.0, "props": {"tag": tag, "attrs": e["attrs"]}})
	else:
		actions.append({"op": SceneChanges.OP_ADD, "id": id, "kind": tag,
			"parent": parent, "ttl": float(e["ttl"]), "props": _typed_props(e["attrs"])})


static func _typed_props(attrs: Dictionary) -> Dictionary:
	var props := {}
	for k in attrs:
		props[k] = _parse_prop_value(str(k), str(attrs[k]))
	return props


## Есть ли у узла страницы предок, которого тоже нет в правке (его tombstone накроет поддерево).
static func _page_ancestor_missing(id: String, page_nodes: Dictionary, edited: Dictionary) -> bool:
	var cur := str(page_nodes[id].get("parent", ""))
	var guard := 0
	while cur != "" and page_nodes.has(cur) and guard < 4096:
		if not edited.has(cur):
			return true
		cur = str(page_nodes[cur].get("parent", ""))
		guard += 1
	return false


## Равенство словарей строка->строка (атрибуты vrweb сравниваются точно, без типизации).
static func _same_string_map(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or str(a[k]) != str(b[k]):
			return false
	return true
