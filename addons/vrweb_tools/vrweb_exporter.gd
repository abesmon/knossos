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
## Использование:
##   VrwebExporter.export_scene(root, "combine"|"exclusive") — HTML, дети root;
##   VrwebExporter.export_vrwml(root) — standalone <vrweb>, включая сам root.

const SUB_PREFIX := VrwebBuilder.SUBRESOURCE_PREFIX
const EXT_PREFIX := VrwebBuilder.EXTRESOURCE_PREFIX
const PUBLIC_CLASSES := preload("res://scripts/vrwml_class_registry.gd")

## Свойства, которые никогда не экспортируем (служебные/неинстанцируемые читателем).
const SKIP_PROPS := {"owner": true, "name": true, "script": true, "scene_file_path": true}
const META_SCRIPT_MODE := "vrweb_script_mode"
const META_SCRIPT_ID := "vrweb_script_id"
const SCRIPT_MODE_INLINE := "inline"
const SCRIPT_MODE_PACKAGE := "package"

var _sub_order: Array[String] = []          # id'ы суб-ресурсов в порядке появления
var _sub_def: Dictionary = {}               # id -> Resource
var _sub_by_res: Dictionary = {}            # Resource -> id (дедуп по инстансу)
var _sub_seq := 0

var _ext_order: Array[String] = []          # id'ы внешних ресурсов в порядке появления
var _ext_def: Dictionary = {}               # id -> VrwebExtResource
var _ext_by_res: Dictionary = {}            # VrwebExtResource -> id (дедуп)
var _ext_seq := 0

var _defaults: Dictionary = {}              # class -> экземпляр-эталон (Node освобождаем в конце)
var _inline_scripts: Array[Dictionary] = [] # [{id,base,source}] для <head>
var _inline_seq := 0
var _package_defs: Array[Dictionary] = []
var _package_seq := 0
var _module_head_lines: Array[String] = []
var _report := {"ok": true, "packages": [], "warnings": [], "errors": []}
var _standalone := false


## Главный вход: HTML-документ строкой. mode — "combine" (по умолчанию) или "exclusive".
static func export_scene(root: Node, mode: String = VrwebBuilder.MODE_COMBINE,
		output_path: String = "") -> String:
	var e := VrwebExporter.new()
	return e._export(root, mode, output_path)


static func export_scene_report(root: Node, mode: String = VrwebBuilder.MODE_COMBINE,
		output_path: String = "") -> Dictionary:
	var e := VrwebExporter.new()
	var html := e._export(root, mode, output_path)
	e._report["html"] = html
	return e._report


## Standalone VRWML — тот же декларативный синтаксис без HTML envelope. Корень сцены здесь
## семантичен (например, Avatar), поэтому экспортируется вместе со своими детьми.
static func export_vrwml(root: Node, output_path: String = "") -> String:
	var e := VrwebExporter.new()
	return e._export_vrwml(root, output_path)


static func export_vrwml_report(root: Node, output_path: String = "") -> Dictionary:
	var e := VrwebExporter.new()
	var vrwml := e._export_vrwml(root, output_path)
	e._report["vrwml"] = vrwml
	return e._report


func _export(root: Node, mode: String, output_path: String) -> String:
	_standalone = false
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
	_write_packages(output_path)

	_free_defaults()

	var inner := body_lines + res_lines
	var pad := "  "
	var out: Array[String] = []
	out.append("<!DOCTYPE html>")
	out.append("<html>")
	out.append("<head>")
	out.append("  <meta charset=\"utf-8\">")
	out.append("  <title>VRWeb export</title>")
	for module_line in _module_head_lines:
		out.append("  " + module_line)
	for script_def in _inline_scripts:
		out.append("  <script type=\"application/vrweb+gdscript\" id=\"%s\" data-base=\"%s\">" \
				% [_escape_attr(script_def.id), _escape_attr(script_def.base)])
		out.append(str(script_def.source))
		out.append("  </script>")
	out.append("</head>")
	out.append("<body>")
	out.append(pad + "<vrweb mode=\"%s\">" % safe_mode)
	for line in inner:
		out.append(line)
	out.append(pad + "</vrweb>")
	out.append("</body>")
	out.append("</html>")
	out.append("")
	return "\n".join(out)


