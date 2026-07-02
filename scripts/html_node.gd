class_name HtmlNode
extends RefCounted

## Узел дерева HTML. Промежуточное представление между сырым HTML и топологией.
## tag == "#text" — текстовый узел (значимый текст в .text).
## tag == "#document" — корень документа.

const TEXT := "#text"
const DOCUMENT := "#document"

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


## Реконструирует HTML-разметку поддерева (для отладки: какой кусок страницы стал
## этим узлом топологии). Не байт-в-байт исходник — нормализованная пересборка
## дерева с отступами; этого достаточно, чтобы глазами сопоставить узел и контент.
func to_html(indent: int = 0) -> String:
	var pad := "  ".repeat(indent)
	if is_text():
		return pad + text.strip_edges()
	if tag == DOCUMENT:
		var parts: PackedStringArray = []
		for c in children:
			parts.append(c.to_html(indent))
		return "\n".join(parts)

	var attr_str := ""
	for k in attributes:
		attr_str += " %s=\"%s\"" % [k, attributes[k]]
	var open_tag := "<%s%s>" % [tag, attr_str]

	if children.is_empty():
		return pad + open_tag
	# Один текстовый ребёнок — инлайним, чтобы не плодить переносы.
	if children.size() == 1 and children[0].is_text():
		return "%s%s%s</%s>" % [pad, open_tag, children[0].text.strip_edges(), tag]
	var inner: PackedStringArray = []
	for c in children:
		inner.append(c.to_html(indent + 1))
	return "%s%s\n%s\n%s</%s>" % [pad, open_tag, "\n".join(inner), pad, tag]
