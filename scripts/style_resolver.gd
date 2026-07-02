class_name StyleResolver
extends RefCounted

## Мини-каскад CSS (docs/css-cascade.md): применяет правила CssParser к дереву HtmlNode
## и аннотирует каждый элемент вычисленным подмножеством стилей — node.computed.
## Чистый (без I/O): тексты таблиц загружает CssFetcher, порядок текстов = порядок
## документа = порядок каскада. Layout не считается — за ним будущий GDExtension-движок,
## который заполнит тот же контракт computed точнее (+боксы).
##
## node.computed (ключи присутствуют, когда известны; пустой словарь = резолвер не бежал):
##   color: Color, "color-own": bool     # own = у узла своя победившая декларация
##   "background-color": Color           # только собственная; нет если transparent
##   "background-image": String          # сырой url-токен (не резолвлен)
##   border: bool
##   "font-size": float                  # абсолютные px, всегда (наследование учтено)
##   "font-weight": int                  # 100..900, всегда
##   "text-align": String                # наследуется
##   display/visibility/opacity          # когда объявлены (visibility наследуется)
##   hidden: bool                        # готовый вердикт «невидим для глаза»

const DEFAULT_FONT_PX := 16.0
const VAR_DEPTH := 4  # предел вложенной подстановки var(--x)

## Кегли ключевых слов font-size (приближение браузерных дефолтов).
const FONT_KEYWORDS := {
	"xx-small": 9.0, "x-small": 10.0, "small": 13.0, "medium": 16.0,
	"large": 18.0, "x-large": 24.0, "xx-large": 32.0,
}

## Дефолты <font size="N"> в px (презентационный атрибут, олдскульная разметка).
const FONT_ATTR_PX := {1: 10.0, 2: 13.0, 3: 16.0, 4: 18.0, 5: 24.0, 6: 32.0, 7: 48.0}

# Индекс правил по правому compound-селектору: кандидаты на узел = объединение его
# бакетов (десятки правил вместо тысяч). Правило лежит ровно в одном бакете.
var _by_id := {}
var _by_class := {}
var _by_tag := {}
var _universal: Array = []
var _root_px := DEFAULT_FONT_PX  # computed font-size <html> — база для rem


## Ссылки на таблицы в порядке документа: [{kind:"inline", text, media} |
## {kind:"link", href, media}]. Загрузку внешних (link) делает вызывающий (CssFetcher).
static func collect_sheet_refs(root: HtmlNode) -> Array:
	var out: Array = []
	_collect_refs(root, out)
	return out


static func _collect_refs(n: HtmlNode, out: Array) -> void:
	if n.tag == "style":
		out.append({"kind": "inline", "text": n.collect_text(), "media": n.get_attr("media")})
	elif n.tag == "link":
		var rel := n.get_attr("rel").to_lower()
		if rel.split(" ", false).has("stylesheet") and not rel.contains("alternate"):
			var href := n.get_attr("href").strip_edges()
			if href != "":
				out.append({"kind": "link", "href": href, "media": n.get_attr("media")})
	for c in n.children:
		_collect_refs(c, out)


## Каскад по дереву: css_texts — тексты таблиц в порядке документа (недоступные — "").
## Аннотирует node.computed на месте. Вызывается и с пустым списком: тогда computed
## отражает только инлайн style/презентационные атрибуты (единый путь для всех страниц).
static func resolve(root: HtmlNode, css_texts: Array) -> void:
	var r := StyleResolver.new()
	var rules: Array = []
	var order_base := 0
	for t in css_texts:
		var sheet := CssParser.parse(String(t), order_base)
		order_base += sheet.size()
		rules.append_array(sheet)
	r._index(rules)
	var ctx := {
		"font-size": DEFAULT_FONT_PX, "font-weight": 400,
		"color": null, "visibility": "", "text-align": "", "vars": {},
	}
	if root.find_descendant("html") == null:
		# Страница-фрагмент без явного <html>: прогоняем каскад по виртуальному корню,
		# чтобы :root-правила (--переменные, база для rem) не терялись.
		ctx = r._ctx_for(HtmlNode.new("html"), [], ctx)
	for c in root.children:
		if not c.is_text():
			r._dfs(c, [], ctx)


func _index(rules: Array) -> void:
	for rule in rules:
		var last: Dictionary = (rule["parts"] as Array).back()
		if last["id"] != "":
			_bucket(_by_id, last["id"], rule)
		elif not (last["classes"] as Array).is_empty():
			_bucket(_by_class, (last["classes"] as Array)[0], rule)
		elif last["tag"] != "":
			_bucket(_by_tag, last["tag"], rule)
		else:
			_universal.append(rule)


func _bucket(index: Dictionary, key: String, rule: Dictionary) -> void:
	if not index.has(key):
		index[key] = []
	(index[key] as Array).append(rule)


