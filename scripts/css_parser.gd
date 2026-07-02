class_name CssParser
extends RefCounted

## Парсер CSS-подмножества для мини-каскада (docs/css-cascade.md). НЕ полный движок:
## таблица разбирается в плоский список правил {parts, combinators, spec, order, decls};
## декларации фильтруются по вайтлисту потребляемых пайплайном свойств, правила с
## опустевшими декларациями выбрасываются — главный рычаг производительности на больших
## минифицированных таблицах. Каскад/наследование/вычисление — StyleResolver.
##
## Токенизация обязана уважать вложенность ()/[]/кавычек: в реальном минифицированном CSS
## запятые живут внутри :is(...), а точки с запятой — внутри url(data:...).

## Предполагаемый viewport для @media (десктопная вёрстка; реального окна у топологии нет).
const VIEWPORT_W := 1280.0
const VIEWPORT_H := 800.0

const MAX_SHEET_BYTES := 1_500_000
const MAX_RULES := 20_000

## Свойства, которые потребляет пайплайн (цвета/шрифты/видимость + хинты скрытия).
## Всё остальное отбрасывается на парсинге. Кастомные --* пропускаются отдельно.
const PROP_WHITELIST := {
	"color": true, "background-color": true, "background-image": true, "border": true,
	"font-size": true, "font-weight": true, "text-align": true,
	"display": true, "visibility": true, "opacity": true,
	"width": true, "height": true, "position": true, "left": true, "top": true,
	"text-indent": true, "clip": true, "clip-path": true,
}

# Коды символов для сканеров (unicode_at быстрее посимвольных String-сравнений).
const C_QUOTE := 34      # "
const C_APOS := 39       # '
const C_PAREN_O := 40    # (
const C_PAREN_C := 41    # )
const C_COMMA := 44      # ,
const C_SEMI := 59       # ;
const C_AT := 64         # @
const C_BRACKET_O := 91  # [
const C_BRACKET_C := 93  # ]
const C_BRACE_O := 123   # {
const C_BRACE_C := 125   # }


## Таблица -> плоский список правил. order_base позволяет склеивать несколько таблиц,
## сохраняя сквозной порядок источника (каскад «позже — сильнее» при равной специфичности).
static func parse(text: String, order_base: int = 0) -> Array:
	if text.length() > MAX_SHEET_BYTES:
		text = text.substr(0, MAX_SHEET_BYTES)
	text = strip_comments(text)
	var rules: Array = []
	_parse_region(text, 0, text.length(), rules, order_base)
	return rules


static func _parse_region(text: String, i: int, to: int, rules: Array, order_base: int) -> void:
	while i < to and rules.size() < MAX_RULES:
		while i < to and _is_space_code(text.unicode_at(i)):
			i += 1
		if i >= to:
			return
		var c := text.unicode_at(i)
		if c == C_AT:
			i = _parse_at_rule(text, i, to, rules, order_base)
			continue
		if c == C_BRACE_C or c == C_SEMI:  # рассинхрон/мусор — пропустить символ
			i += 1
			continue
		var brace := _find_code_top(text, i, to, C_BRACE_O)
		if brace == -1:
			return
		var close := _find_matching_brace(text, brace, to)
		if close == -1:
			close = to
		var decls := parse_declarations(text.substr(brace + 1, close - brace - 1))
		if not decls.is_empty():
			for sel in _split_top(text.substr(i, brace - i), ","):
				var rule := _parse_selector(sel)
				if not rule.is_empty():
					rule["decls"] = decls
					rule["order"] = order_base + rules.size()
					rules.append(rule)
		i = close + 1


## @-правило начиная с '@' на позиции i; возвращает позицию продолжения сканирования.
## @media — рекурсия при совпадении запроса; @supports/@layer — спускаемся (считаем true,
## порядок слоёв не моделируем); прочие блоки (@font-face/@keyframes/@page) и
## statement-формы (@import неразвёрнутый/@charset/@namespace) — пропуск целиком.
static func _parse_at_rule(text: String, i: int, to: int, rules: Array, order_base: int) -> int:
	var k := i + 1
	var kw := ""
	while k < to:
		var c := text.unicode_at(k)
		var is_alpha := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 45  # a-z A-Z -
		if not is_alpha:
			break
		kw += char(c if c >= 97 or c == 45 else c + 32)
		k += 1
	var j := k
	while j < to:
		var c := text.unicode_at(j)
		if c == C_BRACE_O or c == C_SEMI:
			break
		j += 1
	if j >= to:
		return to
	if text.unicode_at(j) == C_SEMI:
		return j + 1
	var close := _find_matching_brace(text, j, to)
	if close == -1:
		close = to
	match kw:
		"media":
			if media_matches(text.substr(k, j - k)):
				_parse_region(text, j + 1, close, rules, order_base)
		"supports", "layer":
			_parse_region(text, j + 1, close, rules, order_base)
	return close + 1


