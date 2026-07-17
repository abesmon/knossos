class_name HtmlParser
extends RefCounted

## Снисходительный (lenient) парсер HTML в дерево [HtmlNode].
## В Godot нет нативного HTML-парсера (XMLParser требует валидный XML), поэтому
## здесь намеренно прощающий токенайзер: обрабатывает незакрытые теги, void-элементы,
## комментарии, doctype и raw-text элементы (script/style). Достаточно для Phase 1,
## где HTML приходит уже готовым (без исполнения JS).

## Таблицы void/raw-text тегов живут в HtmlNode (единый источник для парсера и to_html).
const VOID_TAGS := HtmlNode.VOID_TAGS
const RAW_TEXT_TAGS := HtmlNode.RAW_TEXT_TAGS


static func parse(html: String) -> HtmlNode:
	var root := HtmlNode.new(HtmlNode.DOCUMENT)
	var stack: Array[HtmlNode] = [root]
	var n := html.length()
	var i := 0

	while i < n:
		var ch := html[i]
		if ch == "<":
			# Комментарий <!-- ... -->
			if html.substr(i, 4) == "<!--":
				var end := html.find("-->", i + 4)
				i = (n if end == -1 else end + 3)
				continue
			# Doctype / прочие <! ... >
			if i + 1 < n and html[i + 1] == "!":
				var end := html.find(">", i)
				i = (n if end == -1 else end + 1)
				continue
			# Закрывающий тег </name>
			if i + 1 < n and html[i + 1] == "/":
				var end := html.find(">", i)
				if end == -1:
					break
				var close_name := html.substr(i + 2, end - (i + 2)).strip_edges().to_lower()
				if close_name == "br":
					# Кривой </br> по HTML-спеку эквивалентен <br> (частая ошибка вёрстки,
					# напр. шаблонизаторы). br — void, на стеке его нет, иначе тег потерялся бы.
					stack[-1].add_child(HtmlNode.new("br"))
				else:
					_close_tag(stack, close_name)
				i = end + 1
				continue
			# Открывающий тег <name ...>
			var gt := html.find(">", i)
			if gt == -1:
				break
			var raw := html.substr(i + 1, gt - (i + 1))
			var self_closing := raw.ends_with("/")
			if self_closing:
				raw = raw.substr(0, raw.length() - 1)
			var parsed := _parse_open_tag(raw)
			var tag_name: String = parsed["name"]
			if tag_name == "":
				i = gt + 1
				continue
			var node := HtmlNode.new(tag_name)
			node.raw_tag = parsed["raw_name"]
			node.attributes = parsed["attrs"]
			stack[-1].add_child(node)
			i = gt + 1

			if RAW_TEXT_TAGS.has(tag_name):
				# Проглатываем содержимое до закрывающего тега, разметку внутри игнорируем.
				var close_marker := "</" + tag_name
				var close_pos := html.findn(close_marker, i)
				var content_end := (n if close_pos == -1 else close_pos)
				# Raw-text сохраняется без разбора разметки. TopologyBuilder исключает
				# script/style/head из визуальной сцены.
				if tag_name == "textarea" or tag_name == "title" \
						or tag_name == "style" or tag_name == "script":
					var txt := html.substr(i, content_end - i)
					if txt.strip_edges() != "":
						var tnode := HtmlNode.new(HtmlNode.TEXT)
						tnode.text = txt
						node.add_child(tnode)
				if close_pos == -1:
					i = n
				else:
					var close_gt := html.find(">", close_pos)
					i = (n if close_gt == -1 else close_gt + 1)
				continue

			if not self_closing and not VOID_TAGS.has(tag_name):
				stack.append(node)
		else:
			# Текстовый узел до следующего '<'.
			var next := html.find("<", i)
			var text_end := (n if next == -1 else next)
			var raw_text := html.substr(i, text_end - i)
			# Схлопываем пробелы, но СОХРАНЯЕМ граничный одиночный пробел — иначе
			# inline-ссылки склеятся с соседним текстом («слово<a>ссылка</a>»).
			var normalized := _collapse_ws(_decode_entities(raw_text))
			if normalized != "":
				var tnode := HtmlNode.new(HtmlNode.TEXT)
				tnode.text = normalized
				stack[-1].add_child(tnode)
			i = text_end

	return root


## Закрывает тег: снимает стек до ближайшего совпадающего элемента включительно.
## Если совпадения нет — игнорирует «висячий» закрывающий тег.
static func _close_tag(stack: Array[HtmlNode], name: String) -> void:
	for idx in range(stack.size() - 1, 0, -1):
		if stack[idx].tag == name:
			stack.resize(idx)
			return
	# нет открытого такого тега — игнор