## Один DFS: матчинг -> победитель по свойству -> вычисление относительно родителя.
## ancestors — стек info-словарей предков (root..родитель) для комбинаторов.
func _dfs(node: HtmlNode, ancestors: Array, parent_ctx: Dictionary) -> void:
	var ctx := _ctx_for(node, ancestors, parent_ctx)
	ancestors.push_back(_node_info(node))
	for c in node.children:
		if not c.is_text():
			_dfs(c, ancestors, ctx)
	ancestors.pop_back()


## Каскад для одного узла: кандидаты -> победители по свойствам -> node.computed.
## Возвращает контекст наследования для детей.
func _ctx_for(node: HtmlNode, ancestors: Array, parent_ctx: Dictionary) -> Dictionary:
	var info := _node_info(node)
	var win := {}  # prop -> {v, short?, tier, spec, order}
	_apply_presentational(node, win)
	for rule in _candidates(info):
		if _sel_matches(rule, info, ancestors):
			for prop in rule["decls"]:
				var d: Dictionary = rule["decls"][prop]
				_consider(win, prop, d, 2 if d["imp"] else 0, rule["spec"], rule["order"])
	var inline_style := node.get_attr("style")
	if inline_style != "":
		var decls := CssParser.parse_declarations(inline_style)
		for prop in decls:
			var d: Dictionary = decls[prop]
			_consider(win, prop, d, 3 if d["imp"] else 1, 0, 0)

	# Кастомные свойства: наследуются; копия только когда у узла свои.
	var vars: Dictionary = parent_ctx["vars"]
	var has_own_vars := false
	for prop in win:
		if (prop as String).begins_with("--"):
			if not has_own_vars:
				vars = vars.duplicate()
				has_own_vars = true
			vars[prop] = win[prop]["v"]

	var ctx := _compute(node, win, parent_ctx, vars)
	if node.tag == "html":
		_root_px = ctx["font-size"]
	return ctx


## Презентационные атрибуты — самый слабый тир каскада (-1).
func _apply_presentational(node: HtmlNode, win: Dictionary) -> void:
	if node.has_attr("bgcolor"):
		_consider(win, "background-color", {"v": node.get_attr("bgcolor")}, -1, 0, 0)
	if node.tag == "body" and node.has_attr("text"):
		_consider(win, "color", {"v": node.get_attr("text")}, -1, 0, 0)
	if node.get_attr("align").to_lower() == "center" or node.tag == "center":
		_consider(win, "text-align", {"v": "center"}, -1, 0, 0)
	match node.tag:
		"font":
			var sz := node.get_attr("size").strip_edges()
			if sz.is_valid_int():
				var px: float = FONT_ATTR_PX.get(clampi(int(sz), 1, 7), 0.0)
				if px > 0.0:
					_consider(win, "font-size", {"v": "%dpx" % int(px)}, -1, 0, 0)
			if node.has_attr("color"):
				_consider(win, "color", {"v": node.get_attr("color")}, -1, 0, 0)
		"big":
			_consider(win, "font-size", {"v": "1.2em"}, -1, 0, 0)
		"small":
			_consider(win, "font-size", {"v": "0.83em"}, -1, 0, 0)


func _consider(win: Dictionary, prop: String, d: Dictionary, tier: int, spec: int, order: int) -> void:
	var old: Variant = win.get(prop)
	if old != null:
		if old["tier"] > tier:
			return
		if old["tier"] == tier and old["spec"] > spec:
			return
		if old["tier"] == tier and old["spec"] == spec and old["order"] > order:
			return
	win[prop] = {"v": d["v"], "short": d.get("short", false), "tier": tier, "spec": spec, "order": order}


func _node_info(node: HtmlNode) -> Dictionary:
	var classes := node.get_attr("class").split(" ", false) if node.has_attr("class") else PackedStringArray()
	return {"node": node, "tag": node.tag, "id": node.get_attr("id"), "classes": classes}


func _candidates(info: Dictionary) -> Array:
	var out: Array = []
	if info["id"] != "" and _by_id.has(info["id"]):
		out.append_array(_by_id[info["id"]])
	for cl in info["classes"]:
		if _by_class.has(cl):
			out.append_array(_by_class[cl])
	if _by_tag.has(info["tag"]):
		out.append_array(_by_tag[info["tag"]])
	out.append_array(_universal)
	return out


# --- Матчинг селекторов ---

func _sel_matches(rule: Dictionary, info: Dictionary, ancestors: Array) -> bool:
	var parts: Array = rule["parts"]
	if not _part_matches(parts.back(), info):
		return false
	return _match_left(parts, rule["combinators"], parts.size() - 2, ancestors, ancestors.size() - 1)