## Блок объявлений «prop:value; …» -> {prop: {v, imp[, short]}} по вайтлисту.
## Шортхенды разворачиваются: background -> background-color + background-image (значение
## сырым, извлечение токена — после подстановки var() в резолвере, флаг short);
## font -> font-size (short); border* -> единый хинт border. Используется и для инлайн style.
static func parse_declarations(block: String) -> Dictionary:
	var out := {}
	for decl in _split_top(block, ";"):
		if decl.contains("{"):  # вложенное правило (CSS nesting) — не поддерживаем
			continue
		var colon := decl.find(":")
		if colon == -1:
			continue
		var prop := decl.substr(0, colon).strip_edges().to_lower()
		var value := decl.substr(colon + 1).strip_edges()
		if prop == "" or value == "":
			continue
		var imp := false
		var bang := value.rfind("!")
		if bang != -1 and value.substr(bang + 1).strip_edges().to_lower() == "important":
			imp = true
			value = value.substr(0, bang).strip_edges()
			if value == "":
				continue
		_store_decl(out, prop, value, imp)
	return out


static func _store_decl(out: Dictionary, prop: String, value: String, imp: bool) -> void:
	if prop.begins_with("--"):
		_put_decl(out, prop, {"v": value, "imp": imp})
		return
	match prop:
		"background":
			_put_decl(out, "background-color", {"v": value, "imp": imp, "short": true})
			_put_decl(out, "background-image", {"v": value, "imp": imp, "short": true})
			return
		"font":
			_put_decl(out, "font-size", {"v": value, "imp": imp, "short": true})
			return
	if prop.begins_with("border"):
		match prop:
			"border", "border-width", "border-style", "border-color", \
			"border-top", "border-right", "border-bottom", "border-left":
				_put_decl(out, "border", {"v": value, "imp": imp})
		return
	if PROP_WHITELIST.has(prop):
		_put_decl(out, prop, {"v": value, "imp": imp})


## Внутри одного блока поздняя декларация перекрывает раннюю, но !important не сдаётся
## обычной (color:red!important; color:blue -> red).
static func _put_decl(out: Dictionary, prop: String, entry: Dictionary) -> void:
	var old: Variant = out.get(prop)
	if old != null and old["imp"] and not entry["imp"]:
		return
	out[prop] = entry


# --- Селекторы ---

## Один селектор (без запятых) -> {parts, combinators, spec} либо {} если содержит
## неподдержанное (псевдоклассы кроме :root, +, ~, [attr=v], ::before, …) — тогда
## селектор выбрасывается индивидуально, остальной comma-список живёт.
## parts — compound-селекторы слева направо (правый — последний), combinators между ними.
static func _parse_selector(sel: String) -> Dictionary:
	sel = sel.strip_edges()
	if sel == "":
		return {}
	var parts: Array = []
	var combs: Array = []
	var cur := _new_part()
	var has_cur := false
	var pending := ""
	var spec_a := 0
	var spec_b := 0
	var spec_c := 0
	var i := 0
	var n := sel.length()
	while i < n:
		var c := sel.unicode_at(i)
		if _is_space_code(c):
			if has_cur and pending == "":
				pending = " "
			i += 1
			continue
		if c == 62:  # >
			if not has_cur:
				return {}
			pending = ">"
			i += 1
			continue
		if c == 43 or c == 126:  # + ~
			return {}
		if pending != "":
			parts.append(cur)
			combs.append(pending)
			cur = _new_part()
			has_cur = false
			pending = ""
		match c:
			42:  # *
				has_cur = true
				i += 1
			35:  # #
				var t := _read_ident(sel, i + 1)
				if t == "":
					return {}
				cur["id"] = t
				spec_a += 1
				has_cur = true
				i += 1 + t.length()
			46:  # .
				var t := _read_ident(sel, i + 1)
				if t == "":
					return {}
				(cur["classes"] as Array).append(t)
				spec_b += 1
				has_cur = true
				i += 1 + t.length()
			C_BRACKET_O:
				var close := sel.find("]", i)
				if close == -1:
					return {}
				var inner := sel.substr(i + 1, close - i - 1).strip_edges()
				if _read_ident(inner, 0) != inner or inner == "":
					return {}  # только [attr] по наличию, без значений
				(cur["attrs"] as Array).append(inner.to_lower())
				spec_b += 1
				has_cur = true
				i = close + 1
			58:  # :
				if sel.substr(i, 5) == ":root":
					cur["tag"] = "html"
					spec_c += 1
					has_cur = true
					i += 5
				else:
					return {}
			_:
				var t := _read_ident(sel, i)
				if t == "":
					return {}
				cur["tag"] = t.to_lower()
				spec_c += 1
				has_cur = true
				i += t.length()
	if not has_cur:
		return {}
	parts.append(cur)
	return {
		"parts": parts, "combinators": combs,
		"spec": spec_a * 1_000_000 + spec_b * 1_000 + spec_c,
	}


