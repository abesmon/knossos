class_name TopologyBuilder
extends RefCounted

## Фаза топологии (docs/content-sectioning.md): дерево HtmlNode -> сериализуемый
## артефакт БЕЗ единой 3D-координаты. Геометрия его не касается — между ними только
## этот Dictionary.
##
## МОДЕЛЬ: иерархия комнат строится по ОГЛАВЛЕНИЮ ЗАГОЛОВКОВ, а не по вложенности DOM.
##   1. Линеаризация (§2): обход контента в порядке чтения -> поток маркеров
##      HEADING(rank) / object / anchor / css. Контейнеры схлопываются полностью.
##   2. Сегментация (§4): стек по рангам. Заголовок ранга R закрывает секции ранга ≥R и
##      открывает новую; контент до следующего заголовка — наполнение секции. Секция ->
##      комната; подсекции (заголовки младше) -> вложенные комнаты.
##   3. Внутри секции — ПЛОСКИЙ список терминальных объектов, без под-комнат (§6).
## Нет заголовков -> одна корневая комната с плоским мешком объектов.
##
## Артефакт:
## {
##   "rooms": { id: Room },     # плоский словарь всех комнат/соединителей
##   "root":  id,               # корневое пространство
##   "labels": { anchorId: id }, # цели якорей #id -> комната/объект
##   "typography": { base_px }   # базовый кегль текста (масштаб геометрии)
## }
## Room   = { id, kind:"room"|"connector", objects:[Object], children:[id], hints:{...} }
## Object = { id, type, function:Transition|null, content:{...} }
## Transition = { kind:"navigate", href } | { kind:"teleport", target } | { kind:"back" }

const SKIP_TAGS := {
	"script": true, "style": true, "meta": true, "link": true, "head": true,
	"noscript": true, "svg": true, "title": true, "base": true, "template": true,
	"#document": false,  # документ не скипаем, но и не объект — обрабатываем как контейнер
}

const HEADING_TAGS := {
	"h1": true, "h2": true, "h3": true, "h4": true, "h5": true, "h6": true,
}

## Phrasing / inline-теги: их содержимое — часть текстового потока, а не отдельные
## пространства. Контейнер, где ВСЁ содержимое такое, сворачивается в один rich-text
## объект (абзац) с inline-ссылками — либо распознаётся как визуальный заголовок.
const PHRASING_TAGS := {
	"a": true, "span": true, "em": true, "strong": true, "b": true, "i": true,
	"u": true, "s": true, "strike": true, "small": true, "big": true, "sub": true,
	"sup": true, "mark": true, "abbr": true, "cite": true, "q": true, "code": true,
	"kbd": true, "samp": true, "var": true, "time": true, "label": true, "bdi": true,
	"bdo": true, "wbr": true, "br": true, "tt": true, "ins": true, "del": true,
	"font": true, "nobr": true, "ruby": true, "rt": true, "rp": true, "data": true,
	"center": true,
}

# Внутреннее состояние построителя.
var _rooms: Dictionary = {}      # id -> Room
var _labels: Dictionary = {}     # anchorId -> id
var _next_id: int = 0
var _base_px: float = 16.0       # базовый кегль страницы (нужен детектору заголовков)
var _debug: bool = false         # собирать ли карту id -> исходный HTML (только для отладки)
var _sources: Dictionary = {}    # id -> реконструированный HTML (заполняется при _debug)


## debug=true добавляет в артефакт ключ "sources" (id -> HTML-кусок, из которого собран
## узел/объект) для отладочной визуализации. В проде (main.gd) debug=false — артефакт
## остаётся чистым контрактом топология↔геометрия без разметки.
static func build(root: HtmlNode, debug: bool = false) -> Dictionary:
	var b := TopologyBuilder.new()
	b._debug = debug
	return b._build(root)


func _build(root: HtmlNode) -> Dictionary:
	var body := _find_body(root)
	# Типографику считаем ПЕРВОЙ: базовый кегль нужен детектору визуальных заголовков
	# (ранг — от относительного размера к base_px) и масштабу геометрии (§13 старого дока).
	_base_px = _compute_base_px(body)

	var stream: Array = []
	_linearize(body, stream)
	var root_id := _segment(stream, body)

	var artifact := {
		"rooms": _rooms, "root": root_id, "labels": _labels,
		"typography": {"base_px": _base_px},
	}
	if _debug:
		artifact["sources"] = _sources
	return artifact