func _export_vrwml(root: Node, _output_path: String) -> String:
	_standalone = true
	var body_lines: Array[String] = []
	if root != null:
		_build_node(root, 1, body_lines)

	var res_lines: Array[String] = []
	var i := 0
	while i < _sub_order.size():
		var id := _sub_order[i]
		_emit_resource(id, _sub_def[id], res_lines)
		i += 1
	for ext_id in _ext_order:
		_emit_ext(ext_id, _ext_def[ext_id], res_lines)
	if not _package_defs.is_empty() or not _inline_scripts.is_empty():
		_report_error("standalone VRWML не включает исполняемые Script/module definitions")
	_free_defaults()

	var out: Array[String] = ["<vrweb>"]
	out.append_array(body_lines)
	out.append_array(res_lines)
	out.append("</vrweb>")
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

	var public_class := PUBLIC_CLASSES.public_name(node)
	var script_mode := str(node.get_meta(META_SCRIPT_MODE, ""))
	if public_class == "" and _standalone \
			and script_mode in [SCRIPT_MODE_INLINE, SCRIPT_MODE_PACKAGE]:
		_report_error("Script узла %s нельзя встроить в data-only VRWML" % _node_label(node))
		return

	if public_class == "" and script_mode == SCRIPT_MODE_INLINE:
		if _build_inline_component(node, depth, out):
			return
	if public_class == "" and script_mode == SCRIPT_MODE_PACKAGE:
		if _build_package_component(node, depth, out):
			return

	# Scripting modules требуют явного opt-in: молча превратить scripted node в базовый ClassDB-тег
	# особенно опасно — HTML выглядит рабочим, но всё поведение потеряно.
	if public_class == "" and node.get_script() != null:
		if _standalone:
			_report_error("Script узла %s не имеет public VRWML-класса" % _node_label(node))
		else:
			_report_warning("Script узла %s не экспортирован; выберите inline/package" % _node_label(node))

	var cls := public_class if public_class != "" else node.get_class()
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


func _build_inline_component(node: Node, depth: int, out: Array[String]) -> bool:
	var script = node.get_script()
	if not (script is GDScript) or str(script.source_code).is_empty():
		_report_warning("inline Script узла %s не является source GDScript" % _node_label(node))
		return false
	var source := str(script.source_code)
	if source.to_lower().contains("</script"):
		_report_warning("inline Script узла %s содержит </script; используйте package" % _node_label(node))
		return false
	var id := str(node.get_meta(META_SCRIPT_ID, ""))
	if id.is_empty():
		id = "inline_%d" % _inline_seq
		_inline_seq += 1
	_inline_scripts.append({"id": id, "base": node.get_class(), "source": source})
	var pad := "  ".repeat(depth)
	var parts: Array[String] = ["module=\"#%s\"" % _escape_attr(id), "class=\"default\""]
	parts.append_array(_diff_attrs(node, node.get_class(), {}))
	var attrs := " " + " ".join(parts)
	var kids := node.get_children()
	if kids.is_empty():
		out.append("%s<VRWebComponent%s/>" % [pad, attrs])
		return true
	out.append("%s<VRWebComponent%s>" % [pad, attrs])
	for child in kids:
		_build_node(child, depth + 1, out)
	out.append("%s</VRWebComponent>" % pad)
	return true


func _build_package_component(node: Node, depth: int, out: Array[String]) -> bool:
	var script = node.get_script()
	if not (script is GDScript):
		_report_error("package Script узла %s не является GDScript" % _node_label(node))
		return false
	var id := str(node.get_meta(META_SCRIPT_ID, ""))
	if id.is_empty():
		id = "package_%d" % _package_seq
		_package_seq += 1
	_package_defs.append({"id": id, "script": script, "base": node.get_class()})
	_emit_component_node(node, id, depth, out)
	return true