static func _new_part() -> Dictionary:
	return {"tag": "", "id": "", "classes": [], "attrs": []}


## Идентификатор CSS с позиции from: [a-zA-Z0-9_-] и любые не-ASCII. "" — если пусто.
static func _read_ident(s: String, from: int) -> String:
	var i := from
	var n := s.length()
	while i < n:
		var c := s.unicode_at(i)
		var ok := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) \
				or c == 45 or c == 95 or c > 127
		if not ok:
			break
		i += 1
	return s.substr(from, i - from)


# --- @import (для разворачивания в CssFetcher) ---

## Находит @import-стейтменты: [{href, media, start, end}] (end — за ';'). Текст должен
## быть уже без комментариев (strip_comments), чтобы позиции годились для сплайса.
static func extract_imports(text: String) -> Array:
	var out: Array = []
	var i := 0
	while true:
		var idx := text.findn("@import", i)
		if idx == -1:
			return out
		var semi := text.find(";", idx)
		if semi == -1:
			return out
		var stmt := text.substr(idx + 7, semi - idx - 7).strip_edges()
		var href := ""
		var media := ""
		if stmt.to_lower().begins_with("url("):
			var close := stmt.find(")")
			if close != -1:
				href = _unquote(stmt.substr(4, close - 4).strip_edges())
				media = stmt.substr(close + 1).strip_edges()
		elif stmt.begins_with("\"") or stmt.begins_with("'"):
			var q := stmt.substr(0, 1)
			var close := stmt.find(q, 1)
			if close != -1:
				href = stmt.substr(1, close - 1)
				media = stmt.substr(close + 1).strip_edges()
		if href != "":
			out.append({"href": href, "media": media, "start": idx, "end": semi + 1})
		i = semi + 1
	return out


# --- @media ---

## Совпадает ли media-запрос с предполагаемым десктопным viewport (1280x800, screen).
## Грубая модель: не print/speech, min/max-width|height против viewport, известные
## бинарные фичи; неизвестные фичи считаются истинными (лучше применить лишнее правило,
## чем потерять базовые стили сайта).
static func media_matches(query: String) -> bool:
	query = query.strip_edges().to_lower()
	if query == "" or query == "all" or query == "screen":
		return true
	for part in _split_top(query, ","):
		if _media_one(part.strip_edges()):
			return true
	return false


static func _media_one(q: String) -> bool:
	if q == "":
		return true
	var neg := false
	if q.begins_with("not "):
		neg = true
		q = q.substr(4).strip_edges()
	if q.begins_with("only "):
		q = q.substr(5).strip_edges()
	var ok := true
	var type_word := q.get_slice("(", 0).strip_edges().get_slice(" ", 0)
	if type_word == "print" or type_word == "speech" or type_word == "aural":
		ok = false
	if ok:
		var i := 0
		while true:
			var open := q.find("(", i)
			if open == -1:
				break
			var close := q.find(")", open)
			if close == -1:
				break
			if not _media_feature(q.substr(open + 1, close - open - 1)):
				ok = false
				break
			i = close + 1
	return not ok if neg else ok


