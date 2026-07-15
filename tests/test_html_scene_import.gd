extends Node

## End-to-end HTML scene import/save regression. Run:
##   godot --headless --path . res://tests/test_html_scene_import.tscn

const CODEC := preload("res://integrations/knossos/vrweb_tools/vrweb_html_scene_codec.gd")
const PORTABLE_CODEC := preload("res://addons/vrweb_tools/vrweb_portable_html_scene_codec.gd")
const SAVER := preload("res://addons/vrweb_tools/vrweb_html_scene_saver.gd")
const DOCUMENT := preload("res://addons/vrweb_tools/vrweb_html_document.gd")

var _failed := false


func _ready() -> void:
	var source_path := "/tmp/knossos_html_scene_import_source.html"
	var output_path := "/tmp/knossos_html_scene_import_saved.html"
	var source := "<!doctype html>\r\n<head><title>Не менять</title></head>\r\n" \
		+ "<body><main><h1>Процедурная комната</h1>" \
		+ "<section><h2>Первая</h2><p>Объект на стене</p>" \
		+ "<img src=\"preview.png\" alt=\"Картина\" width=\"256\" height=\"128\"></section>" \
		+ "<section><h2>Вторая</h2><a href=\"next.html\">Портал</a></section></main>\r\n" \
		+ "<vrwml mode=\"combine\"><Node3D name=\"Editable\"/></vrwml>\r\n</body>\r\n"
	_write(source_path, source)

	var root := PORTABLE_CODEC.build_from_path(source_path)
	_check(root != null, "HTML importer возвращает сцену")
	if root == null:
		get_tree().quit(1)
		return
	CODEC.attach_procedural_preview(root)
	_check(bool(root.get_meta(DOCUMENT.META_IMPORTED, false)), "tool-safe vrweb помечен редактируемым")
	_check(root.get_child_count() == 2, "import cache содержит помеченный procedural preview")
	_check(root.get_child(0).name == "Editable", "vrweb-узел материализован")
	var preview := root.get_child(1)
	_check(int(preview.get_meta(DOCUMENT.META_PREVIEW_ROOMS, 0)) >= 3,
		"preview строит полную многокомнатную топологию")
	_check(int(preview.get_meta(DOCUMENT.META_PREVIEW_DOORS, 0)) > 0,
		"preview содержит дверные проёмы полного WorldGenerator")
	_check(_find_meta(preview, DOCUMENT.META_PREVIEW_IMAGE_URL) != null,
		"HTML image материализован как editor-safe texture target")

	var packed := PackedScene.new()
	_check(packed.pack(root) == OK, "сцена с internal preview пакуется")
	var roundtrip := packed.instantiate()
	_check(roundtrip.get_child_count() == 2, "помеченный preview переживает PackedScene cache")
	CODEC.make_preview_internal(roundtrip)
	_check(roundtrip.get_child_count() == 1 and roundtrip.get_child_count(true) == 2,
		"plugin lifecycle скрывает preview из editable обхода")
	roundtrip.free()
	CODEC.make_preview_internal(root)
	_check(root.get_child_count() == 1 and root.get_child_count(true) == 2,
		"live editor tree видит только editable vrweb в обычном обходе")

	(root.get_child(0) as Node3D).position = Vector3(1, 2, 3)
	var saved := SAVER.save_root(root, output_path)
	_check(bool(saved.get("ok", false)), "lossless saver записывает изменённый vrweb")
	var output := FileAccess.get_file_as_string(output_path)
	var before_span := DOCUMENT.locate(source)
	var after_span := DOCUMENT.locate(output)
	_check(_prefix(source, before_span) == _prefix(output, after_span), "HTML prefix не изменён")
	_check(_suffix(source, before_span) == _suffix(output, after_span), "HTML suffix не изменён")
	_check(output.contains("1, 2, 3)"), "изменение сцены попало внутрь vrweb")

	# Parallel source edit must not be overwritten by stale editor state.
	_write(output_path, output.replace("</vrwml>", " \n</vrwml>"))
	var conflict := SAVER.save_root(root, output_path)
	_check(not bool(conflict.get("ok", false)), "внешнее изменение vrweb даёт conflict")
	root.free()

	var exclusive_path := "/tmp/knossos_html_scene_import_exclusive.html"
	_write(exclusive_path, source.replace("mode=\"combine\"", "mode=\"exclusive\""))
	var exclusive_root := PORTABLE_CODEC.build_from_path(exclusive_path)
	CODEC.attach_procedural_preview(exclusive_root)
	_check(exclusive_root != null, "exclusive HTML импортируется")
	if exclusive_root != null:
		_check(exclusive_root.get_child_count() == 1,
			"exclusive не строит DOM за пределами vrweb")
		_check(str(exclusive_root.get_meta(DOCUMENT.META_MODE, "")) == "exclusive",
			"exclusive mode сохраняется в imported root")
		exclusive_root.free()
	get_tree().quit(1 if _failed else 0)


func _find_meta(node: Node, key: StringName) -> Node:
	if node.has_meta(key):
		return node
	for child in node.get_children(true):
		var found := _find_meta(child, key)
		if found != null:
			return found
	return null


func _prefix(source: String, span: Dictionary) -> String:
	return source.substr(0, int(span.get("start", 0)))


func _suffix(source: String, span: Dictionary) -> String:
	return source.substr(int(span.get("end", source.length())))


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failed = true
		push_error("Не удалось открыть test file: %s" % path)
		return
	file.store_string(text)
	file.close()


func _check(ok: bool, label: String) -> void:
	print(("[ok] " if ok else "[FAIL] ") + label)
	_failed = _failed or not ok
