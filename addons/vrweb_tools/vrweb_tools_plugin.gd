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
const EXPORT_AS_VRWML_ID := 0x5652574D # "VRWM"

var _dock: Control
var _dock_scroll: ScrollContainer
var _prop_edit: LineEdit
var _url_edit: LineEdit
var _type_opt: OptionButton
var _status: Label
var _file_dialog: EditorFileDialog
var _vrwml_open_dialog: EditorFileDialog
var _tscn_save_dialog: EditorFileDialog
var _vrwml_import_path := ""
var _vrwml_open_mode := "import"
var _vrwml_preview_avatar: Avatar
var _vrwml_preview_loaders: Node
var _preview: VrwebExtPreview
var _vrwml_scene_importer: EditorSceneFormatImporter
var _html_scene_importer: EditorSceneFormatImporter
var _html_preview_loaders: Node


func _enter_tree() -> void:
	_preview = VrwebExtPreview.new(self)
	_register_export_as_menu()
	_build_dock()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock_scroll)
	_vrwml_scene_importer = preload("res://addons/vrweb_tools/vrwml_avatar_scene_importer.gd").new()
	add_scene_format_importer_plugin(_vrwml_scene_importer)
	_html_scene_importer = preload("res://addons/vrweb_tools/vrweb_html_scene_importer.gd").new()
	add_scene_format_importer_plugin(_html_scene_importer)
	scene_changed.connect(_on_editor_scene_changed)
	_on_editor_scene_changed(EditorInterface.get_edited_scene_root())

	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_file_dialog.add_filter("*.vrwml", "VRWML scene")
	_file_dialog.add_filter("*.html", "HTML with VRWeb wrapper")
	_file_dialog.add_option("HTML scene mode", PackedStringArray([
		VrwebBuilder.MODE_COMBINE,
		VrwebBuilder.MODE_EXCLUSIVE,
	]), 0)
	_file_dialog.file_selected.connect(_on_export_path_chosen)
	EditorInterface.get_base_control().add_child(_file_dialog)

	_vrwml_open_dialog = EditorFileDialog.new()
	_vrwml_open_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_vrwml_open_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_vrwml_open_dialog.add_filter("*.vrwml", "VRWML")
	_vrwml_open_dialog.current_dir = "res://avatars/"
	_vrwml_open_dialog.file_selected.connect(_on_vrwml_import_chosen)
	EditorInterface.get_base_control().add_child(_vrwml_open_dialog)

	_tscn_save_dialog = EditorFileDialog.new()
	_tscn_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_tscn_save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_tscn_save_dialog.add_filter("*.tscn", "Godot scene")
	_tscn_save_dialog.file_selected.connect(_on_vrwml_tscn_chosen)
	EditorInterface.get_base_control().add_child(_tscn_save_dialog)


func _exit_tree() -> void:
	_clear_html_preview_loaders()
	_clear_vrwml_preview()
	_unregister_export_as_menu()
	if scene_changed.is_connected(_on_editor_scene_changed):
		scene_changed.disconnect(_on_editor_scene_changed)
	if _vrwml_scene_importer != null:
		remove_scene_format_importer_plugin(_vrwml_scene_importer)
		_vrwml_scene_importer = null
	if _html_scene_importer != null:
		remove_scene_format_importer_plugin(_html_scene_importer)
		_html_scene_importer = null
	remove_control_from_docks(_dock_scroll)
	if is_instance_valid(_dock_scroll):
		_dock_scroll.queue_free()
	if is_instance_valid(_file_dialog):
		_file_dialog.queue_free()
	if is_instance_valid(_vrwml_open_dialog):
		_vrwml_open_dialog.queue_free()
	if is_instance_valid(_tscn_save_dialog):
		_tscn_save_dialog.queue_free()


# --- Построение дока ---

