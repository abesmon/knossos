@tool
class_name VrwebExporter
extends RefCounted

## Экспорт собранной в редакторе Godot-сцены в HTML-документ с тегами <vrwml> —
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
##   VrwebExporter.export_vrwml(root) — standalone <vrwml>, включая сам root.

const SUB_PREFIX := VrwebFormat.SUBRESOURCE_PREFIX
const EXT_PREFIX := VrwebFormat.EXTRESOURCE_PREFIX

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
var _report := {"ok": true, "packages": [], "assets": [], "warnings": [], "errors": [],
	"profile": VrwebCompatibility.PROFILE_COMPATIBLE,
	"policy_version": VrwebCompatibility.POLICY_VERSION}
var _standalone := false
var _profile := VrwebCompatibility.PROFILE_COMPATIBLE
var _output_path := ""


## Главный вход: HTML-документ строкой. mode — "combine" (по умолчанию) или "exclusive".
static func export_scene(root: Node, mode: String = VrwebFormat.MODE_COMBINE,
		output_path: String = "", profile: String = VrwebCompatibility.PROFILE_COMPATIBLE) -> String:
	var e := VrwebExporter.new()
	e._set_profile(profile)
	return e._export(root, mode, output_path)


static func export_scene_report(root: Node, mode: String = VrwebFormat.MODE_COMBINE,
		output_path: String = "", profile: String = VrwebCompatibility.PROFILE_COMPATIBLE) -> Dictionary:
	var e := VrwebExporter.new()
	e._set_profile(profile)
	var html := e._export(root, mode, output_path)
	e._report["html"] = html
	return e._report


## Standalone VRWML — тот же декларативный синтаксис без HTML envelope. Корень сцены здесь
## семантичен (например, Avatar), поэтому экспортируется вместе со своими детьми.
static func export_vrwml(root: Node, output_path: String = "",
		profile: String = VrwebCompatibility.PROFILE_COMPATIBLE) -> String:
	var e := VrwebExporter.new()
	e._set_profile(profile)
	return e._export_vrwml(root, output_path)


static func export_vrwml_report(root: Node, output_path: String = "",
		profile: String = VrwebCompatibility.PROFILE_COMPATIBLE) -> Dictionary:
	var e := VrwebExporter.new()
	e._set_profile(profile)
	var vrwml := e._export_vrwml(root, output_path)
	e._report["vrwml"] = vrwml
	return e._report


## Только блок <vrwml> для lossless-сохранения импортированной HTML-сцены. В отличие от
## export_scene(), HTML envelope не создаётся: вызывающий заменяет этим текстом ровно исходный
## диапазон блока, сохраняя всё вокруг без нормализации.
static func export_vrweb_block_report(root: Node, mode: String = VrwebFormat.MODE_COMBINE,
		output_path: String = "", profile: String = VrwebCompatibility.PROFILE_COMPATIBLE) -> Dictionary:
	var e := VrwebExporter.new()
	e._set_profile(profile)
	var block := e._export_vrweb_block(root, mode, output_path)
	e._report["vrweb"] = block
	return e._report


func _set_profile(profile: String) -> void:
	_profile = VrwebCompatibility.normalized_profile(profile)
	_report.profile = _profile


func _export(root: Node, mode: String, output_path: String) -> String:
	_standalone = false
	_output_path = output_path
	var safe_mode := VrwebFormat.normalized_mode(mode)
	_validate_world_basics(root)

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
	_validate_budgets()
	_write_asset_manifest(output_path)
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
		out.append("  <script type=\"%s\" id=\"%s\" data-base=\"%s\" data-mode=\"%s\">" \
				% [_escape_attr(script_def.mime), _escape_attr(script_def.id),
					_escape_attr(script_def.base), _escape_attr(script_def.runtime)])
		out.append(str(script_def.source))
		out.append("  </script>")
	out.append("</head>")
	out.append("<body>")
	out.append(pad + "<vrwml mode=\"%s\">" % safe_mode)
	for line in inner:
		out.append(line)
	out.append(pad + "</vrwml>")
	out.append("</body>")
	out.append("</html>")
	out.append("")
	return "\n".join(out)