## Части селектора левее совмещаются с предками (top — верхняя доступная позиция стека).
## Потомок (" ") перебирает предков с бэктрекингом: жадный ближайший матч может
## провалить хвост, который прошёл бы на более дальнем предке (`a > b c`).
func _match_left(parts: Array, combs: Array, pi: int, ancestors: Array, top: int) -> bool:
	if pi < 0:
		return true
	if combs[pi] == ">":
		if top < 0 or not _part_matches(parts[pi], ancestors[top]):
			return false
		return _match_left(parts, combs, pi - 1, ancestors, top - 1)
	var k := top
	while k >= 0:
		if _part_matches(parts[pi], ancestors[k]) \
				and _match_left(parts, combs, pi - 1, ancestors, k - 1):
			return true
		k -= 1
	return false


func _part_matches(part: Dictionary, info: Dictionary) -> bool:
	if part["tag"] != "" and part["tag"] != "*" and part["tag"] != info["tag"]:
		return false
	if part["id"] != "" and part["id"] != info["id"]:
		return false
	for cl in part["classes"]:
		if not (info["classes"] as PackedStringArray).has(cl):
			return false
	for a in part["attrs"]:
		if not (info["node"] as HtmlNode).has_attr(a):
			return false
	return true


# --- Вычисление значений ---

## Победившие декларации -> node.computed; возвращает контекст для детей.
func _compute(node: HtmlNode, win: Dictionary, parent: Dictionary, vars: Dictionary) -> Dictionary:
	var c := {}

	# font-size: относительные единицы резолвятся против родителя -> абсолютные px.
	var font_px: float = parent["font-size"]
	if win.has("font-size"):
		var raw := _value(win["font-size"], vars)
		if win["font-size"]["short"]:
			raw = _font_shorthand_size(raw)
		var px := _font_size_value(raw, parent["font-size"])
		if px > 0.0:
			font_px = px
	c["font-size"] = font_px

	var weight: int = parent["font-weight"]
	if win.has("font-weight"):
		weight = _font_weight_value(_value(win["font-weight"], vars), parent["font-weight"], weight)
	c["font-weight"] = weight

	# color наследуется; own-флаг отличает собственную декларацию от унаследованной,
	# иначе цвет body покрасил бы fg-хинт каждой комнаты.
	var color: Variant = parent["color"]
	var color_own := false
	if win.has("color"):
		var raw := _value(win["color"], vars)
		var low := raw.to_lower().strip_edges()
		if low == "currentcolor" or low == "inherit":
			color_own = parent["color"] != null
		else:
			var parsed: Variant = CssParser.parse_color(raw)
			if parsed != null:
				color = parsed
				color_own = true
	if color != null:
		c["color"] = color
		if color_own:
			c["color-own"] = true

	if win.has("background-color"):
		var raw := _value(win["background-color"], vars)
		if win["background-color"]["short"]:
			raw = CssParser.color_token(raw)
		if raw.to_lower().strip_edges() == "currentcolor":
			if color != null:
				c["background-color"] = color
		else:
			var parsed: Variant = CssParser.parse_color(raw)
			if parsed != null:
				c["background-color"] = parsed

	if win.has("background-image"):
		var url := CssParser.extract_url(_value(win["background-image"], vars))
		if url != "":
			c["background-image"] = url

	if win.has("border"):
		var b := _value(win["border"], vars).to_lower().strip_edges()
		if b != "" and b != "none" and b != "0" and b != "hidden" and not b.begins_with("0px") \
				and not b.begins_with("0 "):
			c["border"] = true

	var align: String = parent["text-align"]
	if win.has("text-align"):
		align = _value(win["text-align"], vars).to_lower().strip_edges()
	if align != "":
		c["text-align"] = align

	if win.has("display"):
		c["display"] = _value(win["display"], vars).to_lower().strip_edges()
	var visibility: String = parent["visibility"]  # наследуется (visible у ребёнка перекрывает)
	if win.has("visibility"):
		visibility = _value(win["visibility"], vars).to_lower().strip_edges()
	if visibility != "":
		c["visibility"] = visibility
	if win.has("opacity"):
		var op := _value(win["opacity"], vars).strip_edges()
		if op.is_valid_float():
			c["opacity"] = op.to_float()

	if _hidden_verdict(c, win, vars):
		c["hidden"] = true

	node.computed = c
	return {
		"font-size": font_px, "font-weight": weight, "color": color,
		"visibility": visibility, "text-align": align, "vars": vars,
	}