func _find_body(root: HtmlNode) -> HtmlNode:
	# Ищем <body>; если нет — работаем от корня документа.
	var stack: Array[HtmlNode] = [root]
	while not stack.is_empty():
		var n: HtmlNode = stack.pop_back()
		if n.tag == "body":
			return n
		for c in n.children:
			stack.append(c)
	return root


# --- Фаза 1: линеаризация в поток маркеров (порядок чтения) ---

## Маркеры потока:
##   {kind:"heading", rank, obj, node} — заголовок (явный или визуальный)
##   {kind:"object",  obj}             — терминальный объект (image/text/list/table/...)
##   {kind:"anchor",  id}              — id схлопнутого контейнера (для labels)
##   {kind:"css",     css}            — визуальный box контейнера (bg/border) для хинтов
func _linearize(node: HtmlNode, stream: Array) -> void:
	if node == null:
		return
	if node.is_text():
		var t := node.text.strip_edges()
		if t != "":
			stream.append({"kind": "object", "obj": _text_object(t)})
		return

	var tag := node.tag
	if SKIP_TAGS.get(tag, false):
		return
	if _is_hidden(node):
		return

	# --- Терминальные объекты (классификация по содержимому, §3 старого дока) ---
	match tag:
		"img":
			var img_content := {"src": node.get_attr("src"), "alt": node.get_attr("alt")}
			img_content.merge(_image_dims(node))
			stream.append({"kind": "object", "obj": _leaf_object(node, "image", img_content)})
			return
		"video":
			# <video> становится логическим видео-плеером VRWeb (см. docs/video-player.md):
			# media_tag="video" + резолвимый src — WorldGenerator строит из него VrwebVideoScreen.
			# src — из атрибута video[src] или первого <source src> (стандарт HTML).
			var v_src := node.get_attr("src")
			if v_src == "":
				var source := node.find_descendant("source")
				if source != null:
					v_src = source.get_attr("src")
			var v_content := {
				"src": v_src, "text": node.collect_text(), "media_tag": "video",
				"autoplay": node.has_attr("autoplay"), "loop": node.has_attr("loop"),
			}
			v_content.merge(_image_dims(node))
			stream.append({"kind": "object", "obj": _leaf_object(node, "media", v_content)})
			return
		"audio", "iframe", "canvas", "embed":
			stream.append({"kind": "object", "obj": _leaf_object(node, "media", {
				"src": node.get_attr("src"), "text": node.collect_text(),
			})})
			return
		"button":
			stream.append({"kind": "object", "obj": _leaf_object(node, "button", {
				"text": node.collect_text(),
			})})
			return
		"input", "textarea", "select":
			stream.append({"kind": "object", "obj": _leaf_object(node, "input", {
				"text": node.get_attr("placeholder", node.get_attr("value", node.collect_text())),
				"input_type": node.get_attr("type", "text"),
			})})
			return
		"ul", "ol":
			# Гомогенный повтор -> один объект-коллекция (§7), а не N комнат.
			stream.append({"kind": "object", "obj": _list_object(node)})
			return
		"table":
			# Таблица — цельный объект (§7), а не россыпь комнат из <tr>/<td>.
			stream.append({"kind": "object", "obj": _table_object(node)})
			return
		"form":
			# Форма — цельный интерактивный объект-коллекция (как список/таблица).
			stream.append({"kind": "object", "obj": _form_object(node)})
			return
		"a":
			stream.append({"kind": "object", "obj": _anchor_object(node)})
			return
		"h1", "h2", "h3", "h4", "h5", "h6":
			# Явный заголовок: ранг = уровень тега (намерение автора бьёт кегль, §3.1).
			stream.append(_heading_marker(node, int(tag.substr(1))))
			return
		"br", "hr":
			return

	# --- Чистый inline-блок: визуальный заголовок ЛИБО абзац (rich-text) ---
	if _is_pure_inline(node):
		var rank := HeadingDetector.visual_rank(node, _base_px)
		if rank > 0:
			stream.append(_heading_marker(node, rank))
		else:
			var runs := _build_runs(node)
			if _runs_have_text(runs):
				stream.append({"kind": "object", "obj": _rich_text_object(node, runs)})
		return

	# --- Контейнер: схлопывается полностью; комнат не порождает (§6) ---
	# Сохраняем id (якорь) и визуальный box контейнера как pending-маркеры — сегментатор
	# прикрепит их к ближайшей открывающейся секции (если за ними сразу идёт заголовок)
	# или к текущей секции (если пошёл контент). См. _segment.
	if node.has_attr("id"):
		stream.append({"kind": "anchor", "id": node.get_attr("id")})
	var box := _css_hints(node)
	if not box.is_empty():
		stream.append({"kind": "css", "css": box})
	for c in node.children:
		_linearize(c, stream)