func _export_vrwml(root: Node, output_path: String) -> String:
	_standalone = true
	_output_path = output_path
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
	_write_asset_manifest(output_path)
	if not _package_defs.is_empty() or not _inline_scripts.is_empty():
		_report_error("standalone VRWML не включает исполняемые Script/module definitions")
	_free_defaults()

	var out: Array[String] = ["<vrwml>"]
	out.append_array(body_lines)
	out.append_array(res_lines)
	out.append("</vrwml>")
	out.append("")
	return "\n".join(out)


func _export_vrweb_block(root: Node, mode: String, output_path: String) -> String:
	_standalone = false
	_output_path = output_path
	var safe_mode := VrwebFormat.normalized_mode(mode)
	var body_lines: Array[String] = []
	if root != null:
		# get_children() excludes internal preview nodes by default. That is the persistence
		# boundary of imported HTML scenes: only editable children become <vrwml> content.
		for child in root.get_children():
			_build_node(child, 1, body_lines)

	var res_lines: Array[String] = []
	var i := 0
	while i < _sub_order.size():
		var id := _sub_order[i]
		_emit_resource(id, _sub_def[id], res_lines)
		i += 1
	for ext_id in _ext_order:
		_emit_ext(ext_id, _ext_def[ext_id], res_lines)
	_validate_budgets()
	_write_asset_manifest(output_path)
	_write_packages(output_path)
	if not _module_head_lines.is_empty() or not _inline_scripts.is_empty():
		_report_error("lossless HTML save не может менять Script/module definitions вне <vrwml>")
	_free_defaults()

	var out: Array[String] = ["<vrwml mode=\"%s\">" % safe_mode]
	out.append_array(body_lines)
	out.append_array(res_lines)
	out.append("</vrwml>")
	return "\n".join(out)


# --- Узлы ---

func _build_node(node: Node, depth: int, out: Array[String]) -> void:
	# Generated HTML geometry is packed into import cache, then hidden as an internal live
	# subtree. The explicit marker is the persistence boundary even before internalization.
	if bool(node.get_meta(VrwebHtmlDocument.META_PREVIEW, false)):
		return
	# VrwebSpawner -> мета-тег <VRWebSpawner> (в сцену клиента не инстанцируется).
	if node is VrwebSpawner:
		_build_spawner(node, depth, out)
		return

	# Узел с meta vrweb_ext_scene -> <ExtScene src="ExtResource:::<id>" ...>.
	if node.has_meta(VrwebExtResource.META_SCENE):
		_build_ext_scene(node, depth, out)
		return

	var public_class := VrwebExportRegistry.public_name(node)
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
		elif _profile == VrwebCompatibility.PROFILE_STRICT:
			_report_error("Script узла %s не экспортирован; выберите inline/package" % _node_label(node))
		else:
			_report_warning("Script узла %s не экспортирован; выберите inline/package" % _node_label(node))

	var cls := public_class if public_class != "" else node.get_class()
	if _profile == VrwebCompatibility.PROFILE_STRICT and public_class == "" \
			and not VrwebCompatibility.supports_node(cls):
		_report_error("узел %s: класс %s не разрешён strict policy Maker Kit %s" % [
			_node_label(node), cls, VrwebCompatibility.POLICY_VERSION])
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
	var id := str(node.get_meta(META_SCRIPT_ID, ""))
	if id.is_empty():
		id = "inline_%d" % _inline_seq
		_inline_seq += 1
	var prepared := VrwebInlineExporter.prepare(script, id, node.get_class())
	if not bool(prepared.ok):
		_report_compatibility_issue("inline Script узла %s: %s" % [
			_node_label(node), prepared.error])
		return false
	_inline_scripts.append(prepared.definition)
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
	var metadata := VrwebModuleMetadata.from_node(node, id)
	var normalized := VrwebModuleMetadata.normalize(metadata)
	if not bool(normalized.ok):
		_report_error("package %s: %s" % [id, "; ".join(normalized.errors)])
		return false
	_package_defs.append({"id": id, "script": script, "base": node.get_class(),
		"metadata": normalized.value})
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
				package_path, definition.base, VrwebModuleMetadata.DEFAULT_REQUIRES,
				VrwebModuleMetadata.DEFAULT_OPTIONAL, definition.metadata)
		if not bool(result.ok):
			_report_error("package %s: %s" % [definition.id, result.error])
			continue
		_report.packages.append({"id": definition.id, "file": filename, "hash": result.hash,
			"integrity": result.integrity, "files": result.files, "assets": result.assets,
			"version": definition.metadata.version,
			"permissions": definition.metadata.permissions,
			"requires": definition.metadata.requires, "optional": definition.metadata.optional})
		_module_head_lines.append('<VRWebModule id="%s" src="%s" integrity="%s" mode="trusted-gdscript"/>' \
				% [_escape_attr(definition.id), _escape_attr(filename), _escape_attr(result.integrity)])