func _build_dock() -> void:
	_dock_scroll = ScrollContainer.new()
	_dock_scroll.name = "VRWeb"
	_dock_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dock_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_dock = VBoxContainer.new()
	_dock.name = "Content"
	_dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dock_scroll.add_child(_dock)

	_dock.add_child(_heading("Avatar VRWML"))
	_dock.add_child(_button("Preview Avatar VRWML…", _on_preview_vrwml_pressed))
	_dock.add_child(_button("Очистить Avatar preview", _on_clear_vrwml_preview_pressed))
	_dock.add_child(_button("Avatar VRWML → редактируемая TSCN…", _on_import_vrwml_pressed))
	_dock.add_child(_sep())
	_dock.add_child(_heading("Script выбранного узла"))
	_dock.add_child(_button("Экспортировать inline", _on_script_inline_pressed))
	_dock.add_child(_button("Экспортировать package", _on_script_package_pressed))
	_dock.add_child(_button("Не экспортировать Script", _on_script_off_pressed))

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
	_dock.add_child(_button("Сохранить импортированный HTML", _on_save_html_scene))

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


func _register_export_as_menu() -> void:
	var menu := get_export_as_menu()
	if menu.get_item_index(EXPORT_AS_VRWML_ID) >= 0:
		return
	menu.add_item("VRWeb Scene…", EXPORT_AS_VRWML_ID)
	var index := menu.get_item_index(EXPORT_AS_VRWML_ID)
	menu.set_item_metadata(index, _on_export_scene_pressed)


func _unregister_export_as_menu() -> void:
	var menu := get_export_as_menu()
	var index := menu.get_item_index(EXPORT_AS_VRWML_ID)
	if index >= 0:
		menu.remove_item(index)


# --- Действия ---

func _on_export_scene_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Нет открытой сцены для экспорта.")
		return
	var source_path := root.scene_file_path
	var basename := root.name.to_snake_case()
	if not source_path.is_empty():
		_file_dialog.current_dir = source_path.get_base_dir()
		basename = source_path.get_file().get_basename()
	_file_dialog.current_file = basename + ".vrwml"
	_file_dialog.popup_file_dialog()