static func _media_feature(feat: String) -> bool:
	var name := feat.get_slice(":", 0).strip_edges()
	var value := feat.get_slice(":", 1).strip_edges() if feat.contains(":") else ""
	match name:
		"min-width":
			return VIEWPORT_W >= _media_len(value, -1.0)
		"max-width":
			return VIEWPORT_W <= _media_len(value, 1e12)
		"min-height":
			return VIEWPORT_H >= _media_len(value, -1.0)
		"max-height":
			return VIEWPORT_H <= _media_len(value, 1e12)
		"orientation":
			return value != "portrait"
		"prefers-color-scheme":
			return value != "dark"
	return true  # неизвестная фича — не отфильтровываем правило


## Длина в media-запросе -> px (px/em/rem, em = 16px). Неразбираемое -> fallback
## (чтобы неизвестное значение не отрубало правило).
static func _media_len(value: String, fallback: float) -> float:
	value = value.strip_edges()
	var f := length_px(value)
	if f >= 0.0:
		return f
	if value.ends_with("em"):
		var num := value.trim_suffix("rem").trim_suffix("em").strip_edges()
		if num.is_valid_float():
			return num.to_float() * 16.0
	return fallback


# --- Значения ---

## Токен значения -> Color, либо null (transparent/нераспознанное/альфа≈0).
## currentColor резолвер обрабатывает сам ДО вызова (нужен цвет узла).
static func parse_color(token: String) -> Variant:
	token = token.strip_edges()
	if token == "":
		return null
	var low := token.to_lower()
	match low:
		"transparent", "inherit", "initial", "unset", "revert", "currentcolor", "none":
			return null
	if token.begins_with("#"):
		return Color.html(token) if Color.html_is_valid(token) else null
	if low.begins_with("rgb"):
		return _parse_rgb_func(low)
	if low.begins_with("hsl"):
		return _parse_hsl_func(low)
	var c := Color.from_string(low, Color(-1.0, -1.0, -1.0))
	return c if c.r >= 0.0 else null


static func _parse_rgb_func(v: String) -> Variant:
	var comps := _func_components(v)
	if comps.size() < 3:
		return null
	if comps.size() >= 4 and _color_component(comps[3], false) <= 0.01:
		return null
	return Color(
		_color_component(comps[0], true),
		_color_component(comps[1], true),
		_color_component(comps[2], true))


static func _parse_hsl_func(v: String) -> Variant:
	var comps := _func_components(v)
	if comps.size() < 3:
		return null
	if comps.size() >= 4 and _color_component(comps[3], false) <= 0.01:
		return null
	var h := comps[0].trim_suffix("deg").strip_edges().to_float()
	var s := _color_component(comps[1], false)
	var l := _color_component(comps[2], false)
	# HSL -> HSV: Godot умеет только from_hsv.
	var val := l + s * minf(l, 1.0 - l)
	var sv := 0.0 if val == 0.0 else 2.0 * (1.0 - l / val)
	return Color.from_hsv(fposmod(h, 360.0) / 360.0, sv, val)


## Аргументы функциональной записи цвета: и «255, 0, 0», и современная «255 0 0 / .5».
static func _func_components(v: String) -> PackedStringArray:
	var open := v.find("(")
	var close := v.rfind(")")
	if open == -1 or close <= open:
		return PackedStringArray()
	var inner := v.substr(open + 1, close - open - 1).replace("/", " ").replace(",", " ")
	return inner.split(" ", false)


## Компонента цвета: % -> /100; число -> /255 для rgb-каналов, как есть для s/l/alpha.
static func _color_component(t: String, rgb_channel: bool) -> float:
	t = t.strip_edges()
	if t.ends_with("%"):
		return clampf(t.substr(0, t.length() - 1).to_float() / 100.0, 0.0, 1.0)
	var f := t.to_float()
	return clampf(f / 255.0, 0.0, 1.0) if rgb_channel else clampf(f, 0.0, 1.0)


## Первый токен значения, похожий на цвет (#hex / rgb()/hsl() / имя). Для шортхенда
## `background: #fff url(x) no-repeat` достаёт именно цвет. "" — если цвета нет.
static func color_token(value: String) -> String:
	for fn in ["rgba(", "rgb(", "hsla(", "hsl("]:
		var fi := value.findn(fn)
		if fi != -1:
			var fe := value.find(")", fi)
			if fe != -1:
				return value.substr(fi, fe - fi + 1)
	for tok in _split_top(value, " "):
		tok = tok.strip_edges()
		if tok == "":
			continue
		if tok.begins_with("#"):
			return tok
		var low := tok.to_lower()
		if low == "none" or low == "transparent" or low.contains("("):
			continue
		if not low.is_valid_float() and Color.from_string(low, Color(-1.0, -1.0, -1.0)).r >= 0.0:
			return tok
	return ""