func _heading_marker(node: HtmlNode, rank: int) -> Dictionary:
	var obj := _leaf_object(node, "heading", {
		"text": node.collect_text(), "level": clampi(rank, 1, 6),
	})
	return {"kind": "heading", "rank": rank, "obj": obj, "node": node}


# --- Фаза 2: сегментация по рангам заголовков (стек) ---

## Строит дерево секций из потока §1 и материализует его в комнаты. Возвращает root id.
func _segment(stream: Array, body: HtmlNode) -> int:
	var root_sec := _new_section(0, null, body)   # rank 0 — преамбула (до первого заголовка)
	var stack: Array = [root_sec]
	var pending_anchors: Array = []
	var pending_css: Dictionary = {}

	for item in stream:
		match item["kind"]:
			"heading":
				var r: int = item["rank"]
				# Закрываем все секции равного/младшего ранга (§4).
				while stack.size() > 1 and int(stack[-1]["rank"]) >= r:
					stack.pop_back()
				var sec := _new_section(r, item["obj"], item["node"])
				(stack[-1]["children"] as Array).append(sec)
				stack.append(sec)
				# Контейнер обрамлял ИМЕННО этот заголовок -> его id/box едут в новую секцию.
				_flush_pending(sec, pending_anchors, pending_css)
				pending_anchors = []
				pending_css = {}
			"object":
				# Контент пошёл в текущую секцию -> pending принадлежит ей.
				_flush_pending(stack[-1], pending_anchors, pending_css)
				pending_anchors = []
				pending_css = {}
				(stack[-1]["objects"] as Array).append(item["obj"])
			"anchor":
				pending_anchors.append(item["id"])
			"css":
				_merge_into(pending_css, item["css"])

	_flush_pending(stack[-1], pending_anchors, pending_css)

	# Пустая корневая обёртка (нет своего наполнения и ровно один ребёнок) — не плодим
	# лишнюю комнату-в-комнате: верхняя секция документа становится корнем сама.
	if root_sec["title"] == null and (root_sec["objects"] as Array).is_empty() \
			and (root_sec["anchors"] as Array).is_empty() and (root_sec["css"] as Dictionary).is_empty() \
			and (root_sec["children"] as Array).size() == 1:
		return _materialize_section((root_sec["children"] as Array)[0])
	return _materialize_section(root_sec)


func _new_section(rank: int, title, node) -> Dictionary:
	return {
		"rank": rank, "title": title, "node": node,
		"objects": [], "children": [], "anchors": [], "css": {},
	}


func _flush_pending(sec: Dictionary, anchors: Array, css: Dictionary) -> void:
	for aid in anchors:
		(sec["anchors"] as Array).append(aid)
	_merge_into(sec["css"], css)


## Рекурсивно превращает дерево секций в комнаты артефакта. Возвращает id комнаты.
func _materialize_section(sec: Dictionary) -> int:
	var child_ids: Array = []
	for child in sec["children"]:
		child_ids.append(_materialize_section(child))

	var objects: Array = []
	if sec["title"] != null:
		objects.append(sec["title"])   # заголовок секции — первый объект (подпись комнаты)
	objects.append_array(sec["objects"])

	var id := _alloc()
	var weight := objects.size()
	for cid in child_ids:
		weight += int(_rooms[cid]["hints"].get("weight", 0))

	# Соединитель — секция, чья роль ТОЛЬКО ветвиться: ≥2 детей и никакого своего наполнения.
	# Иначе обычная комната (возможно с детьми). Степень — хинт геометрии (§6 старого дока).
	var kind := "connector" if (child_ids.size() >= 2 and objects.is_empty()) else "room"
	var hints := {"weight": weight}
	if child_ids.size() >= 2:
		hints["degree"] = child_ids.size()

	var node = sec["node"]
	if node != null:
		var sem := _semantic_tag(node.tag)
		if sem != "":
			hints["semanticTag"] = sem
	var css := {}
	_merge_into(css, sec["css"])
	if node != null:
		_merge_into(css, _css_hints(node))
	if not css.is_empty():
		hints["css"] = css

	_rooms[id] = {
		"id": id, "kind": kind, "objects": objects,
		"children": child_ids, "hints": hints,
	}

	# Якоря: id-ы схлопнутых контейнеров секции + id самого заголовка -> на эту комнату
	# (teleport #id приводит игрока в комнату секции, а не в объект-подпись).
	for aid in sec["anchors"]:
		_labels[aid] = id
	if node != null and node.get_attr("id") != "":
		_labels[node.get_attr("id")] = id
	_record_source(id, node)
	return id


