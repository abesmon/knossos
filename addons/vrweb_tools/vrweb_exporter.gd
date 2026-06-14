@tool
class_name VrwebExporter
extends RefCounted

## Экспорт собранной в редакторе Godot-сцены в HTML-документ с тегами <vrweb> —
## ОБРАТНАЯ операция к VrwebBuilder (scripts/vrweb_builder.gd), который читает такой HTML.
##
## Правила зеркалят читателя:
##   * тег узла   = node.get_class() (движковый класс, PascalCase — то, что ClassDB инстанцирует);
##   * атрибуты   = свойства, отличающиеся от дефолта свежесозданного экземпляра класса,
##                  сериализованные var_to_str (Transform3D(...), Vector3(...), числа, "строки") —
##                  ровно формат, который VrwebBuilder читает через str_to_var;
##   * Resource в свойстве -> запись <Resource> + ссылка "SubResource:::<id>";
##   * meta vrweb_ext / vrweb_ext_scene (см. VrwebExtResource) -> <ExtResource>/<ExtScene>;
##   * узел VrwebSpawner с детьми -> мета-тег <VRWebSpawner>/<SpawnerPoint>.
##
## Использование: VrwebExporter.export_scene(get_edited_scene_root(), "combine"|"exclusive").

const SUB_PREFIX := VrwebBuilder.SUBRESOURCE_PREFIX
const EXT_PREFIX := VrwebBuilder.EXTRESOURCE_PREFIX

## Свойства, которые никогда не экспортируем (служебные/неинстанцируемые читателем).
const SKIP_PROPS := {"owner": true, "name": true, "script": true, "scene_file_path": true}

var _sub_order: Array[String] = []          # id'ы суб-ресурсов в порядке появления
var _sub_def: Dictionary = {}               # id -> Resource
var _sub_by_res: Dictionary = {}            # Resource -> id (дедуп по инстансу)
var _sub_seq := 0

var _ext_order: Array[String] = []          # id'ы внешних ресурсов в порядке появления
var _ext_def: Dictionary = {}               # id -> VrwebExtResource
var _ext_by_res: Dictionary = {}            # VrwebExtResource -> id (дедуп)
var _ext_seq := 0

var _defaults: Dictionary = {}              # class -> экземпляр-эталон (Node освобождаем в конце)


## Главный вход: HTML-документ строкой. mode — "combine" (по умолчанию) или "exclusive".
static func export_scene(root: Node, mode: String = VrwebBuilder.MODE_COMBINE) -> String:
	var e := VrwebExporter.new()
	return e._export(root, mode)


func _export(root: Node, mode: String) -> String:
	var safe_mode := mode if mode == VrwebBuilder.MODE_EXCLUSIVE else VrwebBuilder.MODE_COMBINE

	# Сначала строим узлы (попутно наполняются таблицы суб-/внешних ресурсов).
	var body_lines: Array[String] = []
	if root != null:
		for child in root.get_children():
			_build_node(child, 2, body_lines)

	# Затем — определения ресурсов (суб-ресурсы могут ссылаться друг на друга,
	# поэтому идём по растущему списку, пока в нём появляются новые).
	var res_lines: Array[String] = []
	var i := 0
	while i < _sub_order.size():
		var id := _sub_order[i]
		_emit_resource(id, _sub_def[id], res_lines)
		i += 1
	for ext_id in _ext_order:
		_emit_ext(ext_id, _ext_def[ext_id], res_lines)

	_free_defaults()

	var inner := body_lines + res_lines
	var pad := "  "
	var out: Array[String] = []
	out.append("<!DOCTYPE html>")
	out.append("<html>")
	out.append("<head><meta charset=\"utf-8\"><title>VRWeb export</title></head>")
	out.append("<body>")
	out.append(pad + "<vrweb mode=\"%s\">" % safe_mode)
	for line in inner:
		out.append(line)
	out.append(pad + "</vrweb>")
	out.append("</body>")
	out.append("</html>")
	out.append("")
	return "\n".join(out)


# --- Узлы ---

func _build_node(node: Node, depth: int, out: Array[String]) -> void:
	# VrwebSpawner -> мета-тег <VRWebSpawner> (в сцену клиента не инстанцируется).
	if node is VrwebSpawner:
		_build_spawner(node, depth, out)
		return

	# Узел с meta vrweb_ext_scene -> <ExtScene src="ExtResource:::<id>" ...>.
	if node.has_meta(VrwebExtResource.META_SCENE):
		_build_ext_scene(node, depth, out)
		return

	var cls := node.get_class()
	var pad := "  ".repeat(depth)
	var attrs := _node_attrs(node, cls)
	var kids := node.get_children()
	if kids.is_empty():
		out.append("%s<%s%s/>" % [pad, cls, attrs])
		return
	out.append("%s<%s%s>" % [pad, cls, attrs])
	for child in kids:
		_build_node(child, depth + 1, out)
	out.append("%s</%s>" % [pad, cls])


## Строка атрибутов узла: ext-привязки (как "ExtResource:::id") + не-дефолтные свойства.
func _node_attrs(node: Node, cls: String) -> String:
	var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {})
	var parts: Array[String] = []

	# Ext-привязки идут первыми; их реальные свойства из диффа исключаются.
	for prop in bindings:
		var ext_res = bindings[prop]
		if ext_res is VrwebExtResource:
			parts.append("%s=\"%s%s\"" % [prop, EXT_PREFIX, _ext_id(ext_res)])

	parts.append_array(_diff_attrs(node, cls, bindings))
	if parts.is_empty():
		return ""
	return " " + " ".join(parts)