## Разбирает внутренность открывающего тега: имя и атрибуты.
static func _parse_open_tag(raw: String) -> Dictionary:
	raw = raw.strip_edges()
	var attrs: Dictionary = {}
	var name := ""
	var i := 0
	var n := raw.length()

	# имя тега
	while i < n and not _is_space(raw[i]):
		name += raw[i]
		i += 1
	var raw_name := name           # исходный регистр (vrweb-теги — классы Godot, PascalCase)
	name = name.to_lower()

	while i < n:
		while i < n and _is_space(raw[i]):
			i += 1
		if i >= n:
			break
		# имя атрибута
		var attr_name := ""
		while i < n and not _is_space(raw[i]) and raw[i] != "=":
			attr_name += raw[i]
			i += 1
		attr_name = attr_name.to_lower()
		while i < n and _is_space(raw[i]):
			i += 1
		var value := ""
		if i < n and raw[i] == "=":
			i += 1
			while i < n and _is_space(raw[i]):
				i += 1
			if i < n and (raw[i] == "\"" or raw[i] == "'"):
				var quote := raw[i]
				i += 1
				var start := i
				while i < n and raw[i] != quote:
					i += 1
				value = raw.substr(start, i - start)
				i += 1
			else:
				var start2 := i
				while i < n and not _is_space(raw[i]):
					i += 1
				value = raw.substr(start2, i - start2)
		if attr_name != "":
			attrs[attr_name] = _decode_entities(value)

	return {"name": name, "raw_name": raw_name, "attrs": attrs}


static func _is_space(c: String) -> bool:
	return c == " " or c == "\t" or c == "\n" or c == "\r"


## Схлопывает любые последовательности пробелов в один пробел, сохраняя по одному
## граничному пробелу слева/справа. Чисто пробельный сегмент → ОДИН пробел (как в браузере:
## перевод строки/отступы между inline-элементами схлопываются в пробел, `<a>A</a> <a>B</a>`
## → «A B»). Между блоками этот пробел отбрасывается топологией (`_classify` пропускает
## пробельные узлы; в абзаце же он сохраняется). Пустая строка → "".
static func _collapse_ws(s: String) -> String:
	var out := ""
	var in_ws := false
	for i in s.length():
		var c := s[i]
		if _is_space(c):
			in_ws = true
		else:
			if in_ws:
				out += " "
			out += c
			in_ws = false
	if in_ws:
		out += " "
	if out == "":
		return ""
	return out


## Минимальное декодирование HTML-сущностей (самые частые).
static func _decode_entities(s: String) -> String:
	if not s.contains("&"):
		return s
	s = _decode_numeric_entities(s)
	s = s.replace("&amp;", "&")
	s = s.replace("&lt;", "<")
	s = s.replace("&gt;", ">")
	s = s.replace("&quot;", "\"")
	s = s.replace("&#39;", "'")
	s = s.replace("&apos;", "'")
	s = s.replace("&nbsp;", " ")
	s = s.replace("&mdash;", "—")
	s = s.replace("&ndash;", "–")
	return s


static func _decode_numeric_entities(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "&" and i + 2 < s.length() and s[i + 1] == "#":
			var end := s.find(";", i + 2)
			if end != -1:
				var token := s.substr(i + 2, end - (i + 2))
				var codepoint := _parse_entity_codepoint(token)
				if _valid_codepoint(codepoint):
					out += String.chr(codepoint)
					i = end + 1
					continue
		out += s[i]
		i += 1
	return out


static func _parse_entity_codepoint(token: String) -> int:
	if token == "":
		return -1
	if token.begins_with("x") or token.begins_with("X"):
		return _parse_hex_codepoint(token.substr(1))
	if not token.is_valid_int():
		return -1
	return token.to_int()


static func _parse_hex_codepoint(hex: String) -> int:
	if hex == "":
		return -1
	var value := 0
	for i in hex.length():
		var c := hex[i]
		var digit := -1
		if c >= "0" and c <= "9":
			digit = c.unicode_at(0) - "0".unicode_at(0)
		elif c >= "a" and c <= "f":
			digit = 10 + c.unicode_at(0) - "a".unicode_at(0)
		elif c >= "A" and c <= "F":
			digit = 10 + c.unicode_at(0) - "A".unicode_at(0)
		else:
			return -1
		value = value * 16 + digit
		if value > 0x10ffff:
			return -1
	return value


static func _valid_codepoint(codepoint: int) -> bool:
	return codepoint > 0 and codepoint <= 0x10ffff and not (codepoint >= 0xd800 and codepoint <= 0xdfff)
