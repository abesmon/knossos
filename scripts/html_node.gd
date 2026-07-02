class_name HtmlNode
extends RefCounted

## Узел дерева HTML. Промежуточное представление между сырым HTML и топологией.
## tag == "#text" — текстовый узел (значимый текст в .text).
## tag == "#document" — корень документа.

const TEXT := "#text"
const DOCUMENT := "#document"

## Элементы без закрывающего тега (единая таблица: парсер и to_html руководствуются ею).
const VOID_TAGS := {
	"area": true, "base": true, "br": true, "col": true, "embed": true,
	"hr": true, "img": true, "input": true, "link": true, "meta": true,
	"param": true, "source": true, "track": true, "wbr": true,
}

## Элементы, чьё содержимое — сырой текст (не парсится как разметка и не экранируется).
const RAW_TEXT_TAGS := {
	"script": true, "style": true, "textarea": true, "title": true,
}

var tag: String = ""
var raw_tag: String = ""            ## имя тега в исходном регистре (для vrweb: классы Godot PascalCase)
var text: String = ""               ## заполнен только для #text
var attributes: Dictionary = {}     ## { имя: значение } в нижнем регистре по ключу
var children: Array[HtmlNode] = []
var computed: Dictionary = {}       ## вычисленные стили (StyleResolver); пусто = каскад не бежал


func _init(p_tag: String = "") -> void:
	tag = p_tag
	raw_tag = p_tag


func add_child(node: HtmlNode) -> void:
	children.append(node)


func is_text() -> bool:
	return tag == TEXT


func get_attr(name: String, default_value: String = "") -> String:
	return attributes.get(name, default_value)


func has_attr(name: String) -> bool:
	return attributes.has(name)


## Рекурсивно собирает весь видимый текст поддерева (нормализуя пробелы).
func collect_text() -> String:
	if is_text():
		return text
	var parts: PackedStringArray = []
	for c in children:
		var t := c.collect_text()
		if t.strip_edges() != "":
			parts.append(t.strip_edges())
	return " ".join(parts)


## Есть ли в поддереве хотя бы один элемент с указанным тегом.
func has_descendant_tag(target: String) -> bool:
	for c in children:
		if c.tag == target:
			return true
		if c.has_descendant_tag(target):
			return true
	return false


## Первый потомок с указанным тегом (поиск в глубину) или null.
func find_descendant(target: String) -> HtmlNode:
	for c in children:
		if c.tag == target:
			return c
		var found := c.find_descendant(target)
		if found != null:
			return found
	return null


## Реконструирует HTML-разметку поддерева. Не байт-в-байт исходник — нормализованная
## пересборка дерева с отступами. Round-trip-безопасна: HtmlParser.parse(to_html()) даёт
## эквивалентное дерево (пустые не-void элементы закрываются, текст и атрибуты
## экранируются, содержимое raw-text тегов идёт как есть). Используется отладочным
## инспектором провенанса и консолью пространства (docs/space-console.md).
func to_html(indent: int = 0) -> String:
	var pad := "  ".repeat(indent)
	if is_text():
		return pad + escape_text(text.strip_edges())
	if tag == DOCUMENT:
		var parts: PackedStringArray = []
		for c in children:
			parts.append(c.to_html(indent))
		return "\n".join(parts)

	var attr_str := ""
	for k in attributes:
		attr_str += " %s=\"%s\"" % [k, escape_attr(str(attributes[k]))]
	# Имя в исходном регистре (vrweb-теги — PascalCase-классы Godot); tag — как запасной.
	var name := raw_tag if raw_tag != "" else tag
	var open_tag := "<%s%s>" % [name, attr_str]

	if VOID_TAGS.has(tag):
		return pad + open_tag
	# Raw-text содержимое (style/title/textarea) — как есть: парсер его не декодирует,
	# экранирование исказило бы, например, CSS-селекторы с «>».
	if RAW_TEXT_TAGS.has(tag):
		var raw := ""
		for c in children:
			raw += c.text
		return "%s%s%s</%s>" % [pad, open_tag, raw.strip_edges(), name]
	if children.is_empty():
		# Пустой не-void элемент обязан закрыться: незакрытый <script>/<div> при повторном
		# парсинге проглотил бы весь остаток документа.
		return "%s%s</%s>" % [pad, open_tag, name]
	# Один текстовый ребёнок — инлайним, чтобы не плодить переносы.
	if children.size() == 1 and children[0].is_text():
		return "%s%s%s</%s>" % [pad, open_tag, escape_text(children[0].text.strip_edges()), name]
	var inner: PackedStringArray = []
	for c in children:
		inner.append(c.to_html(indent + 1))
	return "%s%s\n%s\n%s</%s>" % [pad, open_tag, "\n".join(inner), pad, name]


## Экранирование текстового узла для валидного round-trip через HtmlParser.
static func escape_text(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


## Экранирование значения атрибута (то же + кавычка).
static func escape_attr(s: String) -> String:
	return escape_text(s).replace("\"", "&quot;")