func _merge_into(dst: Dictionary, src: Dictionary) -> void:
	for k in src:
		if not dst.has(k):
			dst[k] = src[k]


# --- Конструкторы объектов ---

func _text_object(text: String) -> Dictionary:
	return {"id": _alloc(), "type": "text", "function": null, "content": {"text": text}}


func _leaf_object(node: HtmlNode, type: String, content: Dictionary) -> Dictionary:
	var obj := {"id": _alloc(), "type": type, "function": null, "content": content}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


func _anchor_object(node: HtmlNode) -> Dictionary:
	# Что это как объект — по содержимому; href навешивает функцию перехода (§3).
	var type := "image" if node.has_descendant_tag("img") else "text"
	var content := {"text": node.collect_text()}
	if type == "image":
		content["alt"] = node.collect_text()
		var img: HtmlNode = node.find_descendant("img")
		if img != null:
			content["src"] = img.get_attr("src")
			content.merge(_image_dims(img))
	var obj := {"id": _alloc(), "type": type, "function": _transition_for(node), "content": content}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


## true, если в поддереве нет блочных элементов — только текст и inline-теги.
func _is_pure_inline(node: HtmlNode) -> bool:
	for child in node.children:
		if child.is_text():
			continue
		var t := child.tag
		if SKIP_TAGS.get(t, false):
			continue
		if PHRASING_TAGS.has(t):
			if not _is_pure_inline(child):
				return false
		else:
			return false
	return true


## Линеаризует inline-поддерево в массив «прогонов» (runs) в порядке чтения.
## run = { "text": String, "function": Transition|null }. Ссылки становятся отдельными
## прогонами с функцией перехода; смежный обычный текст склеивается.
func _build_runs(node: HtmlNode) -> Array:
	var runs: Array = []
	_collect_runs(node, runs)
	return runs


func _collect_runs(node: HtmlNode, runs: Array) -> void:
	for child in node.children:
		if child.is_text():
			_append_text_run(runs, child.text)
		elif SKIP_TAGS.get(child.tag, false):
			continue
		elif child.tag == "a":
			var fn = _transition_for(child)
			var text := child.collect_text()
			if fn != null:
				runs.append({"text": text, "function": fn})
			else:
				_append_text_run(runs, text)
		elif PHRASING_TAGS.has(child.tag):
			_collect_runs(child, runs)
		else:
			_append_text_run(runs, child.collect_text())


func _append_text_run(runs: Array, text: String) -> void:
	if text == "":
		return
	# Склеиваем с предыдущим текстовым прогоном (без функции), сохраняя пробелы.
	if not runs.is_empty() and runs[-1].get("function", null) == null:
		runs[-1]["text"] = str(runs[-1]["text"]) + text
	else:
		runs.append({"text": text, "function": null})


func _runs_have_text(runs: Array) -> bool:
	for r in runs:
		if str(r.get("text", "")).strip_edges() != "":
			return true
	return false


func _rich_text_object(node: HtmlNode, runs: Array) -> Dictionary:
	var plain := ""
	for r in runs:
		plain += str(r["text"])
	var obj := {
		"id": _alloc(), "type": "text", "function": null,
		"content": {"text": plain.strip_edges(), "runs": runs},
	}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