## Та же эвристика «невидим для глаза», что и инлайновая в TopologyBuilder._is_hidden,
## но по каскадному набору — ловит скрытие через классы (.sr-only и т.п.).
func _hidden_verdict(c: Dictionary, win: Dictionary, vars: Dictionary) -> bool:
	if c.get("display", "") == "none":
		return true
	var vis: String = c.get("visibility", "")
	if vis == "hidden" or vis == "collapse":
		return true
	if c.get("opacity", 1.0) <= 0.01:
		return true
	if _win_len(win, "width", vars) == 0.0 or _win_len(win, "height", vars) == 0.0:
		return true
	if _win_len(win, "text-indent", vars) <= -999.0:
		return true
	var pos := _win_value(win, "position", vars)
	if pos == "absolute" or pos == "fixed":
		if _win_len(win, "left", vars) <= -999.0 or _win_len(win, "top", vars) <= -999.0:
			return true
	var clip := _win_value(win, "clip-path", vars).replace(" ", "")
	if clip.begins_with("inset(100%"):
		return true
	clip = _win_value(win, "clip", vars).replace(" ", "")
	if clip == "rect(0,0,0,0)" or clip == "rect(0px,0px,0px,0px)":
		return true
	return false


func _win_value(win: Dictionary, prop: String, vars: Dictionary) -> String:
	if not win.has(prop):
		return ""
	return _value(win[prop], vars).to_lower().strip_edges()


## Длина свойства в px; «нет декларации/не абсолютная» -> прокидывает -1 (не срабатывает).
## Относительные единицы (%/em) намеренно дают -1 — ложно скрыть видимое дороже.
func _win_len(win: Dictionary, prop: String, vars: Dictionary) -> float:
	var v := _win_value(win, prop, vars)
	if v == "":
		return -1.0
	return CssParser.length_px(v)


## Значение декларации с подстановкой var(--x[, fallback]).
func _value(entry: Dictionary, vars: Dictionary) -> String:
	var v: String = entry["v"]
	if not v.contains("var("):
		return v
	return _subst_vars(v, vars, 0)


func _subst_vars(v: String, vars: Dictionary, depth: int) -> String:
	if depth >= VAR_DEPTH:
		return v
	var idx := v.find("var(")
	if idx == -1:
		return v
	# Парная скобка с учётом вложенности (var(--a, var(--b)) валиден).
	var i := idx + 4
	var level := 1
	var n := v.length()
	while i < n and level > 0:
		var ch := v.unicode_at(i)
		if ch == 40:
			level += 1
		elif ch == 41:
			level -= 1
		i += 1
	if level != 0:
		return v
	var inner := v.substr(idx + 4, i - idx - 5)
	var comma := CssParser._split_top(inner, ",")
	var name := String(comma[0]).strip_edges()
	var fallback := ""
	if comma.size() > 1:
		fallback = inner.substr(String(comma[0]).length() + 1).strip_edges()
	var repl := String(vars.get(name, fallback))
	var out := v.substr(0, idx) + repl + v.substr(i)
	return _subst_vars(out, vars, depth + 1)


## font-size -> px против родителя: px/pt/число — абсолют, em/% — от родителя,
## rem — от корня (<html>), ключевые слова — таблица/родитель x1.2.
func _font_size_value(value: String, parent_px: float) -> float:
	value = value.strip_edges().to_lower()
	if value == "":
		return -1.0
	if value.ends_with("rem"):
		var num := value.substr(0, value.length() - 3).strip_edges()
		return num.to_float() * _root_px if num.is_valid_float() else -1.0
	if value.ends_with("em"):
		var num := value.substr(0, value.length() - 2).strip_edges()
		return num.to_float() * parent_px if num.is_valid_float() else -1.0
	if value.ends_with("%"):
		var num := value.substr(0, value.length() - 1).strip_edges()
		return num.to_float() / 100.0 * parent_px if num.is_valid_float() else -1.0
	var abs_px := CssParser.length_px(value)
	if abs_px > 0.0:
		return abs_px
	if FONT_KEYWORDS.has(value):
		return FONT_KEYWORDS[value]
	match value:
		"larger":
			return parent_px * 1.2
		"smaller":
			return parent_px / 1.2
		"inherit":
			return parent_px
	return -1.0


## Токен кегля из шортхенда font: первый токен-длина/ключевое слово; line-height
## после '/' отрезается.
func _font_shorthand_size(value: String) -> String:
	for tok in CssParser._split_top(value, " "):
		tok = String(tok).strip_edges()
		if tok == "":
			continue
		var size := tok.get_slice("/", 0)
		var low := size.to_lower()
		if FONT_KEYWORDS.has(low) or CssParser.length_px(low) > 0.0 \
				or low.ends_with("em") or low.ends_with("%"):
			return size
	return ""


func _font_weight_value(value: String, parent_weight: int, current: int) -> int:
	value = value.strip_edges().to_lower()
	match value:
		"bold":
			return 700
		"normal":
			return 400
		"bolder":
			return mini(parent_weight + 300, 900)
		"lighter":
			return maxi(parent_weight - 300, 100)
		"inherit":
			return parent_weight
	if value.is_valid_float():
		return clampi(int(value.to_float()), 100, 900)
	return current