## url(...) -> очищенный путь; "" если url() нет. Снимает кавычки и пробелы.
static func extract_url(value: String) -> String:
	var idx := value.findn("url(")
	if idx == -1:
		return ""
	var start := idx + 4
	var end := value.find(")", start)
	if end == -1:
		return ""
	return _unquote(value.substr(start, end - start).strip_edges())


## Абсолютная длина в CSS-пикселях: «600»/«600px» -> 600.0; pt -> x4/3; прочее -> -1.0.
static func length_px(value: String) -> float:
	value = value.strip_edges().to_lower()
	if value == "":
		return -1.0
	var mult := 1.0
	if value.ends_with("px"):
		value = value.substr(0, value.length() - 2).strip_edges()
	elif value.ends_with("pt"):
		value = value.substr(0, value.length() - 2).strip_edges()
		mult = 4.0 / 3.0
	if value.is_valid_float():
		return value.to_float() * mult
	return -1.0


## Удаляет /* … */ комментарии. Публичный: CssFetcher чистит текст ДО extract_imports,
## чтобы позиции стейтментов годились для сплайса.
static func strip_comments(css: String) -> String:
	if not css.contains("/*"):
		return css
	var out := ""
	var i := 0
	while true:
		var open := css.find("/*", i)
		if open == -1:
			out += css.substr(i)
			return out
		out += css.substr(i, open - i)
		var close := css.find("*/", open + 2)
		if close == -1:
			return out
		i = close + 2
	return out


static func _unquote(s: String) -> String:
	if s.length() >= 2 and (s[0] == "\"" or s[0] == "'") and s[s.length() - 1] == s[0]:
		return s.substr(1, s.length() - 2).strip_edges()
	return s


# --- Сканеры (учитывают кавычки и вложенность скобок) ---

static func _is_space_code(c: int) -> bool:
	return c == 32 or c == 9 or c == 10 or c == 13 or c == 12


## Разбивает строку по разделителю на верхнем уровне вложенности ()/[]/{}/кавычек.
static func _split_top(s: String, sep: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var sep_c := sep.unicode_at(0)
	var depth := 0
	var quote := 0
	var start := 0
	var n := s.length()
	for i in n:
		var c := s.unicode_at(i)
		if quote != 0:
			if c == quote:
				quote = 0
		elif c == C_QUOTE or c == C_APOS:
			quote = c
		elif c == C_PAREN_O or c == C_BRACKET_O or c == C_BRACE_O:
			depth += 1
		elif c == C_PAREN_C or c == C_BRACKET_C or c == C_BRACE_C:
			depth = maxi(0, depth - 1)
		elif c == sep_c and depth == 0:
			out.append(s.substr(start, i - start))
			start = i + 1
	out.append(s.substr(start))
	return out


## Первое вхождение символа target на верхнем уровне вложенности в [from, to). -1 — нет.
static func _find_code_top(s: String, from: int, to: int, target: int) -> int:
	var depth := 0
	var quote := 0
	var i := from
	while i < to:
		var c := s.unicode_at(i)
		if quote != 0:
			if c == quote:
				quote = 0
		elif c == C_QUOTE or c == C_APOS:
			quote = c
		elif c == target and depth == 0:
			return i
		elif c == C_PAREN_O or c == C_BRACKET_O:
			depth += 1
		elif c == C_PAREN_C or c == C_BRACKET_C:
			depth = maxi(0, depth - 1)
		i += 1
	return -1


## Индекс '}' парного открывающей скобке на open_idx (учитывая вложенные блоки и кавычки).
static func _find_matching_brace(s: String, open_idx: int, to: int) -> int:
	var depth := 0
	var quote := 0
	var i := open_idx
	while i < to:
		var c := s.unicode_at(i)
		if quote != 0:
			if c == quote:
				quote = 0
		elif c == C_QUOTE or c == C_APOS:
			quote = c
		elif c == C_BRACE_O:
			depth += 1
		elif c == C_BRACE_C:
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1
