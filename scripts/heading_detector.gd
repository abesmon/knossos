class_name HeadingDetector
extends RefCounted

## Детекция заголовков для сегментации пространства (docs/content-sectioning.md §3).
## Заголовок сводится к РАНГУ (1 = старший, как h1; больше = младше). Явные h1..h6
## обрабатывает сам TopologyBuilder (ранг = уровень). Здесь — ВИЗУАЛЬНЫЙ заголовок:
## короткий отдельно стоящий текстовый блок, выделенный кеглем/жирным/классом.
##
## visual_rank() вызывается ТОЛЬКО на pure-inline узлах (короткий инлайновый блок) —
## решение «это отдельный блок, а не жирное слово посреди абзаца» принимает вызывающий.

const MAX_HEADING_WORDS := 8     # длиннее — это выделенный абзац, не заголовок

## Браузерные дефолты <font size="N"> в px (N: 1..7). Для олдскульной разметки.
const FONT_SIZE_PX := {1: 10.0, 2: 13.0, 3: 16.0, 4: 18.0, 5: 24.0, 6: 32.0, 7: 48.0}


## Ранг визуального заголовка 1..6, либо 0 если узел заголовком не является.
static func visual_rank(node: HtmlNode, base_px: float) -> int:
	var text := node.collect_text().strip_edges()
	if text == "":
		return 0
	if _word_count(text) > MAX_HEADING_WORDS:
		return 0

	# Сильнейший сигнал — относительный кегль. Ранг прямо из отношения к базе (§3.3).
	var px := _max_font_px(node, base_px)
	var ratio := (px / base_px) if (px > 0.0 and base_px > 0.0) else 0.0
	if ratio >= 1.2:
		return _rank_from_ratio(ratio)

	# Кегль не выделен — добираем по другим признакам (жирный/класс/центр/капс).
	var bold := _is_all_bold(node)
	var class_hint := _has_heading_class(node)
	var centered := _is_centered(node)
	var allcaps := _is_allcaps(text)

	if class_hint:
		return 3
	if bold and (centered or allcaps):
		return 4
	if bold:
		return 5
	if centered and allcaps:
		return 5
	return 0


static func _rank_from_ratio(ratio: float) -> int:
	if ratio >= 2.0:
		return 1
	if ratio >= 1.7:
		return 2
	if ratio >= 1.4:
		return 3
	if ratio >= 1.2:
		return 4
	return 5


static func _word_count(text: String) -> int:
	return text.split(" ", false).size()


## Максимальный объявленный кегль (в px) по инлайновому поддереву, либо 0 если нигде не
## объявлен. Наследование от внешних предков НЕ учитывается (v1 — см. открытые вопросы §9).
static func _max_font_px(node: HtmlNode, base_px: float) -> float:
	var best := _own_font_px(node, base_px)
	for c in node.children:
		if not c.is_text():
			best = maxf(best, _max_font_px(c, base_px))
	return best


static func _own_font_px(node: HtmlNode, base_px: float) -> float:
	match node.tag:
		"font":
			if node.has_attr("size"):
				var sz := node.get_attr("size").strip_edges()
				if sz.is_valid_int():
					return float(FONT_SIZE_PX.get(clampi(int(sz), 1, 7), 0))
		"big":
			return base_px * 1.2
	var style := node.get_attr("style").to_lower()
	return _font_len_px(_css_value(style, "font-size"), base_px)


## Длина font-size в px: px/число — абсолют; em/rem/% — относительно base_px; ключевые
## слова large/x-large — грубо. Неразбираемое -> 0.
static func _font_len_px(value: String, base_px: float) -> float:
	value = value.strip_edges().to_lower()
	if value == "":
		return 0.0
	if value.ends_with("px"):
		return _to_float_or(value.substr(0, value.length() - 2), 0.0)
	if value.ends_with("rem"):
		return _to_float_or(value.substr(0, value.length() - 3), 0.0) * base_px
	if value.ends_with("em"):
		return _to_float_or(value.substr(0, value.length() - 2), 0.0) * base_px
	if value.ends_with("%"):
		return _to_float_or(value.substr(0, value.length() - 1), 0.0) / 100.0 * base_px
	if value.is_valid_float():
		return value.to_float()
	match value:
		"large", "larger":
			return base_px * 1.2
		"x-large", "xx-large":
			return base_px * 1.5
	return 0.0


static func _to_float_or(s: String, fallback: float) -> float:
	s = s.strip_edges()
	return s.to_float() if s.is_valid_float() else fallback


## true, если ВЕСЬ текст блока жирный (тег b/strong, font-weight:bold/≥600), без голого
## не-жирного текста. Так «<b>Короткая строка</b>» — заголовок, а «<b>Важно:</b> текст» — нет.
static func _is_all_bold(node: HtmlNode) -> bool:
	if _self_bold(node):
		return true
	var any := false
	for c in node.children:
		if c.is_text():
			if c.text.strip_edges() != "":
				return false   # голый не-жирный текст
		else:
			any = true
			if not _is_all_bold(c):
				return false
	return any


static func _self_bold(node: HtmlNode) -> bool:
	if node.tag == "b" or node.tag == "strong":
		return true
	var style := node.get_attr("style").to_lower().replace(" ", "")
	if style.contains("font-weight:bold") or style.contains("font-weight:bolder"):
		return true
	var idx := style.find("font-weight:")
	if idx != -1:
		var num := ""
		var rest := style.substr(idx + len("font-weight:"))
		for i in rest.length():
			var ch := rest[i]
			if ch >= "0" and ch <= "9":
				num += ch
			else:
				break
		if num != "" and int(num) >= 600:
			return true
	return false


static func _has_heading_class(node: HtmlNode) -> bool:
	var s := (node.get_attr("class") + " " + node.get_attr("id")).to_lower()
	return s.contains("title") or s.contains("heading") or s.contains("header") or s.contains("head")


static func _is_centered(node: HtmlNode) -> bool:
	if node.tag == "center":
		return true
	if node.get_attr("align").to_lower() == "center":
		return true
	return node.get_attr("style").to_lower().replace(" ", "").contains("text-align:center")


static func _is_allcaps(text: String) -> bool:
	var up := text.to_upper()
	return text == up and up != text.to_lower()   # есть буквы и все заглавные


static func _css_value(style: String, prop: String) -> String:
	var idx := style.find(prop + ":")
	if idx == -1:
		return ""
	var start := idx + prop.length() + 1
	var end := style.find(";", start)
	if end == -1:
		end = style.length()
	return style.substr(start, end - start).strip_edges()