## Атрибуты из свойств, отличающихся от дефолта класса cls. skip_props перекрыты ext-ом.
func _diff_attrs(obj: Object, cls: String, skip_props: Dictionary) -> Array[String]:
	var def = _default_of(cls)
	var parts: Array[String] = []
	for entry in obj.get_property_list():
		var name: String = entry["name"]
		var usage: int = entry["usage"]
		if usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		if SKIP_PROPS.has(name) or skip_props.has(name) or name.begins_with("metadata/"):
			continue
		var value = obj.get(name)
		if def != null and _values_equal(value, def.get(name)):
			continue
		var serialized := _serialize_value(value)
		if serialized == "":
			continue
		parts.append("%s=\"%s\"" % [name, _escape_attr(serialized)])
	return parts


## <ExtScene src="ExtResource:::<id>" <свойства Node3D>/> — плейсхолдер внешней сцены.
func _build_ext_scene(node: Node, depth: int, out: Array[String]) -> void:
	var ext_res = node.get_meta(VrwebExtResource.META_SCENE)
	var pad := "  ".repeat(depth)
	var parts: Array[String] = []
	if ext_res is VrwebExtResource:
		parts.append("src=\"%s%s\"" % [EXT_PREFIX, _ext_id(ext_res)])
	# Свойства Node3D (transform и т.п.) переносим как у обычного узла; класс — Node3D-эталон.
	parts.append_array(_diff_attrs(node, "Node3D", {}))
	var attrs := "" if parts.is_empty() else " " + " ".join(parts)
	out.append("%s<%s%s/>" % [pad, VrwebBuilder.EXT_SCENE_TAG, attrs])


## <VRWebSpawner mode="..."> + <SpawnerPoint transform="..."/> по детям-Node3D.
func _build_spawner(node: VrwebSpawner, depth: int, out: Array[String]) -> void:
	var pad := "  ".repeat(depth)
	out.append("%s<%s mode=\"%s\">" % [pad, VrwebBuilder.SPAWNER_TAG, node.mode])
	var cpad := "  ".repeat(depth + 1)
	for child in node.get_children():
		if child is Node3D:
			var xform: Transform3D = (child as Node3D).transform
			out.append("%s<%s transform=\"%s\"/>" % [
				cpad, VrwebBuilder.SPAWN_POINT_TAG, _escape_attr(var_to_str(xform))])
	out.append("%s</%s>" % [pad, VrwebBuilder.SPAWNER_TAG])


# --- Ресурсы ---

## Сериализует встроенный суб-ресурс: <Resource id="..." type="<class>" <свойства>/>.
func _emit_resource(id: String, res: Resource, out: Array[String]) -> void:
	var cls := res.get_class()
	var parts: Array[String] = ["id=\"%s\"" % id, "type=\"%s\"" % cls]
	parts.append_array(_diff_attrs(res, cls, {}))
	out.append("  %s<%s %s/>" % ["", VrwebBuilder.RESOURCE_TAG, " ".join(parts)])


## Сериализует внешний ресурс: <ExtResource id="..." type="<type>" path="<url>"/>.
func _emit_ext(id: String, ext: VrwebExtResource, out: Array[String]) -> void:
	out.append("  <%s id=\"%s\" type=\"%s\" path=\"%s\"/>" % [
		VrwebBuilder.EXT_RESOURCE_TAG, id, ext.type, _escape_attr(ext.url)])


# --- Сериализация значений ---

## Variant -> строка-значение атрибута (ещё без HTML-escape).
## Resource -> регистрируется суб-ресурсом и отдаётся как "SubResource:::<id>".
## "" означает «не сериализуем» (узел/неподдержанный объект) — атрибут пропускается.
func _serialize_value(value) -> String:
	if value is Resource:
		return SUB_PREFIX + _sub_id(value)
	if value is Object:
		return ""   # узлы и прочие не-Resource объекты в атрибуты не пишем
	return var_to_str(value)


## Сравнение значений с учётом ссылочной природы Resource (одинаковый инстанс == равны).
func _values_equal(a, b) -> bool:
	if a is Resource or b is Resource:
		return a == b
	return typeof(a) == typeof(b) and a == b


# --- Таблицы id ---

func _sub_id(res: Resource) -> String:
	if _sub_by_res.has(res):
		return _sub_by_res[res]
	var id := "r%d" % _sub_seq
	_sub_seq += 1
	_sub_by_res[res] = id
	_sub_def[id] = res
	_sub_order.append(id)
	return id


func _ext_id(ext: VrwebExtResource) -> String:
	if _ext_by_res.has(ext):
		return _ext_by_res[ext]
	var id := "e%d" % _ext_seq
	_ext_seq += 1
	_ext_by_res[ext] = id
	_ext_def[id] = ext
	_ext_order.append(id)
	return id


# --- Эталоны классов (для диффа от дефолта) ---

func _default_of(cls: String):
	if _defaults.has(cls):
		return _defaults[cls]
	var inst = null
	if ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls):
		inst = ClassDB.instantiate(cls)
	_defaults[cls] = inst
	return inst


func _free_defaults() -> void:
	for cls in _defaults:
		var inst = _defaults[cls]
		if inst is Node:
			inst.free()
	_defaults.clear()


# --- Экранирование ---

## HTML-escape значения атрибута. Парность с HtmlParser._decode_entities обеспечивает
## round-trip (включая кавычки из var_to_str строк).
func _escape_attr(s: String) -> String:
	s = s.replace("&", "&amp;")
	s = s.replace("<", "&lt;")
	s = s.replace(">", "&gt;")
	s = s.replace("\"", "&quot;")
	return s