func _report_error(message: String) -> void:
	_report.ok = false
	_report.errors.append(message)
	push_warning("VRWeb export: " + message)


func _report_warning(message: String) -> void:
	_report.warnings.append(message)
	push_warning("VRWeb export: " + message)


func _report_compatibility_issue(message: String) -> void:
	if _profile == VrwebCompatibility.PROFILE_STRICT:
		_report_error(message)
	else:
		_report_warning(message)


func _node_label(node: Node) -> String:
	if node.is_inside_tree():
		return str(node.get_path())
	var names: Array[String] = []
	var cursor: Node = node
	while cursor != null:
		var part := str(cursor.name)
		if part.is_empty():
			part = cursor.get_class()
		names.push_front(part)
		cursor = cursor.get_parent()
	return "/" + "/".join(names)


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
			if _standalone or _profile == VrwebCompatibility.PROFILE_STRICT:
				var owner := _node_label(obj) if obj is Node else cls
				_report_error("%s: свойство %s не поддерживает VRWML round-trip" % [owner, name])
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
	out.append("%s<%s%s/>" % [pad, VrwebFormat.EXT_SCENE_TAG, attrs])


## <VRWebSpawner mode="..."> + <SpawnerPoint transform="..."/> по детям-Node3D.
func _build_spawner(node: VrwebSpawner, depth: int, out: Array[String]) -> void:
	var pad := "  ".repeat(depth)
	out.append("%s<%s mode=\"%s\">" % [pad, VrwebFormat.SPAWNER_TAG, node.mode])
	var cpad := "  ".repeat(depth + 1)
	for child in node.get_children():
		if child is Node3D:
			var xform: Transform3D = (child as Node3D).transform
			out.append("%s<%s transform=\"%s\"/>" % [
				cpad, VrwebFormat.SPAWN_POINT_TAG, _escape_attr(var_to_str(xform))])
	out.append("%s</%s>" % [pad, VrwebFormat.SPAWNER_TAG])


# --- Ресурсы ---

## Сериализует встроенный суб-ресурс: <Resource id="..." type="<class>" <свойства>/>.
func _emit_resource(id: String, res: Resource, out: Array[String]) -> void:
	var public_class := VrwebExportRegistry.public_name(res)
	var cls := public_class if public_class != "" else res.get_class()
	if _profile == VrwebCompatibility.PROFILE_STRICT and public_class == "" \
			and not VrwebCompatibility.supports_resource(cls):
		_report_error("resource %s: класс %s не разрешён strict policy Maker Kit %s" % [
			id, cls, VrwebCompatibility.POLICY_VERSION])
	if res is Mesh:
		var triangle_count := (res as Mesh).get_faces().size() / 3
		if triangle_count > VrwebCompatibility.HEAVY_MESH_TRIANGLES:
			_report_warning("resource %s: mesh содержит %d triangles (recommended <= %d)" % [
				id, triangle_count, VrwebCompatibility.HEAVY_MESH_TRIANGLES])
	var parts: Array[String] = ["id=\"%s\"" % id, "type=\"%s\"" % cls]
	parts.append_array(_diff_attrs(res, cls, {}))
	out.append("  %s<%s %s/>" % ["", VrwebFormat.RESOURCE_TAG, " ".join(parts)])


## Сериализует внешний ресурс: <ExtResource id="..." type="<type>" path="<url>"/>.
func _emit_ext(id: String, ext: VrwebExtResource, out: Array[String]) -> void:
	if _profile == VrwebCompatibility.PROFILE_STRICT \
			and not VrwebCompatibility.supports_external_type(ext.type):
		_report_error("external resource %s: type %s не разрешён strict policy Maker Kit %s" % [
			id, ext.type, VrwebCompatibility.POLICY_VERSION])
	if _profile == VrwebCompatibility.PROFILE_STRICT and not ext is VrwebLocalAsset:
		var scheme := ext.url.get_slice(":", 0).to_lower()
		var safe_relative := not ext.url.contains(":") \
				and VrwebPublishedVerifier.validate_relative_path(ext.url).is_empty()
		if not safe_relative and scheme not in ["http", "https", "vrweb", "vrwebresource", "vrweblocal"]:
			_report_error("external resource %s: непереносимый или неизвестный URL scheme: %s" % [
				id, scheme if not scheme.is_empty() else "<none>"])
	var url := ext.url
	if ext is VrwebLocalAsset:
		var bundled := VrwebAssetBundler.bundle(ext, _output_path)
		if not bool(bundled.get("ok", false)):
			_report_error("external resource %s: %s" % [id, bundled.get("error", "bundle error")])
			url = ""
		else:
			url = str(bundled.url)
			_append_asset_entry(bundled.entry)
			for dependency in bundled.dependencies:
				_append_asset_entry(dependency)
	out.append("  <%s id=\"%s\" type=\"%s\" path=\"%s\"/>" % [
		VrwebFormat.EXT_RESOURCE_TAG, id, ext.type, _escape_attr(url)])