func _list_object(node: HtmlNode) -> Dictionary:
	var items: Array = []
	for li in node.children:
		if li.tag != "li":
			continue
		# Содержимое элемента линеаризуется в «прогоны» (как абзац, §3): каждая <a href>
		# внутри становится отдельным прогоном со своей Transition, текст склеивается.
		items.append({"text": li.collect_text(), "runs": _build_runs(li)})
	var obj := {"id": _alloc(), "type": "list", "function": null, "content": {"items": items}}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


## Таблица -> один объект-коллекция (§7). Строки собираются сквозь обёртки
## <thead>/<tbody>/<tfoot>; ячейка = { text, runs, header }. <caption> -> подпись.
func _table_object(node: HtmlNode) -> Dictionary:
	var rows: Array = []
	_collect_table_rows(node, rows)
	var caption := ""
	for c in node.children:
		if c.tag == "caption":
			caption = c.collect_text()
			break
	var obj := {
		"id": _alloc(), "type": "table", "function": null,
		"content": {"caption": caption, "rows": rows},
	}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


func _collect_table_rows(node: HtmlNode, rows: Array) -> void:
	for c in node.children:
		match c.tag:
			"tr":
				rows.append(_table_row(c))
			"thead", "tbody", "tfoot":
				_collect_table_rows(c, rows)


func _table_row(row_node: HtmlNode) -> Dictionary:
	var cells: Array = []
	var is_header := false
	for c in row_node.children:
		if c.tag != "td" and c.tag != "th":
			continue
		cells.append({"text": c.collect_text(), "runs": _build_runs(c), "header": c.tag == "th"})
		if c.tag == "th":
			is_header = true
	return {"cells": cells, "header": is_header}


## Форма -> объект-коллекция: поля (input/textarea/select/button) собираются сквозь
## обёртки. content.text — плоская сводка полей (дешёвый рендер без спец-актора формы).
func _form_object(node: HtmlNode) -> Dictionary:
	var fields: Array = []
	_collect_form_fields(node, fields)
	var summary := ""
	for f in fields:
		summary += "[" + str(f["input_type"]) + "] " + str(f["text"]) + "  "
	var obj := {
		"id": _alloc(), "type": "form", "function": null,
		"content": {"fields": fields, "text": summary.strip_edges(), "action": node.get_attr("action")},
	}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


func _collect_form_fields(node: HtmlNode, fields: Array) -> void:
	for c in node.children:
		match c.tag:
			"input", "textarea", "select":
				fields.append({
					"input_type": c.get_attr("type", "text"),
					"text": c.get_attr("placeholder", c.get_attr("value", c.collect_text())),
				})
			"button":
				fields.append({"input_type": "button", "text": c.collect_text()})
			_:
				if not c.is_text():
					_collect_form_fields(c, fields)


func _transition_for(anchor: HtmlNode):
	if not anchor.has_attr("href"):
		return null
	var href := anchor.get_attr("href").strip_edges()
	if href == "" or href == "#":
		return null
	if href.begins_with("#"):
		return {"kind": "teleport", "target": href.substr(1)}
	var scheme := _scheme_of(href)
	if scheme == "javascript":
		return null
	# http/https и относительные ссылки (без схемы) — внутренний браузинг VRWeb.
	if scheme == "" or scheme == "http" or scheme == "https":
		return {"kind": "navigate", "href": href}
	# Любая другая схема (mailto:, tel:, sms:, magnet:, кастомные app-схемы) — это не
	# веб-страница, а намерение для ОС: пробросим в системный обработчик (OS.shell_open).
	return {"kind": "external", "uri": href}


## Возвращает схему URL в нижнем регистре ("http", "mailto", …) или "" если её нет
## (относительный путь). Схема по RFC 3986: ALPHA *(ALPHA/DIGIT/"+"/"-"/".") до ":".
## Любой из /?# до двоеточия означает, что это относительный путь, а не схема.
static func _scheme_of(url: String) -> String:
	var colon := url.find(":")
	if colon <= 0:
		return ""
	for sep in ["/", "?", "#"]:
		var p := url.find(sep)
		if p != -1 and p < colon:
			return ""
	var scheme := url.substr(0, colon)
	for i in scheme.length():
		var ch := scheme[i]
		var alpha := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")
		var ok := alpha or (i > 0 and ((ch >= "0" and ch <= "9") or ch == "+" or ch == "-" or ch == "."))
		if not ok:
			return ""
	return scheme.to_lower()


# --- Хинты и якоря ---

