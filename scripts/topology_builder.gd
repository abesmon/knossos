class_name TopologyBuilder
extends RefCounted

## Фаза топологии (docs/html-to-3d-topology.md): дерево HtmlNode -> сериализуемый
## артефакт §1 БЕЗ единой 3D-координаты. Геометрия его не касается — между ними
## только этот Dictionary.
##
## Артефакт:
## {
##   "rooms": { id: Room },     # плоский словарь всех комнат/соединителей
##   "root":  id,               # корневое пространство
##   "labels": { anchorId: id } # цели якорей #id -> комната/объект
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
## объект (абзац) с inline-ссылками, а не дробится на множество объектов.
const PHRASING_TAGS := {
	"a": true, "span": true, "em": true, "strong": true, "b": true, "i": true,
	"u": true, "s": true, "strike": true, "small": true, "big": true, "sub": true,
	"sup": true, "mark": true, "abbr": true, "cite": true, "q": true, "code": true,
	"kbd": true, "samp": true, "var": true, "time": true, "label": true, "bdi": true,
	"bdo": true, "wbr": true, "br": true, "tt": true, "ins": true, "del": true,
	"font": true, "nobr": true, "ruby": true, "rt": true, "rp": true, "data": true,
}

# Внутреннее состояние построителя.
var _rooms: Dictionary = {}      # id -> Room
var _labels: Dictionary = {}     # anchorId -> id
var _next_id: int = 0
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
	var res := _process(body)
	var top: Array = res["rooms"]
	var loose: Array = res["loose"]

	var root_id: int
	if top.size() == 1 and loose.is_empty():
		root_id = top[0]
	else:
		# Осталось несколько верхних пространств и/или свободные листья — оборачиваем.
		var kind := "connector" if top.size() >= 2 else "room"
		root_id = _make_room(kind, loose, top, null)

	# Типографика страницы: базовый кегль текста. Геометрия выводит из него единый
	# масштаб «CSS-пиксель -> метр», относительно которого размеряет всё остальное
	# (заголовки, картинки, таблицы). См. docs/html-to-3d-topology.md §F.
	var artifact := {
		"rooms": _rooms, "root": root_id, "labels": _labels,
		"typography": {"base_px": _compute_base_px(body)},
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


## Возвращает { "rooms": [id...], "loose": [Object...] }.
## rooms — уже сформированные пространства (комнаты/соединители).
## loose — свободные листья-объекты, ещё не приписанные ни к одной комнате.
func _process(node: HtmlNode) -> Dictionary:
	var empty := {"rooms": [], "loose": []}
	if node == null:
		return empty

	if node.is_text():
		var t := node.text.strip_edges()
		if t == "":
			return empty
		return {"rooms": [], "loose": [_text_object(t)]}

	var tag := node.tag
	if SKIP_TAGS.get(tag, false):
		return empty
	if _is_hidden(node):
		return empty

	# --- Листовые типы объектов (классификация по содержимому, §3) ---
	match tag:
		"img":
			var img_content := {"src": node.get_attr("src"), "alt": node.get_attr("alt")}
			img_content.merge(_image_dims(node))
			return {"rooms": [], "loose": [_leaf_object(node, "image", img_content)]}
		"video", "audio", "iframe", "canvas", "embed":
			return {"rooms": [], "loose": [_leaf_object(node, "media", {
				"src": node.get_attr("src"), "text": node.collect_text(),
			})]}
		"button":
			return {"rooms": [], "loose": [_leaf_object(node, "button", {
				"text": node.collect_text(),
			})]}
		"input", "textarea", "select":
			return {"rooms": [], "loose": [_leaf_object(node, "input", {
				"text": node.get_attr("placeholder", node.get_attr("value", node.collect_text())),
				"input_type": node.get_attr("type", "text"),
			})]}
		"ul", "ol":
			# Гомогенный повтор -> один объект-коллекция (§7), а не N комнат.
			return {"rooms": [], "loose": [_list_object(node)]}
		"table":
			# Таблица — цельный объект (§7), а не россыпь комнат из <tr>/<td>.
			# Это буквально объект-таблица, стоящий В комнате, как и список.
			return {"rooms": [], "loose": [_table_object(node)]}
		"a":
			return {"rooms": [], "loose": [_anchor_object(node)]}
		"h1", "h2", "h3", "h4", "h5", "h6":
			return {"rooms": [], "loose": [_leaf_object(node, "heading", {
				"text": node.collect_text(), "level": int(tag.substr(1)),
			})]}
		"br", "hr":
			return empty

	# --- Абзац: чистый inline-контент сворачивается в ОДИН rich-text объект ---
	# (текст + inline-ссылки одним блоком, без дробления на панели).
	if _is_pure_inline(node):
		var runs := _build_runs(node)
		if _runs_have_text(runs):
			return {"rooms": [], "loose": [_rich_text_object(node, runs)]}
		return empty

	# --- Контейнер: контракция снизу вверх (§4) ---
	var child_rooms: Array = []
	var child_loose: Array = []
	for c in node.children:
		var r := _process(c)
		child_rooms.append_array(r["rooms"])
		child_loose.append_array(r["loose"])

	if child_rooms.size() >= 2:
		# >=2 готовых комнаты -> узел становится соединителем; слияние вверх стоп.
		# Свободные листья декорируют соединитель (§5).
		var conn_id := _make_room("connector", child_loose, child_rooms, node)
		return {"rooms": [conn_id], "loose": []}

	if child_rooms.size() == 1:
		# Неветвящийся узел: ровно одно дочернее пространство. Узел лежит на «пути»,
		# а не на границе комнаты, поэтому комнату-в-комнате не плодим (§4.4, правило B).
		var only_id: int = child_rooms[0]
		if child_loose.is_empty():
			# Чистая цепочка-«леса»: один ребёнок, своих листьев нет — схлопываем.
			# CSS-box (стена/пол) требует сохранить контейнер как отдельное пространство.
			if _has_visual_box(node):
				var wrap_id := _make_room("room", [], child_rooms, node)
				return {"rooms": [wrap_id], "loose": []}
			_register_anchor(node, only_id)  # якорь схлопнутого контейнера не теряем
			return {"rooms": [only_id], "loose": []}
		# Один ребёнок + свои свободные листья. Линейная цепочка: листья ВЛИВАЮТСЯ в
		# единственную комнату, узел схлопывается — не оборачиваем комнату в комнату.
		# Стоп: box узла (стена) либо ребёнок-соединитель / визуальная карточка
		# (own css) — туда контент сверху не вливаем, оставляем как вложенное.
		var only: Dictionary = _rooms[only_id]
		if not _has_visual_box(node) and only["kind"] == "room" and not only["hints"].has("css"):
			only["objects"] = child_loose + only["objects"]
			only["hints"]["weight"] = int(only["hints"].get("weight", 0)) + child_loose.size()
			var sem := _semantic_tag(node.tag)
			if sem != "" and not only["hints"].has("semanticTag"):
				only["hints"]["semanticTag"] = sem
			_register_anchor(node, only_id)
			_record_source(only_id, node)
			return {"rooms": [only_id], "loose": []}
		var wrap_id2 := _make_room("room", child_loose, child_rooms, node)
		return {"rooms": [wrap_id2], "loose": []}

	if child_loose.is_empty():
		return empty

	# Отсюда: дочерних комнат нет, есть только свободные листья.

	# Обёртка вокруг одних заголовков — это подпись, а не комната (§5). Заголовок —
	# label к контенту, что идёт после него; он не «якорит» собственное пространство.
	# Контейнер комнатой не становится: заголовки всплывают наверх как loose и прилипают
	# к ближайшему выжившему пространству-предку, где встают объектами-соседями с этим
	# контентом. Так чинится «div.mw-heading вокруг <h3>», который иначе боксился в комнату
	# на уровень ниже соседних абзацев. CSS-box (стена/рамка) блокирует схлопывание (§4).
	if _all_headings(child_loose) and not _has_visual_box(node):
		return {"rooms": [], "loose": child_loose}

	# Правило A: контейнер вокруг ОДНОГО листа комнатой не становится — лист всплывает
	# наверх как loose и кластеризуется с соседями на ближайшем выжившем пространстве.
	# Так распускаются «леса» вокруг одиночного списка/картинки/текста, а тонкие сиблинги
	# (по 1 листу в каждом) собираются в одну комнату, а не в россыпь комнат-одиночек.
	# Стоп: семантический тег (section/article/nav/... — настоящее пространство) или
	# CSS-box (визуальная карточка) — там одиночный лист остаётся собственной комнатой.
	if child_loose.size() == 1 and _semantic_tag(node.tag) == "" and not _has_visual_box(node):
		_register_anchor(node, child_loose[0]["id"])  # якорь обёртки -> на сам объект
		return {"rooms": [], "loose": child_loose}

	# >=2 листьев (или семантика/box) -> кристаллизуем комнату из листьев.
	var room_id := _make_room("room", child_loose, [], node)
	return {"rooms": [room_id], "loose": []}


# --- Конструкторы пространства ---

func _make_room(kind: String, objects: Array, children: Array, node) -> int:
	var id := _alloc()
	var weight := objects.size()
	for child_id in children:
		weight += int(_rooms[child_id]["hints"].get("weight", 0))
	var hints := {"weight": weight}
	if kind == "connector":
		hints["degree"] = children.size()
	if node != null:
		var sem := _semantic_tag(node.tag)
		if sem != "":
			hints["semanticTag"] = sem
		var css := _css_hints(node)
		if not css.is_empty():
			hints["css"] = css
	_rooms[id] = {
		"id": id, "kind": kind, "objects": objects,
		"children": children, "hints": hints,
	}
	_register_anchor(node, id)
	_record_source(id, node)
	return id


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
## run = { "text": String, "function": Transition|null }. Ссылки становятся
## отдельными прогонами с функцией перехода; смежный обычный текст склеивается.
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


## true, если непустой набор loose-листьев состоит ИСКЛЮЧИТЕЛЬНО из заголовков.
## Такой контейнер — обёртка-подпись, а не комната (см. ветку схлопывания в _process).
func _all_headings(objects: Array) -> bool:
	if objects.is_empty():
		return false
	for o in objects:
		if o.get("type", "") != "heading":
			return false
	return true


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
		# Так ссылки внутри пункта списка не теряются и остаются кликабельными в мире (§7).
		items.append({"text": li.collect_text(), "runs": _build_runs(li)})
	var obj := {"id": _alloc(), "type": "list", "function": null, "content": {"items": items}}
	_record_source(obj["id"], node)
	return obj


## Таблица -> один объект-коллекция (§7). Строки собираются сквозь обёртки
## <thead>/<tbody>/<tfoot>; ячейка = { text, function?, header } (как элемент списка
## в §3: <a> внутри едет с ячейкой функцией перехода). <caption> -> подпись.
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
		# Содержимое ячейки линеаризуется в прогоны (как элемент списка): ссылки внутри
		# становятся кликабельными прогонами и не теряются в мире (§7).
		cells.append({"text": c.collect_text(), "runs": _build_runs(c), "header": c.tag == "th"})
		if c.tag == "th":
			is_header = true
	return {"cells": cells, "header": is_header}


func _transition_for(anchor: HtmlNode):
	if not anchor.has_attr("href"):
		return null
	var href := anchor.get_attr("href").strip_edges()
	if href == "" or href == "#":
		return null
	if href.begins_with("#"):
		return {"kind": "teleport", "target": href.substr(1)}
	if href.begins_with("javascript:"):
		return null
	return {"kind": "navigate", "href": href}


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
## (CSS перекрывает атрибут). Относительные/процентные значения игнорируются —
## остаётся только то, что геометрия может перевести в метры через base_px.
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


func _has_visual_box(node: HtmlNode) -> bool:
	# Контейнер с фоном/рамкой несёт визуальную информацию -> схлопывать нельзя (§4).
	var css := _css_hints(node)
	return css.has("bg") or css.has("border")


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
