class_name TopologyBuilder
extends RefCounted

## Фаза топологии (docs/clustering.md): дерево HtmlNode -> сериализуемый артефакт БЕЗ
## единой 3D-координаты. Геометрия его не касается — между ними только этот Dictionary.
##
## МОДЕЛЬ: КЛАСТЕРИЗАЦИЯ. div и контейнеры больше НЕ источник комнат. Комнаты рождаются
## из дерева кластеров по разным сигналам:
##   - структурные семантические (body/main/section/article/header/footer/aside) -> комнаты;
##   - заголовки h1..h6 (явные и визуальные) -> «именованный» кластер, вес = ранг; старт на
##     заголовке, конец — у следующего заголовка веса ≥ в пределах того же DOM-кластера ЛИБО
##     у закрытия DOM-кластера;
##   - лёгкие кластеры (nav, группа ссылок ≥3) -> объекты-группы В комнате родителя, не комнаты;
##   - прозрачные контейнеры (div, обёртки) -> не кластеры, проходим насквозь, но СОБИРАЕМ их
##     мету (id -> якоря, css-box bg/border -> хинты, чтобы не потерять при «развоплощении»).
## Кластер = объекты, гарантированно в одной комнате. Внутри кластера ДРОБИТЕЛИ
## (table/form/video/iframe/canvas/embed/pre/blockquote/figure/list/одиночная блок-img)
## становятся отдельными объектами; смежный текст/inline/ссылки/inline-картинки сливаются
## в один RichText.
##
## Артефакт (контракт неизменен):
## {
##   "rooms":  { id: Room },      # плоский словарь всех комнат/соединителей
##   "root":   id,                # корневое пространство
##   "labels": { anchorId: id },  # цели якорей #id -> комната/объект
##   "typography": { base_px },   # базовый кегль текста (масштаб геометрии)
##   "document": { bg?, bg_image?, fg? }  # визуальный паспорт <body> -> небо/земля/палитра
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

## Структурные семантические контейнеры -> кластеры-КОМНАТЫ (по DOM-границе).
const SEMANTIC_TAGS := {
	"body": true, "main": true, "section": true, "article": true,
	"header": true, "footer": true, "aside": true,
}

## Phrasing / inline-теги: их содержимое — часть текстового потока, а не отдельные
## пространства. Сливаются в rich-text прогоны (абзац) с inline-ссылками/картинками.
const PHRASING_TAGS := {
	"a": true, "span": true, "em": true, "strong": true, "b": true, "i": true,
	"u": true, "s": true, "strike": true, "small": true, "big": true, "sub": true,
	"sup": true, "mark": true, "abbr": true, "cite": true, "q": true, "code": true,
	"kbd": true, "samp": true, "var": true, "time": true, "label": true, "bdi": true,
	"bdo": true, "wbr": true, "br": true, "tt": true, "ins": true, "del": true,
	"font": true, "nobr": true, "ruby": true, "rt": true, "rp": true, "data": true,
	"center": true,
}

const LINK_GROUP_MIN := 3        # ≥ столько ссылок в контейнере -> лёгкий кластер-«меню»

# Внутреннее состояние построителя.
var _rooms: Dictionary = {}      # id -> Room
var _labels: Dictionary = {}     # anchorId -> id
var _next_id: int = 0
var _base_px: float = 16.0       # базовый кегль страницы (нужен детектору заголовков)
var _debug: bool = false         # собирать ли карту id -> исходный HTML (только для отладки)
var _sources: Dictionary = {}    # id -> реконструированный HTML (заполняется при _debug)
var _pending_anchors: Array = [] # id-ы прозрачных контейнеров, ждущие владельца-кластера
var _pending_css: Dictionary = {} # css-box прозрачных контейнеров, ждущий владельца


## debug=true добавляет в артефакт ключ "sources" (id -> HTML-кусок, из которого собран
## узел/объект) для отладочной визуализации. В проде (main.gd) debug=false — артефакт
## остаётся чистым контрактом топология↔геометрия без разметки.
static func build(root: HtmlNode, debug: bool = false) -> Dictionary:
	var b := TopologyBuilder.new()
	b._debug = debug
	return b._build(root)


## Структурная подпись топологии — канонический отпечаток ФОРМЫ пространства без его
## содержимого. Две страницы одного шаблона (напр. разные статьи новостника) с одинаковым
## деревом комнат и одинаковой последовательностью объектов дают одну подпись, даже если
## текст/ссылки/картинки внутри разные. Влияет: дерево комнат (порядок детей), kind комнаты,
## тип каждого объекта и вид его перехода (navigate/teleport/back/external). НЕ влияет:
## текст, href/target перехода, src картинки, css-хинты, id. Подпись — сид ПРОСТРАНСТВА
## (геометрии), см. PageFetcher.space_seed: одинаковая топология на одном хосте → один мир.
static func signature(space: Dictionary) -> String:
	var rooms: Dictionary = space.get("rooms", {})
	var root: int = space.get("root", -1)
	var parts := PackedStringArray()
	_sig_walk(root, rooms, parts)
	return "|".join(parts)


static func _sig_walk(id: int, rooms: Dictionary, parts: PackedStringArray) -> void:
	var room = rooms.get(id, null)
	if room == null:
		parts.append("_")
		return
	parts.append("(" + str(room.get("kind", "room")))
	for obj in room.get("objects", []):
		var fn = obj.get("function", null)
		var fk: String = "" if fn == null else str(fn.get("kind", ""))
		parts.append(str(obj.get("type", "")) + ":" + fk)
	parts.append("[")
	for child in room.get("children", []):
		_sig_walk(int(child), rooms, parts)
	parts.append("])")


