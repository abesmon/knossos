class_name HtmlNode
extends RefCounted

## Узел дерева HTML. Промежуточное представление между сырым HTML и топологией.
## tag == "#text" — текстовый узел (значимый текст в .text).
## tag == "#document" — корень документа.

const TEXT := "#text"
const DOCUMENT := "#document"

var tag: String = ""
var text: String = ""               ## заполнен только для #text
var attributes: Dictionary = {}     ## { имя: значение } в нижнем регистре по ключу
var children: Array[HtmlNode] = []


func _init(p_tag: String = "") -> void:
	tag = p_tag


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
