@tool
extends EditorPlugin

## Инструментарий VRWeb в редакторе: док-панель с экспортом сцены в HTML (VrwebExporter),
## привязкой внешних ресурсов к узлам (VrwebExtResource в мету) и дебаг-превью (VrwebExtPreview).
## Типы VrwebExtResource/VrwebSpawner регистрируются автоматически через class_name —
## отдельный add_custom_type не нужен.

const EXPORT_TYPES := [
	"Texture2D", "ImageTexture", "CompressedTexture2D",
	"AudioStreamMP3", "AudioStreamOggVorbis", "AudioStreamWAV",
	"Mesh", "ArrayMesh", "PackedScene",
]

var _dock: Control
var _prop_edit: LineEdit
var _url_edit: LineEdit
var _type_opt: OptionButton
var _mode_opt: OptionButton
var _status: Label
var _file_dialog: EditorFileDialog
var _preview: VrwebExtPreview


func _enter_tree() -> void:
	_preview = VrwebExtPreview.new(self)
	_build_dock()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)

	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_file_dialog.add_filter("*.html", "HTML")
	_file_dialog.current_dir = "res://test_pages/"
	_file_dialog.file_selected.connect(_on_export_path_chosen)
	EditorInterface.get_base_control().add_child(_file_dialog)


func _exit_tree() -> void:
	remove_control_from_docks(_dock)
	if is_instance_valid(_dock):
		_dock.queue_free()
	if is_instance_valid(_file_dialog):
		_file_dialog.queue_free()


# --- Построение дока ---

func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "VRWeb"

	_dock.add_child(_heading("Экспорт сцены"))
	var mode_row := HBoxContainer.new()
	mode_row.add_child(_label("Режим:"))
	_mode_opt = OptionButton.new()
	_mode_opt.add_item("combine")
	_mode_opt.add_item("exclusive")
	mode_row.add_child(_mode_opt)
	_dock.add_child(mode_row)
	_dock.add_child(_button("Экспорт в HTML…", _on_export_pressed))

	_dock.add_child(_sep())
	_dock.add_child(_heading("Внешний ресурс → выбранный узел"))
	_prop_edit = LineEdit.new()
	_prop_edit.placeholder_text = "свойство (напр. texture); пусто = ExtScene"
	_dock.add_child(_prop_edit)
	_url_edit = LineEdit.new()
	_url_edit.placeholder_text = "URL (http(s):// или vrweb-адрес)"
	_dock.add_child(_url_edit)
	_type_opt = OptionButton.new()
	for t in EXPORT_TYPES:
		_type_opt.add_item(t)
	_dock.add_child(_type_opt)
	_dock.add_child(_button("Привязать к узлу", _on_bind_pressed))
	_dock.add_child(_button("Убрать привязку", _on_unbind_pressed))

	_dock.add_child(_sep())
	_dock.add_child(_heading("Дебаг-превью (без записи в файлы)"))
	_dock.add_child(_button("Загрузить превью", _on_load_preview))
	_dock.add_child(_button("Очистить превью", _on_clear_preview))

	_dock.add_child(_sep())
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dock.add_child(_status)


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	return l


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	return b


func _sep() -> HSeparator:
	return HSeparator.new()


# --- Действия ---

func _on_export_pressed() -> void:
	if EditorInterface.get_edited_scene_root() == null:
		_say("Нет открытой сцены для экспорта.")
		return
	_file_dialog.popup_centered_ratio(0.6)


func _on_export_path_chosen(path: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Нет открытой сцены.")
		return
	var mode := _mode_opt.get_item_text(_mode_opt.selected)
	var html := VrwebExporter.export_scene(root, mode)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("Не удалось записать %s (код %d)." % [path, FileAccess.get_open_error()])
		return
	f.store_string(html)
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	_say("Экспортировано: %s" % path)


func _on_bind_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	var url := _url_edit.text.strip_edges()
	if url == "":
		_say("Укажите URL.")
		return
	var ext := VrwebExtResource.new()
	ext.url = url
	ext.type = _type_opt.get_item_text(_type_opt.selected)

	var prop := _prop_edit.text.strip_edges()
	if prop == "":
		# Пустое свойство -> точка <ExtScene> (узел-плейсхолдер).
		ext.type = "PackedScene"
		node.set_meta(VrwebExtResource.META_SCENE, ext)
		_say("Привязан <ExtScene> к «%s»." % node.name)
	else:
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {})
		bindings = bindings.duplicate()
		bindings[prop] = ext
		node.set_meta(VrwebExtResource.META_BINDINGS, bindings)
		_say("Привязано %s ← %s (%s)." % [prop, url, ext.type])
	_mark_dirty()


func _on_unbind_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	var prop := _prop_edit.text.strip_edges()
	if prop == "":
		if node.has_meta(VrwebExtResource.META_SCENE):
			node.remove_meta(VrwebExtResource.META_SCENE)
		_say("Снята <ExtScene>-привязка с «%s»." % node.name)
	else:
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {})
		if bindings.has(prop):
			bindings = bindings.duplicate()
			bindings.erase(prop)
			if bindings.is_empty():
				node.remove_meta(VrwebExtResource.META_BINDINGS)
			else:
				node.set_meta(VrwebExtResource.META_BINDINGS, bindings)
		_say("Снята привязка свойства «%s»." % prop)
	_mark_dirty()


func _on_load_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Нет открытой сцены.")
		return
	var n := _preview.load_preview(root)
	_say("Превью: запрошено %d внешних ресурсов." % n)


func _on_clear_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	_preview.clear_preview(root)
	_say("Превью очищено.")


# --- Утилиты ---

func _selected_node() -> Node:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if sel.is_empty():
		_say("Выберите узел в дереве сцены.")
		return null
	return sel[0]


func _mark_dirty() -> void:
	# Метим сцену как изменённую, чтобы привязки сохранились (set_meta сам этого не делает).
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		EditorInterface.mark_scene_as_unsaved()


func _say(text: String) -> void:
	if _status != null:
		_status.text = text
	print("[VRWeb Tools] ", text)