func _build(root: HtmlNode) -> Dictionary:
	var body := _find_body(root)
	# Типографику считаем ПЕРВОЙ: базовый кегль нужен детектору визуальных заголовков
	# (ранг — от относительного размера к base_px) и масштабу геометрии.
	_base_px = _compute_base_px(body)

	_pending_anchors = []
	_pending_css = {}
	var root_frame := _new_frame("root", body, 0, null, "")
	var stack: Array = [root_frame]
	for c in body.children:
		_classify(c, stack)
	_pop_to(root_frame, stack)        # сбрасываем хвостовой runbuf + висящие заголовочные фреймы

	var root_id := _materialize(root_frame)

	var artifact := {
		"rooms": _rooms, "root": root_id, "labels": _labels,
		"typography": {"base_px": _base_px},
		"document": _document_style(root, body),   # фон/цвет документа -> небо/земля/палитра (фаза F)
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


# --- Фаза 1: построение дерева кластеров (DFS со стеком фреймов, порядок чтения) ---

## Фрейм-кластер:
##   type        : "root" | "semantic" | "heading" | "light"
##   weight      : ранг заголовка (1..6); 0 для прочих
##   title       : объект-heading (подпись комнаты) или null
##   node        : исходный HtmlNode (для хинтов/семантики/якорей)
##   light_kind  : "nav" | "linkgroup" | "" (для лёгких кластеров)
##   items       : упорядоченный контент: {k:"runs",runs} | {k:"object",obj} | {k:"frame",frame}
##   anchors     : id-якоря, осевшие на этом кластере (свой + прозрачные обёртки)
##   css         : css-box (bg/border) кластера и обёрток
##   runbuf      : открытый буфер inline-прогонов (склейка текста/ссылок до блок-границы)
func _new_frame(type: String, node, weight: int, title, light_kind: String) -> Dictionary:
	var anchors: Array = []
	if node != null and node.has_attr("id"):
		anchors.append(node.get_attr("id"))
	var css := {}
	if node != null:
		_merge_into(css, _css_hints(node))
	return {
		"type": type, "weight": weight, "title": title, "node": node,
		"light_kind": light_kind, "items": [], "anchors": anchors,
		"css": css, "runbuf": [],
	}


## Главный диспетчер: классифицирует узел и либо открывает кластер, либо эмитит объект/прогон.
func _classify(node: HtmlNode, stack: Array) -> void:
	if node.is_text():
		if node.text.strip_edges() != "":
			_emit_inline(node, stack)   # значимый текст -> в inline-буфер текущего кластера
		elif node.text != "" and not (stack[-1]["runbuf"] as Array).is_empty():
			# Пробел между inline-сиблингами (схлопнутый перенос: <a>A</a> <a>B</a> -> «A B»).
			# Только в начатой строке прогонов — иначе на границах блоков плодились бы пробелы.
			_append_text_run(stack[-1]["runbuf"], " ")
		return

	var tag := node.tag
	if SKIP_TAGS.get(tag, false):
		return
	if _is_hidden(node):
		return

	# --- Кластеры-источники ---
	if HEADING_TAGS.has(tag):
		_open_heading(node, int(tag.substr(1)), stack)   # явный заголовок: ранг = уровень тега
		return
	if SEMANTIC_TAGS.has(tag):
		_open_semantic(node, stack)
		return

	# --- Терминальные объекты / дробители (проверяем ДО лёгких кластеров: ul/table и т.п.
	#     остаются цельными объектами, а не превращаются в «группу ссылок») ---
	match tag:
		"img":
			_emit_object(_leaf_object(node, "image", _img_content(node)), stack)
			return
		"video":
			_emit_object(_video_object(node), stack)
			return
		"audio", "iframe", "canvas", "embed":
			_emit_object(_leaf_object(node, "media", {
				"src": node.get_attr("src"), "text": node.collect_text(),
			}), stack)
			return
		"button":
			_emit_object(_leaf_object(node, "button", {"text": node.collect_text()}), stack)
			return
		"input", "textarea", "select":
			# Поле без выводимой подписи (ни value/placeholder/aria-label/title, ни текста) —
			# «немое», ничего не сообщает (типичный UI-чекбокс скина) -> объекта нет.
			var label := _input_label(node)
			if label == "":
				return
			_emit_object(_leaf_object(node, "input", {
				"text": label, "input_type": node.get_attr("type", "text"),
			}), stack)
			return
		"ul", "ol":
			# Пустой список (<ul></ul> без пунктов, частый артефакт меню-скинов) -> объекта нет.
			if not _has_list_items(node):
				return
			_emit_object(_list_object(node), stack)        # объект-коллекция (дробитель)
			return
		"table":
			_emit_object(_table_object(node), stack)
			return
		"form":
			_emit_object(_form_object(node), stack)
			return
		"figure":
			_emit_object(_figure_object(node), stack)
			return
		"pre":
			_emit_object(_code_object(node), stack)        # блок кода: моноширинный, отдельно
			return
		"blockquote":
			_emit_object(_quote_object(node), stack)
			return
		"a":
			_emit_inline(node, stack)                      # ссылка вливается в прозу
			return
		"br", "hr":
			return

	# --- Лёгкие кластеры (объекты-группы в комнате родителя) ---
	if tag == "nav":
		_open_light(node, "nav", stack)
		return
	if _is_link_group(node):
		_open_light(node, "linkgroup", stack)
		return

	# --- Фразовый элемент ИЛИ чистый inline-блок: визуальный заголовок / инлайн-прогон /
	#     абзац. Голые фразовые сиблинги (span/b/em вне <p>) сливаются в общий буфер прогонов,
	#     а не дробятся каждый в свой абзац; блочный pure-inline (<p>, <div> с текстом) — абзац. ---
	if PHRASING_TAGS.has(tag) or _is_pure_inline(node):
		var rank := HeadingDetector.visual_rank(node, _base_px)
		if rank > 0:
			_open_heading(node, rank, stack, true)   # визуальный заголовок (эвристика)
		elif PHRASING_TAGS.has(tag):
			_emit_inline(node, stack)
		else:
			_emit_paragraph(node, stack)
		return

	# --- Прозрачный контейнер: НЕ кластер. Собираем мету и идём насквозь. ---
	_harvest(node)
	for c in node.children:
		_classify(c, stack)


# --- Операции со стеком фреймов ---

func _push_frame(frame: Dictionary, stack: Array) -> void:
	var parent: Dictionary = stack[-1]
	_flush_runbuf(parent)                                # открытие кластера закрывает абзац родителя
	(parent["items"] as Array).append({"k": "frame", "frame": frame})
	_flush_pending(frame)                                # обёртки вокруг кластера -> на сам кластер
	stack.append(frame)


## Снимает со стека всё до указанного фрейма ВКЛЮЧИТЕЛЬНО, сбрасывая их inline-буферы.
func _pop_to(frame: Dictionary, stack: Array) -> void:
	while not stack.is_empty() and stack[-1] != frame:
		_flush_runbuf(stack[-1])
		stack.pop_back()
	if not stack.is_empty():
		_flush_runbuf(frame)
		stack.pop_back()


## Заголовок: закрывает заголовочные фреймы веса ≥ ранга В ПРЕДЕЛАХ текущего DOM-кластера
## (цикл стопится на не-heading фрейме), затем открывает новый заголовочный фрейм.
func _open_heading(node: HtmlNode, rank: int, stack: Array, visual: bool = false) -> void:
	while stack.size() > 1 and stack[-1]["type"] == "heading" and int(stack[-1]["weight"]) >= rank:
		_flush_runbuf(stack[-1])
		stack.pop_back()
	var content := {"text": node.collect_text(), "level": clampi(rank, 1, 6)}
	# Заголовок может содержать ссылку (<h2><a>...</a></h2>, кликабельный «ENTER →»):
	# сохраняем прогоны со ссылками, чтобы кликабельность не терялась (рендер сделает портал).
	var runs := _build_runs(node)
	if _has_link_run(runs):
		content["runs"] = runs
	var title := _leaf_object(node, "heading", content)
	var frame := _new_frame("heading", node, rank, title, "")
	frame["visual"] = visual   # визуальный (эвристика) vs явный <h1>..<h6> — влияет на демоутинг
	_push_frame(frame, stack)
	# Текст заголовка — его подпись; в детей не спускаемся (последующие сиблинги — наполнение).


func _open_semantic(node: HtmlNode, stack: Array) -> void:
	var frame := _new_frame("semantic", node, 0, null, "")
	_push_frame(frame, stack)
	for c in node.children:
		_classify(c, stack)
	_pop_to(frame, stack)


func _open_light(node: HtmlNode, kind: String, stack: Array) -> void:
	var frame := _new_frame("light", node, 0, null, kind)
	_push_frame(frame, stack)
	for c in node.children:
		_classify(c, stack)
	_pop_to(frame, stack)


func _emit_object(obj: Dictionary, stack: Array) -> void:
	var top: Dictionary = stack[-1]
	_flush_pending(top)
	_flush_runbuf(top)                                   # дробитель разрывает абзац
	(top["items"] as Array).append({"k": "object", "obj": obj})


func _emit_inline(node: HtmlNode, stack: Array) -> void:
	var top: Dictionary = stack[-1]
	_flush_pending(top)
	_append_node_runs(node, top["runbuf"])               # копим прогоны в открытом буфере


func _emit_paragraph(node: HtmlNode, stack: Array) -> void:
	var top: Dictionary = stack[-1]
	# Абзац сливается в node-less RichText, поэтому его id/css сами не осядут — собираем их
	# в pending (как у прозрачной обёртки), чтобы #id-якорь абзаца не потерялся.
	_harvest(node)
	_flush_pending(top)
	_flush_runbuf(top)
	var runs := _build_runs(node)
	if _runs_have_content(runs):
		(top["items"] as Array).append({"k": "runs", "runs": runs})


## Сбрасывает открытый inline-буфер фрейма в его items как один прогон-сегмент.
func _flush_runbuf(frame: Dictionary) -> void:
	var buf: Array = frame["runbuf"]
	if _runs_have_content(buf):
		(frame["items"] as Array).append({"k": "runs", "runs": buf})
	frame["runbuf"] = []


## Прицепляет накопленные «висящие» якоря/css прозрачных обёрток к указанному фрейму.
func _flush_pending(frame: Dictionary) -> void:
	for aid in _pending_anchors:
		(frame["anchors"] as Array).append(aid)
	_merge_into(frame["css"], _pending_css)
	_pending_anchors = []
	_pending_css = {}


## Собирает мету прозрачного контейнера (id -> якорь, css-box -> хинт) в pending —
## так инфа из div, который больше не комната, не теряется.
func _harvest(node: HtmlNode) -> void:
	if node.has_attr("id"):
		_pending_anchors.append(node.get_attr("id"))
	var box := _css_hints(node)
	if not box.is_empty():
		_merge_into(_pending_css, box)


## Контейнер ≥LINK_GROUP_MIN ссылок-«пунктов», где ссылки доминируют над прозой -> лёгкий
## кластер-«меню». Работает и для inline-контейнеров (навбар из <span>+<a>): меню от абзаца
## отличаем по тому, что почти весь текст лежит ВНУТРИ ссылок (а не вокруг них).
func _is_link_group(node: HtmlNode) -> bool:
	if _count_grouped_links(node) < LINK_GROUP_MIN:
		return false
	if _has_structural_descendant(node):
		return false   # есть заголовки/секции -> это структура, а не плоское меню
	var total := node.collect_text().length()
	var linked := _linked_text_len(node)
	return (total - linked) <= linked   # текст вне ссылок не больше, чем в ссылках


## Содержит ли поддерево заголовок или семантический контейнер (признак структуры, а не
## плоского меню). Защищает от поглощения контентного div лёгким кластером (потери заголовков).
func _has_structural_descendant(node: HtmlNode) -> bool:
	for c in node.children:
		if c.is_text():
			continue
		if HEADING_TAGS.has(c.tag) or SEMANTIC_TAGS.has(c.tag):
			return true
		if _has_structural_descendant(c):
			return true
	return false


## Считает «пункты-ссылки» среди ПРЯМЫХ детей: сам <a href> либо обёртка (любая), чьё
## наполнение — ссылка. Только прямые дети — поэтому ссылки, разбросанные в абзацах прозы,
## порог не наберут.
func _count_grouped_links(node: HtmlNode) -> int:
	var n := 0
	for c in node.children:
		if c.is_text():
			continue
		if c.tag == "a" and c.has_attr("href"):
			n += 1
		elif c.has_descendant_tag("a"):
			var a := c.find_descendant("a")
			if a != null and a.has_attr("href"):
				n += 1
	return n


## Суммарная длина текста внутри <a href> поддерева (для отличения меню от прозы).
func _linked_text_len(node: HtmlNode) -> int:
	if node.tag == "a" and node.has_attr("href"):
		return node.collect_text().length()
	var total := 0
	for c in node.children:
		if not c.is_text():
			total += _linked_text_len(c)
	return total


# --- Фаза 2: материализация дерева кластеров в комнаты ---

func _is_room_frame(frame: Dictionary) -> bool:
	var t: String = frame["type"]
	return t == "root" or t == "semantic" or t == "heading"


## Пустой заголовок-кластер: ни своих объектов/текста, ни подкластеров — только сам заголовок.
## Как КОМНАТА он бессмысленен (комната нужна, лишь если есть контент или дочерние кластеры),
## поэтому вливается в родителя (см. _form_objects: визуальный -> richtext, явный -> объект-heading).
func _heading_is_bare(frame: Dictionary) -> bool:
	if frame["type"] != "heading":
		return false
	for item in frame["items"]:
		match item["k"]:
			"object":
				return false
			"runs":
				if _runs_have_content(item["runs"]):
					return false
			"frame":
				return false   # любой подкластер -> заголовок что-то «возглавляет»
	return true


func _has_link_run(runs: Array) -> bool:
	for r in runs:
		if r.get("function", null) != null:
			return true
	return false


## Лёгкие кластеры не становятся комнатами — но их мету (якоря/css) нельзя терять:
## поднимаем её в ближайшую комнату-владельца.
func _absorb_light_meta(frame: Dictionary) -> void:
	for item in frame["items"]:
		if item["k"] == "frame" and not _is_room_frame(item["frame"]):
			var lf: Dictionary = item["frame"]
			_absorb_light_meta(lf)
			for aid in lf["anchors"]:
				(frame["anchors"] as Array).append(aid)
			_merge_into(frame["css"], lf["css"])


## Рекурсивно превращает фрейм-кластер в комнату артефакта. Возвращает id комнаты.
func _materialize(frame: Dictionary) -> int:
	_absorb_light_meta(frame)
	var objects := _form_objects(frame)

	var child_ids: Array = []
	for item in frame["items"]:
		if item["k"] == "frame" and _is_room_frame(item["frame"]) \
				and not _heading_is_bare(item["frame"]):
			child_ids.append(_materialize(item["frame"]))

	# Проходная комната: пустой родитель (нет подписи/наполнения) c единственным ребёнком —
	# это коридор-обёртка к тому, что внутри. Сливаем родителя в ребёнка, ПЕРЕНОСЯ якоря/css/
	# семантику (мета не теряется), чтобы не плодить пустую комнату-в-комнате. Коннекторы
	# (≥2 детей) не трогаем — это реальные развилки.
	if frame["title"] == null and objects.is_empty() and child_ids.size() == 1:
		_merge_meta_into_room(frame, child_ids[0])
		return child_ids[0]

	var id := _alloc()
	var weight := objects.size()
	for cid in child_ids:
		weight += int(_rooms[cid]["hints"].get("weight", 0))

	# Соединитель — кластер, чья роль ТОЛЬКО ветвиться: ≥2 детей и нет своего наполнения.
	var kind := "connector" if (child_ids.size() >= 2 and objects.is_empty()) else "room"
	var hints := {"weight": weight}
	if child_ids.size() >= 2:
		hints["degree"] = child_ids.size()
	if frame["node"] != null:
		var sem := _semantic_tag(frame["node"].tag)
		if sem != "":
			hints["semanticTag"] = sem
	if not (frame["css"] as Dictionary).is_empty():
		hints["css"] = frame["css"]

	_rooms[id] = {
		"id": id, "kind": kind, "objects": objects,
		"children": child_ids, "hints": hints,
	}
	for aid in frame["anchors"]:
		_labels[aid] = id
	_record_source(id, frame["node"])
	return id


## Собственные объекты кластера: подпись + слияние смежных прогонов в RichText, разрывы
## на дробителях, инлайн объектов лёгких подкластеров. Дочерние КОМНАТЫ пропускаются.
func _form_objects(frame: Dictionary) -> Array:
	var result: Array = []
	if frame["title"] != null:
		result.append(frame["title"])   # заголовок — первый объект (подпись комнаты)
	var merge: Array = []                # копим прогоны текущего RichText-сегмента
	for item in frame["items"]:
		match item["k"]:
			"runs":
				if not merge.is_empty():
					merge.append({"text": "\n", "function": null})   # граница абзацев
				merge.append_array(item["runs"])
			"object":
				_flush_merge(merge, result)
				merge = []
				result.append(item["obj"])
			"frame":
				var ch: Dictionary = item["frame"]
				if _heading_is_bare(ch):
					# Пустой заголовок-кластер вливаем в родителя (своей комнаты не получает).
					# Визуальный (эвристика часто ложна + может нести ссылку) -> richtext, сохраняя
					# кликабельность («ENTER →»). Явный <h1>..<h6> -> остаётся объектом-heading.
					_flush_merge(merge, result)
					merge = []
					if ch.get("visual", false):
						var runs := _build_runs(ch["node"])
						if _runs_have_content(runs):
							result.append(_rich_text_object(ch["node"], runs))
					else:
						result.append(ch["title"])
					continue
				if _is_room_frame(ch):
					continue             # дочерняя комната — не объект этого кластера
				# Лёгкий подкластер (nav/группа ссылок) -> его объекты прямо здесь.
				# NB: заголовок внутри лёгкого кластера (редкость) тут потерялся бы.
				_flush_merge(merge, result)
				merge = []
				result.append_array(_form_objects(ch))
	_flush_merge(merge, result)
	return result


func _flush_merge(merge: Array, result: Array) -> void:
	if _runs_have_content(merge):
		result.append(_rich_text_object(null, merge))


## Переносит мету схлопнутого родителя-проходной в комнату-ребёнка: якоря (-> labels на
## ребёнка), css-box (стены/пол), семантический тег (если у ребёнка своего нет).
func _merge_meta_into_room(frame: Dictionary, room_id: int) -> void:
	var room: Dictionary = _rooms[room_id]
	for aid in frame["anchors"]:
		_labels[aid] = room_id
	if not (frame["css"] as Dictionary).is_empty():
		var css: Dictionary = room["hints"].get("css", {})
		_merge_into(css, frame["css"])
		room["hints"]["css"] = css
	if frame["node"] != null:
		var sem := _semantic_tag(frame["node"].tag)
		if sem != "" and not room["hints"].has("semanticTag"):
			room["hints"]["semanticTag"] = sem


func _merge_into(dst: Dictionary, src: Dictionary) -> void:
	for k in src:
		if not dst.has(k):
			dst[k] = src[k]


# --- Конструкторы объектов ---

func _leaf_object(node: HtmlNode, type: String, content: Dictionary) -> Dictionary:
	var obj := {"id": _alloc(), "type": type, "function": null, "content": content}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


func _img_content(node: HtmlNode) -> Dictionary:
	var content := {"src": node.get_attr("src"), "alt": node.get_attr("alt")}
	content.merge(_image_dims(node))
	return content


## <video> -> логический видео-плеер VRWeb (docs/video-player.md): media_tag="video" +
## резолвимый src — WorldGenerator строит из него VrwebVideoScreen. src из video[src] или
## первого <source src> (стандарт HTML).
func _video_object(node: HtmlNode) -> Dictionary:
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
	return _leaf_object(node, "media", v_content)


## <figure> -> цельный объект (картинка + подпись из <figcaption>).
func _figure_object(node: HtmlNode) -> Dictionary:
	var content := {}
	var cap := node.find_descendant("figcaption")
	var caption := cap.collect_text() if cap != null else ""
	content["caption"] = caption
	var img := node.find_descendant("img")
	if img != null:
		content["src"] = img.get_attr("src")
		content["alt"] = img.get_attr("alt")
		content.merge(_image_dims(img))
	content["text"] = caption if caption != "" else (img.get_attr("alt") if img != null else "")
	return _leaf_object(node, "figure", content)


## <pre> -> блок кода. Сохраняем СЫРОЙ текст (с переносами/отступами), без нормализации.
func _code_object(node: HtmlNode) -> Dictionary:
	return _leaf_object(node, "code", {"text": _raw_text(node)})


## <blockquote> -> цитата. runs сохраняют inline-ссылки (как абзац).
func _quote_object(node: HtmlNode) -> Dictionary:
	return _leaf_object(node, "quote", {
		"text": node.collect_text(), "runs": _build_runs(node),
	})


## Сырой текст поддерева без нормализации пробелов (для <pre>).
func _raw_text(node: HtmlNode) -> String:
	if node.is_text():
		return node.text
	var s := ""
	for c in node.children:
		s += _raw_text(c)
	return s


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
## run = { "text", "function":Transition|null } | { "type":"image", "src","alt",..,"function" }.
func _build_runs(node: HtmlNode) -> Array:
	var runs: Array = []
	for child in node.children:
		_append_node_runs(child, runs)
	return runs


## Добавляет один узел в массив прогонов: текст склеивается, <a> -> ссылка-прогон,
## <img> -> картинка-прогон, inline-теги рекурсивно, прочее -> плоский текст (с картинкой).
func _append_node_runs(node: HtmlNode, runs: Array) -> void:
	if node.is_text():
		_append_text_run(runs, node.text)
		return
	if SKIP_TAGS.get(node.tag, false):
		return
	if node.tag == "br":
		_append_text_run(runs, "\n")   # перенос строки внутри абзаца (в т.ч. кривой </br>)
		return
	if node.tag == "img":
		runs.append(_image_run(node, null))
		return
	if node.tag == "a":
		var fn = _transition_for(node)
		var text := node.collect_text()
		# <a><img></a> -> картинка-прогон с функцией перехода (как объект-image).
		if text.strip_edges() == "" and node.has_descendant_tag("img"):
			runs.append(_image_run(node.find_descendant("img"), fn))
		elif fn != null:
			runs.append({"text": text, "function": fn})
		else:
			_append_text_run(runs, text)
		return
	if PHRASING_TAGS.has(node.tag):
		for child in node.children:
			_append_node_runs(child, runs)
		return
	# Блочная обёртка в inline-контексте: текст склеиваем; если текста нет, а внутри есть
	# картинка (<div><img></div>) — не теряем её (берём первую).
	var t := node.collect_text()
	if t.strip_edges() == "" and node.has_descendant_tag("img"):
		runs.append(_image_run(node.find_descendant("img"), null))
	else:
		_append_text_run(runs, t)


func _append_text_run(runs: Array, text: String) -> void:
	if text == "":
		return
	# Склеиваем с предыдущим текстовым прогоном (без функции), сохраняя пробелы.
	if not runs.is_empty() and runs[-1].get("function", null) == null and not runs[-1].has("type"):
		runs[-1]["text"] = str(runs[-1].get("text", "")) + text
	else:
		runs.append({"text": text, "function": null})


## Есть ли в прогонах значимое содержимое (текст ИЛИ картинка).
func _runs_have_content(runs: Array) -> bool:
	for r in runs:
		if str(r.get("type", "")) == "image":
			return true
		if str(r.get("text", "")).strip_edges() != "":
			return true
	return false


## Прогон-картинка внутри абзаца/ячейки/пункта: несёт src/alt/размеры как объект-image
## плюс опциональную функцию перехода, если картинка была завёрнута в <a href>.
func _image_run(img: HtmlNode, fn) -> Dictionary:
	if img == null:
		return {"text": "", "function": fn}
	var run := {
		"type": "image", "src": img.get_attr("src"),
		"alt": img.get_attr("alt"), "function": fn,
	}
	run.merge(_image_dims(img))
	return run


## RichText-объект из готовых прогонов. node может быть null (склейка нескольких сегментов).
func _rich_text_object(node, runs: Array) -> Dictionary:
	var plain := ""
	for r in runs:
		plain += str(r.get("text", ""))
	var obj := {
		"id": _alloc(), "type": "text", "function": null,
		"content": {"text": plain.strip_edges(), "runs": runs},
	}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


## Есть ли в списке хоть один пункт <li> (иначе объект пустой — выкидываем).
func _has_list_items(node: HtmlNode) -> bool:
	for li in node.children:
		if li.tag == "li":
			return true
	return false


## Подпись поля ввода. Видимого текста у <input> обычно нет, поэтому берём косвенные
## признаки. Для кнопок надпись — value; для checkbox/radio value не надпись, берём aria-label/
## title; для текстовых — placeholder; aria-label/title — общий фолбэк. Иначе поле «немое».
func _input_label(node: HtmlNode) -> String:
	var t := node.get_attr("type").to_lower()
	var order: Array
	if t == "submit" or t == "button" or t == "reset":
		order = ["value", "aria-label", "title"]
	elif t == "checkbox" or t == "radio":
		order = ["aria-label", "title"]
	else:
		order = ["placeholder", "aria-label", "value", "title"]
	for attr in order:
		var v := node.get_attr(attr).strip_edges()
		if v != "":
			return v
	return node.collect_text().strip_edges()   # <select>/<textarea> — текст содержимого


func _list_object(node: HtmlNode) -> Dictionary:
	var items: Array = []
	for li in node.children:
		if li.tag != "li":
			continue
		# Содержимое элемента линеаризуется в «прогоны» (как абзац): каждая <a href>
		# внутри становится отдельным прогоном со своей Transition, текст склеивается.
		items.append({"text": li.collect_text(), "runs": _build_runs(li)})
	var obj := {"id": _alloc(), "type": "list", "function": null, "content": {"items": items}}
	_register_anchor(node, obj["id"])
	_record_source(obj["id"], node)
	return obj


## Таблица -> один объект-коллекция. Строки собираются сквозь обёртки
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
	return classify_href(anchor.get_attr("href").strip_edges())


## Классифицирует href в Transition (или null, если вести некуда). Едина для ссылок
## страницы и кликабельных ссылок чата (см. main.gd _on_chat_meta_clicked).
static func classify_href(href: String):
	if href == "" or href == "#":
		return null
	if href.begins_with("#"):
		return {"kind": "teleport", "target": href.substr(1)}
	# Собственные схемы приложения (vrwebresource:// — бандл, vrweblocal:// — файл ОС) —
	# это страницы VRWeb, а не намерение для ОС: открываем их внутренней навигацией, иначе
	# OS.shell_open ушёл бы искать внешний обработчик и ничего бы не открыл.
	if PageFetcher.is_local(href):
		return {"kind": "navigate", "href": href}
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
		bg = _css_color_token(_extract_css_value(style, "background"))
	if bg != "":
		css["bg"] = bg
	if node.has_attr("bgcolor"):
		css["bg"] = node.get_attr("bgcolor")
	var fg := _extract_css_value(style, "color")
	if fg != "":
		css["fg"] = fg
	if style.contains("border"):
		css["border"] = true
	return css


## Визуальный «паспорт» документа для геометрии: фон-картинка, фон-цвет и цвет текста
## <body>. Из них фаза F строит небо (картинка -> панорама, иначе фон-цвет -> база неба),
## землю (цвет текста, иначе очень тёмный фон) и палитру комнат (см. world_generator).
##
## Каскада/специфичности у нас нет (внешний CSS не резолвится, см. html-to-3d-topology.md
## §10–§11), поэтому источники берём по нарастанию «явности»: правила body/html/:root из
## встроенных <style> -> инлайн-style самого <body> -> презентационные атрибуты
## (bgcolor/text). Каждый следующий перекрывает предыдущий по найденным ключам.
func _document_style(root: HtmlNode, body: HtmlNode) -> Dictionary:
	var doc := _doc_style_from_stylesheet(_collect_stylesheet_css(root))
	if body != null:
		var style := body.get_attr("style").to_lower()
		_merge_decls(doc, style)
		if body.has_attr("bgcolor"):
			doc["bg"] = body.get_attr("bgcolor").to_lower()
		if body.has_attr("text"):
			doc["fg"] = body.get_attr("text").to_lower()
	return doc


## Склеивает текст всех <style> страницы (порядок документа = порядок каскада).
func _collect_stylesheet_css(root: HtmlNode) -> String:
	var parts: PackedStringArray = []
	var stack: Array[HtmlNode] = [root]
	while not stack.is_empty():
		var n: HtmlNode = stack.pop_back()
		if n.tag == "style":
			parts.append(n.collect_text())
		for c in n.children:
			stack.append(c)
	return " ".join(parts)


## Вытаскивает фон/цвет документа из таблицы стилей: правила, чей селектор целит в
## body/html/:root. Лёгкий экстрактор, НЕ движок CSS — без специфичности и @-правил
## (вложенные @media/@supports игнорируются), правила берутся по порядку (last-wins).
func _doc_style_from_stylesheet(css: String) -> Dictionary:
	var out := {}
	css = _strip_css_comments(css).to_lower()
	var i := 0
	while true:
		var brace := css.find("{", i)
		if brace == -1:
			break
		var close := css.find("}", brace)
		if close == -1:
			break
		var sel := css.substr(i, brace - i).strip_edges()
		if _selector_targets_document(sel):
			_merge_decls(out, css.substr(brace + 1, close - brace - 1))
		i = close + 1
	return out


## Целит ли селектор в корень документа: любая из групп (через запятую) равна
## body / html / :root (без вложенных комбинаторов — берём только простые корневые правила).
func _selector_targets_document(sel: String) -> bool:
	for part in sel.split(","):
		match part.strip_edges():
			"body", "html", ":root":
				return true
	return false


## Разбирает блок объявлений «prop:value; …» и кладёт в out фон/картинку/цвет (last-wins).
func _merge_decls(out: Dictionary, decls: String) -> void:
	var bg := _extract_css_value(decls, "background-color")
	if bg != "":
		out["bg"] = bg
	var bg_img := _extract_css_url(_extract_css_value(decls, "background-image"))
	if bg_img != "":
		out["bg_image"] = bg_img
	# Шорткат background: и цвет, и картинка в одном свойстве.
	var bg_short := _extract_css_value(decls, "background")
	if bg_short != "":
		var short_img := _extract_css_url(bg_short)
		if short_img != "":
			out["bg_image"] = short_img
		var short_col := _css_color_token(bg_short)
		if short_col != "":
			out["bg"] = short_col
	var fg := _extract_css_value(decls, "color")
	if fg != "":
		out["fg"] = fg


## url(...) -> очищенный путь; "" если url() нет. Снимает кавычки и пробелы.
func _extract_css_url(value: String) -> String:
	var idx := value.find("url(")
	if idx == -1:
		return ""
	var start := idx + 4
	var end := value.find(")", start)
	if end == -1:
		return ""
	var url := value.substr(start, end - start).strip_edges()
	if url.length() >= 2 and (url[0] == "\"" or url[0] == "'"):
		url = url.substr(1, url.length() - 2)
	return url.strip_edges()


## Первый токен значения, похожий на цвет (#hex / rgb()/ имя). Нужен, чтобы из шортката
## `background: #fff url(x) no-repeat` достать именно цвет. "" — если цвета нет.
func _css_color_token(value: String) -> String:
	value = value.strip_edges()
	if value == "":
		return ""
	# rgb()/rgba()/hsl() — берём как есть до закрывающей скобки.
	for fn in ["rgba(", "rgb(", "hsla(", "hsl("]:
		var fi := value.find(fn)
		if fi != -1:
			var fe := value.find(")", fi)
			if fe != -1:
				return value.substr(fi, fe - fi + 1)
	for tok in value.split(" ", false):
		tok = tok.strip_edges()
		if tok.begins_with("#"):
			return tok
		if tok != "" and not tok.begins_with("url(") and CSS_COLOR_NAMES.has(tok):
			return tok
	return ""


## Имена CSS-цветов, которые встречаются на практике как фон/цвет документа. Полную
## таблицу X11 не тащим — геометрия всё равно валидирует через Color.from_string.
const CSS_COLOR_NAMES := {
	"black": true, "white": true, "red": true, "green": true, "blue": true,
	"yellow": true, "orange": true, "purple": true, "gray": true, "grey": true,
	"silver": true, "maroon": true, "olive": true, "lime": true, "aqua": true,
	"teal": true, "navy": true, "fuchsia": true, "pink": true, "brown": true,
	"cyan": true, "magenta": true, "gold": true, "beige": true, "ivory": true,
	"indigo": true, "violet": true, "transparent": false,
}


## Удаляет /* … */ комментарии из CSS перед разбором.
func _strip_css_comments(css: String) -> String:
	while true:
		var open := css.find("/*")
		if open == -1:
			break
		var close := css.find("*/", open + 2)
		if close == -1:
			css = css.substr(0, open)
			break
		css = css.substr(0, open) + css.substr(close + 2)
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


## Значение свойства из блока объявлений. Свойство ищется на границе (начало / ';' / '{' /
## пробел слева, опц. пробелы и ':' справа) — иначе `color` ловился бы внутри
## `background-color`, а `background` — внутри `background-image`. Возвращает значение до ';'.
func _extract_css_value(style: String, prop: String) -> String:
	var from := 0
	while true:
		var idx := style.find(prop, from)
		if idx == -1:
			return ""
		var left_ok := idx == 0
		if not left_ok:
			var lc := style[idx - 1]
			left_ok = lc == ";" or lc == "{" or lc == " " or lc == "\t" or lc == "\n"
		var j := idx + prop.length()
		while j < style.length() and (style[j] == " " or style[j] == "\t" or style[j] == "\n"):
			j += 1
		if left_ok and j < style.length() and style[j] == ":":
			var end := style.find(";", j + 1)
			if end == -1:
				end = style.length()
			return style.substr(j + 1, end - j - 1).strip_edges()
		from = idx + prop.length()
	return ""


## Элемент невидим «для глаза» — выкидываем на фазе линеаризации.
## Внешний CSS не резолвится (нет движка/рендера), поэтому ловим только надёжные
## инлайновые признаки и атрибуты, не требующие layout-пасса.
func _is_hidden(node: HtmlNode) -> bool:
	# Атрибуты, явно убирающие элемент из видимого/доступного дерева.
	if node.has_attr("hidden"):
		return true
	if node.get_attr("aria-hidden").to_lower() == "true":
		return true
	if node.tag == "input" and node.get_attr("type").to_lower() == "hidden":
		return true

	# Дальше — только инлайновый style (нижний регистр, без пробелов).
	var style := node.get_attr("style").to_lower().replace(" ", "")
	if style == "":
		return false
	if style.contains("display:none") or style.contains("visibility:hidden"):
		return true
	# Нулевая (или почти нулевая) альфа.
	var opacity := _inline_css(style, "opacity")
	if opacity.is_valid_float() and opacity.to_float() <= 0.01:
		return true
	# Схлопнутый в ноль бокс.
	if _length_px(_inline_css(style, "width")) == 0.0 \
			or _length_px(_inline_css(style, "height")) == 0.0:
		return true
	# Унесён за экран (классические visually-hidden техники).
	if _is_offscreen(style):
		return true
	# Обрезан в ноль клипом (старый clip / современный clip-path).
	if style.contains("clip-path:inset(100%)") \
			or style.contains("clip:rect(0,0,0,0)") \
			or style.contains("clip:rect(0px,0px,0px,0px)"):
		return true
	return false


## Спозиционирован далеко за пределами экрана (off-screen hiding).
## style — нижний регистр, без пробелов. Относительные единицы (%, em) дают -1.0
## из _length_px и не срабатывают — это намеренно, в метры их не перевести.
func _is_offscreen(style: String) -> bool:
	# text-indent в большой минус — приём скрытия текста (image replacement).
	if _length_px(_inline_css(style, "text-indent")) <= -999.0:
		return true
	var pos := _inline_css(style, "position")
	if pos != "absolute" and pos != "fixed":
		return false
	return _length_px(_inline_css(style, "left")) <= -999.0 \
			or _length_px(_inline_css(style, "top")) <= -999.0


## Значение инлайн-свойства с учётом границы свойства: ищет ";prop:" в
## дополненной строке, поэтому "width" не ловится внутри "min-width"/"max-width".
## style должен быть в нижнем регистре без пробелов.
func _inline_css(style: String, prop: String) -> String:
	var hay := ";" + style
	var key := ";" + prop + ":"
	var idx := hay.find(key)
	if idx == -1:
		return ""
	var start := idx + key.length()
	var end := hay.find(";", start)
	if end == -1:
		end = hay.length()
	return hay.substr(start, end - start)


func _alloc() -> int:
	var id := _next_id
	_next_id += 1
	return id