func _on_export_path_chosen(path: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Нет открытой сцены.")
		return
	var extension := path.get_extension().to_lower()
	var report: Dictionary
	if extension == "vrwml":
		report = VrwebExporter.export_vrwml_report(root, path)
	elif extension == "html":
		var selected_options := _file_dialog.get_selected_options()
		var mode_index := int(selected_options.get("HTML scene mode", 0))
		var mode := VrwebBuilder.MODE_EXCLUSIVE if mode_index == 1 else VrwebBuilder.MODE_COMBINE
		report = VrwebExporter.export_scene_report(root, mode, path)
	else:
		_say("Выберите формат .vrwml или .html.")
		return
	if not bool(report.ok):
		_say("Экспорт остановлен: %s" % "; ".join(report.errors))
		return
	var output := str(report.vrwml if extension == "vrwml" else report.html)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("Не удалось записать %s (код %d)." % [path, FileAccess.get_open_error()])
		return
	f.store_string(output)
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	_say("Экспортировано: %s; packages: %d" % [path, report.packages.size()])


func _on_import_vrwml_pressed() -> void:
	_vrwml_open_mode = "import"
	_vrwml_open_dialog.popup_centered_ratio(0.6)


func _on_vrwml_import_chosen(path: String) -> void:
	if _vrwml_open_mode == "preview":
		_load_vrwml_preview(path)
		return
	_vrwml_import_path = path
	_tscn_save_dialog.current_path = path.get_basename() + ".tscn"
	_tscn_save_dialog.popup_centered_ratio(0.6)


func _on_vrwml_tscn_chosen(path: String) -> void:
	var parsed := _parse_avatar_vrwml(_vrwml_import_path)
	if not str(parsed.get("error", "")).is_empty():
		_say(str(parsed.error))
		return
	var avatar := parsed.avatar as Avatar
	var ext: Dictionary = parsed.ext
	if not ext.get("targets", []).is_empty():
		var loader_host := Node.new()
		loader_host.name = "VrwmlImportLoaders"
		EditorInterface.get_base_control().add_child(loader_host)
		var image_loader := ImageLoader.new()
		loader_host.add_child(image_loader)
		_say("Загружаю внешние ресурсы VRWML…")
		VrwebExtInjector.inject(ext, image_loader, loader_host, func() -> void:
			_finish_vrwml_import(avatar, path)
			loader_host.queue_free())
		return
	_finish_vrwml_import(avatar, path)


func _on_preview_vrwml_pressed() -> void:
	if EditorInterface.get_edited_scene_root() == null:
		_say("Откройте сцену, к которой временно добавить preview.")
		return
	_vrwml_open_mode = "preview"
	_vrwml_open_dialog.popup_centered_ratio(0.6)


func _load_vrwml_preview(path: String) -> void:
	var parsed := _parse_avatar_vrwml(path)
	if not str(parsed.get("error", "")).is_empty():
		_say(str(parsed.error))
		return
	_clear_vrwml_preview()
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		(parsed.avatar as Avatar).free()
		_say("Открытая сцена исчезла до materialization preview.")
		return
	_vrwml_preview_avatar = parsed.avatar as Avatar
	_vrwml_preview_avatar.name = "VRWMLPreview_" + _vrwml_preview_avatar.name
	root.add_child(_vrwml_preview_avatar)
	# owner намеренно не задаётся: preview виден в viewport, но не попадёт в `.tscn`.
	var ext: Dictionary = parsed.ext
	if ext.get("targets", []).is_empty():
		_say("Avatar preview загружен в viewport; SceneTree намеренно не меняется.")
		return
	_vrwml_preview_loaders = Node.new()
	_vrwml_preview_loaders.name = "VrwmlPreviewLoaders"
	EditorInterface.get_base_control().add_child(_vrwml_preview_loaders)
	var image_loader := ImageLoader.new()
	_vrwml_preview_loaders.add_child(image_loader)
	_say("Viewport preview создан (вне SceneTree); загружаю внешние ресурсы…")
	VrwebExtInjector.inject(ext, image_loader, _vrwml_preview_loaders, func() -> void:
		_say("Avatar VRWML preview и внешние ресурсы загружены.")
		if is_instance_valid(_vrwml_preview_loaders):
			_vrwml_preview_loaders.queue_free()
		_vrwml_preview_loaders = null)


func _on_clear_vrwml_preview_pressed() -> void:
	_clear_vrwml_preview()
	_say("Avatar VRWML preview очищен.")


func _clear_vrwml_preview() -> void:
	if is_instance_valid(_vrwml_preview_avatar):
		_vrwml_preview_avatar.queue_free()
	_vrwml_preview_avatar = null
	if is_instance_valid(_vrwml_preview_loaders):
		_vrwml_preview_loaders.queue_free()
	_vrwml_preview_loaders = null


func _parse_avatar_vrwml(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return {"error": "Не удалось прочитать %s." % path}
	var base_url := PageFetcher.LOCAL_SCHEME + ProjectSettings.globalize_path(path)
	var policy := AvatarVrwmlPolicy.new()
	var built := VrwebBuilder.build(HtmlParser.parse(text), base_url, null, policy)
	var holder := built.get("root") as Node3D
	if policy.has_errors() or holder == null or holder.get_child_count() != 1 \
			or not (holder.get_child(0) is Avatar):
		if holder != null:
			holder.free()
		var detail := ": " + policy.summary() if policy.has_errors() else ""
		return {"error": "VRWML не прошёл avatar diagnostics%s" % detail}
	var avatar := holder.get_child(0) as Avatar
	holder.remove_child(avatar)
	holder.free()
	return {"error": "", "avatar": avatar, "ext": built.get("ext", {})}


func _finish_vrwml_import(avatar: Avatar, path: String) -> void:
	_set_scene_owner_recursive(avatar, avatar)
	var packed := PackedScene.new()
	var err := packed.pack(avatar)
	avatar.free()
	if err == OK:
		err = ResourceSaver.save(packed, path)
	if err != OK:
		_say("Не удалось сохранить %s (код %d)." % [path, err])
		return
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	_say("Создана редактируемая сцена: %s" % path)


func _on_script_inline_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	if not (node.get_script() is GDScript):
		_say("У выбранного узла нет GDScript.")
		return
	node.set_meta(VrwebExporter.META_SCRIPT_MODE, VrwebExporter.SCRIPT_MODE_INLINE)
	_mark_dirty()
	_say("Script «%s» будет экспортирован inline." % node.name)


func _on_script_off_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	if node.has_meta(VrwebExporter.META_SCRIPT_MODE):
		node.remove_meta(VrwebExporter.META_SCRIPT_MODE)
	_mark_dirty()
	_say("Script «%s» не будет экспортирован." % node.name)


func _on_script_package_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	if not (node.get_script() is GDScript):
		_say("У выбранного узла нет GDScript.")
		return
	node.set_meta(VrwebExporter.META_SCRIPT_MODE, VrwebExporter.SCRIPT_MODE_PACKAGE)
	_mark_dirty()
	_say("Script «%s» будет экспортирован в .vrmod." % node.name)


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


func _on_save_html_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		_say("Открытая сцена не является редактируемым HTML с <vrweb>.")
		return
	var result := VrwebHtmlSceneSaver.save_root(root)
	if bool(result.ok):
		_say("HTML сохранён: изменён только блок <vrweb>.")
		EditorInterface.get_resource_filesystem().scan()
	else:
		_say("HTML не сохранён: %s" % result.error)


func _save_external_data() -> void:
	# Godot вызывает virtual при явном Save/Save All. Работаем только с live HTML-root;
	# import pipeline сюда не приходит, поэтому исходник не меняется во время импорта.
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		return
	var result := VrwebHtmlSceneSaver.save_root(root)
	if not bool(result.ok):
		push_error("HTML scene save: %s" % result.error)


func _on_editor_scene_changed(root: Node) -> void:
	_clear_html_preview_loaders()
	if root == null or not root.has_meta(VrwebHtmlDocument.META_SOURCE_PATH):
		return
	VrwebHtmlSceneCodec.make_preview_internal(root)
	_load_html_preview_images(root)
	if bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		_say("HTML scene: <vrweb> редактируемый, procedural geometry — read-only preview.")
	else:
		_say("HTML открыт только для preview: %s." %
			str(root.get_meta(VrwebHtmlDocument.META_READ_ONLY_REASON, "нет editable <vrweb>")))


func _load_html_preview_images(root: Node) -> void:
	var targets: Array[MeshInstance3D] = []
	_collect_html_preview_images(root, targets)
	if targets.is_empty():
		return
	_html_preview_loaders = Node.new()
	_html_preview_loaders.name = "HTMLPreviewLoaders"
	EditorInterface.get_base_control().add_child(_html_preview_loaders)
	var loader := ImageLoader.new()
	_html_preview_loaders.add_child(loader)
	for target in targets:
		var url := str(target.get_meta(VrwebHtmlDocument.META_PREVIEW_IMAGE_URL, ""))
		loader.request_image(url, _apply_html_preview_texture.bind(target))


func _collect_html_preview_images(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.has_meta(VrwebHtmlDocument.META_PREVIEW_IMAGE_URL):
		out.append(node)
	for child in node.get_children(true):
		_collect_html_preview_images(child, out)


func _apply_html_preview_texture(texture: Texture2D, target: MeshInstance3D) -> void:
	if texture == null or not is_instance_valid(target):
		return
	var material := target.material_override as StandardMaterial3D
	if material == null:
		material = StandardMaterial3D.new()
		target.material_override = material
	material.albedo_texture = texture
	material.albedo_color = Color.WHITE
	var alt := target.get_node_or_null("../ImageAlt")
	if alt != null:
		alt.visible = false


func _clear_html_preview_loaders() -> void:
	if is_instance_valid(_html_preview_loaders):
		_html_preview_loaders.queue_free()
	_html_preview_loaders = null


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


func _set_scene_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_scene_owner_recursive(child, root)


func _say(text: String) -> void:
	if _status != null:
		_status.text = text
	print("[VRWeb Tools] ", text)