func _append_asset_entry(entry: Dictionary) -> void:
	for existing in _report.assets:
		if str(existing.get("file", "")) == str(entry.get("file", "")):
			return
	_report.assets.append(entry)


func _write_asset_manifest(output_path: String) -> void:
	if not bool(_report.ok):
		return
	var entries: Array = _report.assets
	entries.sort_custom(func(a, b): return str(a.file) < str(b.file))
	var path := output_path.get_base_dir().path_join(
			output_path.get_file().get_basename() + ".assets.json")
	_cleanup_previous_assets(path, entries)
	if entries.is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var payload := JSON.stringify({"version": 1, "assets": entries}, "  ") + "\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_report_error("не удалось записать asset manifest: " + path)
		return
	file.store_string(payload)
	file.close()
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(payload.to_utf8_buffer())
	_report["asset_manifest"] = {"file": path.get_file(),
		"sha256": context.finish().hex_encode(), "assets": entries.size()}


func _cleanup_previous_assets(manifest_path: String, next_entries: Array) -> void:
	if not FileAccess.file_exists(manifest_path):
		return
	var previous = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not previous is Dictionary or not previous.get("assets", []) is Array:
		return
	var keep := {}
	for entry in next_entries:
		keep[str(entry.get("file", ""))] = true
	var output_stub := manifest_path.get_base_dir().path_join(
			manifest_path.get_file().trim_suffix(".assets.json") + ".html")
	var expected_prefix := VrwebAssetBundler.asset_dir(output_stub) + "/"
	for entry in previous.assets:
		if not entry is Dictionary:
			continue
		var relative := str(entry.get("file", ""))
		if keep.has(relative) or not relative.begins_with(expected_prefix) or relative.contains(".."):
			continue
		var stale := manifest_path.get_base_dir().path_join(relative)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))


func _validate_world_basics(root: Node) -> void:
	if _profile != VrwebCompatibility.PROFILE_STRICT or root == null:
		return
	var nodes := root.find_children("*", "Node", true, false)
	var has_spawn := _spawner_has_point(root)
	var has_collision := false
	for node in nodes:
		has_spawn = has_spawn or _spawner_has_point(node)
		has_collision = has_collision or (node is CollisionShape3D and node.shape != null)
	if not has_spawn:
		_report_error("world: обязательный VRWebSpawner со spawn point не найден")
	if not has_collision:
		_report_warning("world: CollisionShape3D не найден; визуальная геометрия не создаёт пол")
	if nodes.size() + 1 > VrwebCompatibility.MAX_NODES:
		_report_error("world: %d nodes превышают strict budget %d" % [
			nodes.size() + 1, VrwebCompatibility.MAX_NODES])


func _spawner_has_point(node: Node) -> bool:
	if not node is VrwebSpawner:
		return false
	for child in node.get_children():
		if child is Node3D:
			return true
	return false


func _validate_budgets() -> void:
	if _profile != VrwebCompatibility.PROFILE_STRICT:
		return
	if _sub_order.size() > VrwebCompatibility.MAX_RESOURCES:
		_report_error("world: %d resources превышают strict budget %d" % [
			_sub_order.size(), VrwebCompatibility.MAX_RESOURCES])
	if _ext_order.size() > VrwebCompatibility.MAX_EXTERNAL_RESOURCES:
		_report_error("world: %d external resources превышают strict budget %d" % [
			_ext_order.size(), VrwebCompatibility.MAX_EXTERNAL_RESOURCES])


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
	var inst = VrwebExportRegistry.instantiate(cls)
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