func _register_anchor(node, id: int) -> void:
	if node == null:
		return
	var anchor_id: String = node.get_attr("id")
	if anchor_id != "":
		_labels[anchor_id] = id


## Запоминает исходный HTML узла/объекта (только в режиме отладки).
func _record_source(id: int, node) -> void:
	if not _debug or node == null:
		return
	_sources[id] = node.to_html()


func _semantic_tag(tag: String) -> String:
	match tag:
		"main", "section", "article", "nav", "aside", "header", "footer", "body":
			return tag
	return ""


func _css_hints(node: HtmlNode) -> Dictionary:
	var css := {}
	var style := node.get_attr("style").to_lower()
	var bg := _extract_css_value(style, "background-color")
	if bg == "":
		bg = _extract_css_value(style, "background")
	if bg != "":
		css["bg"] = bg
	if node.has_attr("bgcolor"):
		css["bg"] = node.get_attr("bgcolor")
	if style.contains("border"):
		css["border"] = true
	return css


# --- Типографика и размеры (для масштаба геометрии) ---

const DEFAULT_BASE_PX := 16.0  # дефолтный кегль <body> в браузере


## Средневзвешенный (по длине текста) кегль страницы. Текст без явного font-size
## считается базовым (16px); заголовки в среднее не входят — они масштабируются
## геометрией отдельно по уровню. Так «база» отражает основной читаемый текст.
func _compute_base_px(root: HtmlNode) -> float:
	var acc := {"sum": 0.0, "weight": 0.0}
	_accumulate_font_px(root, DEFAULT_BASE_PX, acc)
	if acc["weight"] <= 0.0:
		return DEFAULT_BASE_PX
	return clampf(acc["sum"] / acc["weight"], 8.0, 40.0)


func _accumulate_font_px(node: HtmlNode, inherited_px: float, acc: Dictionary) -> void:
	if node.is_text():
		var t := node.text.strip_edges()
		if t != "":
			var w := float(t.length())
			acc["sum"] += inherited_px * w
			acc["weight"] += w
		return
	if SKIP_TAGS.get(node.tag, false):
		return
	if HEADING_TAGS.has(node.tag):
		return  # текст заголовков в базу не считаем
	var px := inherited_px
	var declared := _font_size_px(node)
	if declared > 0.0:
		px = declared
	for c in node.children:
		_accumulate_font_px(c, px, acc)


func _font_size_px(node: HtmlNode) -> float:
	var style := node.get_attr("style").to_lower()
	return _length_px(_extract_css_value(style, "font-size"))


## Картинка -> {width_px?, height_px?} из атрибутов width/height или inline-стиля
## (CSS перекрывает атрибут). Относительные/процентные значения игнорируются.
func _image_dims(node: HtmlNode) -> Dictionary:
	var w := _length_px(node.get_attr("width"))
	var h := _length_px(node.get_attr("height"))
	var style := node.get_attr("style").to_lower()
	var sw := _length_px(_extract_css_value(style, "width"))
	var sh := _length_px(_extract_css_value(style, "height"))
	if sw > 0.0:
		w = sw
	if sh > 0.0:
		h = sh
	var dims := {}
	if w > 0.0:
		dims["width_px"] = w
	if h > 0.0:
		dims["height_px"] = h
	return dims


## Абсолютная длина в CSS-пикселях: «600», «600px» -> 600.0; em/%/прочее -> -1.0.
func _length_px(value: String) -> float:
	value = value.strip_edges().to_lower()
	if value == "":
		return -1.0
	if value.ends_with("px"):
		value = value.substr(0, value.length() - 2).strip_edges()
	if value.is_valid_float():
		return value.to_float()
	return -1.0


func _extract_css_value(style: String, prop: String) -> String:
	var idx := style.find(prop + ":")
	if idx == -1:
		return ""
	var start := idx + prop.length() + 1
	var end := style.find(";", start)
	if end == -1:
		end = style.length()
	return style.substr(start, end - start).strip_edges()


func _is_hidden(node: HtmlNode) -> bool:
	var style := node.get_attr("style").to_lower().replace(" ", "")
	if style.contains("display:none") or style.contains("visibility:hidden"):
		return true
	if node.has_attr("hidden"):
		return true
	return false


func _alloc() -> int:
	var id := _next_id
	_next_id += 1
	return id