func _emit_component_node(node: Node, module_id: String, depth: int, out: Array[String]) -> void:
	var pad := "  ".repeat(depth)
	var parts: Array[String] = ["module=\"#%s\"" % _escape_attr(module_id), "class=\"default\""]
	parts.append_array(_diff_attrs(node, node.get_class(), {}))
	var attrs := " " + " ".join(parts)
	if node.get_children().is_empty():
		out.append("%s<VRWebComponent%s/>" % [pad, attrs])
		return
	out.append("%s<VRWebComponent%s>" % [pad, attrs])
	for child in node.get_children():
		_build_node(child, depth + 1, out)
	out.append("%s</VRWebComponent>" % pad)


func _write_packages(output_path: String) -> void:
	var ids := {}
	for definition in _package_defs:
		if ids.has(definition.id):
			_report_error("дублирующийся package id %s" % definition.id)
			continue
		ids[definition.id] = true
		if output_path.is_empty():
			_report_error("package %s требует output_path" % definition.id)
			continue
		var filename := str(definition.id) + ".vrmod"
		var package_path := output_path.get_base_dir().path_join(filename)
		var result := VrwebPackageExporter.build(definition.script, definition.id,
				package_path, definition.base)
		if not bool(result.ok):
			_report_error("package %s: %s" % [definition.id, result.error])
			continue
		_report.packages.append({"id": definition.id, "file": filename, "hash": result.hash,
			"integrity": result.integrity, "files": result.files, "assets": result.assets})
		_module_head_lines.append('<VRWebModule id="%s" src="%s" integrity="%s" mode="trusted-gdscript"/>' \
				% [_escape_attr(definition.id), _escape_attr(filename), _escape_attr(result.integrity)])


func _report_error(message: String) -> void:
	_report.ok = false
	_report.errors.append(message)
	push_warning("VRWeb export: " + message)


func _report_warning(message: String) -> void:
	_report.warnings.append(message)
	push_warning("VRWeb export: " + message)


func _node_label(node: Node) -> String:
	return str(node.get_path()) if node.is_inside_tree() else str(node.name)


## Строка атрибутов узла: ext-привязки (как "ExtResource:::id") + не-дефолтные свойства.
func _node_attrs(node: Node, cls: String) -> String:
	var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {})
	var skip_props := bindings.duplicate()
	var parts: Array[String] = []
	# В standalone-документе имена участвуют в NodePath аппликаторов и потому семантичны.
	# HTML world-export исторически их опускал — его output не меняем этой миграцией.
	if _standalone and str(node.name) != "":
		parts.append("name=\"%s\"" % _escape_attr(str(node.name)))

	# Ext-привязки идут первыми; их реальные свойства из диффа исключаются.
	for prop in bindings:
		var ext_res = bindings[prop]
		if ext_res is VrwebExtResource:
			parts.append("%s=\"%s%s\"" % [prop, EXT_PREFIX, _ext_id(ext_res)])

	# Node-ссылка — Godot authoring convenience. Публичный формат хранит переносимый путь.
	if cls == "AvatarAnimationTreeApplier":
		skip_props["animation_tree"] = true
		var tree := node.get("animation_tree") as AnimationTree
		if tree != null:
			skip_props["animation_tree_path"] = true
			parts.append("animation_tree_path=\"%s\"" %
					_escape_attr(var_to_str(node.get_path_to(tree))))

	parts.append_array(_diff_attrs(node, cls, skip_props))
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
		if value == null:
			continue
		if def != null and _has_property(def, name) and _values_equal(value, def.get(name)):
			continue
		var serialized := _serialize_value(value)
		if serialized == "":
			if _standalone:
				_report_error("свойство %s.%s не поддерживает VRWML round-trip" % [cls, name])
			continue
		parts.append("%s=\"%s\"" % [name, _escape_attr(serialized)])
	return parts


func _has_property(obj: Object, property: String) -> bool:
	for entry in obj.get_property_list():
		if str(entry.name) == property:
			return true
	return false


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
	var public_class := PUBLIC_CLASSES.public_name(res)
	var cls := public_class if public_class != "" else res.get_class()
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
	if value is Array:
		var serialized_items: Array = []
		for item in value:
			if item is Resource:
				serialized_items.append(SUB_PREFIX + _sub_id(item))
			elif item is Object:
				return ""
			else:
				serialized_items.append(item)
		return var_to_str(serialized_items)
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
	var inst = PUBLIC_CLASSES.instantiate(cls)
	if inst == null and ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls):
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
