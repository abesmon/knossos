@tool
extends RefCounted

## Knossos editor integration loaded by the portable addon through a project setting. This
## file may depend on client runtime classes; nothing under addons/vrweb_tools imports it.

var _plugin: EditorPlugin
var _say: Callable
var _preview: VrwebExtPreview
var _vrwml_scene_importer: EditorSceneFormatImporter
var _vrwml_open_dialog: EditorFileDialog
var _tscn_save_dialog: EditorFileDialog
var _vrwml_import_path := ""
var _vrwml_open_mode := "import"
var _vrwml_preview_avatar: Avatar
var _vrwml_preview_loaders: Node
var _html_preview_loaders: Node


func setup(plugin: EditorPlugin, dock: VBoxContainer, say: Callable) -> void:
	_plugin = plugin
	_say = say
	_preview = VrwebExtPreview.new(plugin)
	_build_dock(dock)
	_register_importers()
	_build_dialogs()


func teardown() -> void:
	_clear_html_preview_loaders()
	_clear_vrwml_preview()
	if _vrwml_scene_importer != null:
		_plugin.remove_scene_format_importer_plugin(_vrwml_scene_importer)
		_vrwml_scene_importer = null
	if is_instance_valid(_vrwml_open_dialog):
		_vrwml_open_dialog.queue_free()
	if is_instance_valid(_tscn_save_dialog):
		_tscn_save_dialog.queue_free()
	_plugin = null


func save_external_data() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		return
	var result := VrwebHtmlSceneSaver.save_root(root)
	if not bool(result.get("ok", false)):
		push_error("HTML scene save: %s" % result.get("error", "unknown error"))


func on_scene_changed(root: Node) -> void:
	_clear_html_preview_loaders()
	if root == null or not root.has_meta(VrwebHtmlDocument.META_SOURCE_PATH):
		return
	VrwebHtmlSceneCodec.attach_procedural_preview(root)
	VrwebHtmlSceneCodec.make_preview_internal(root)
	_load_html_preview_images(root)
	if bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		_status("HTML scene: <vrweb> редактируемый, procedural geometry — read-only preview.")
	else:
		_status("HTML открыт только для preview: %s." %
				str(root.get_meta(VrwebHtmlDocument.META_READ_ONLY_REASON,
				"нет editable <vrweb>")))


func _build_dock(dock: VBoxContainer) -> void:
	dock.add_child(_sep())
	dock.add_child(_heading("Avatar VRWML · Knossos"))
	dock.add_child(_button("Preview Avatar VRWML…", _on_preview_vrwml_pressed))
	dock.add_child(_button("Очистить Avatar preview", _on_clear_vrwml_preview_pressed))
	dock.add_child(_button("Avatar VRWML → редактируемая TSCN…", _on_import_vrwml_pressed))
	dock.add_child(_sep())
	dock.add_child(_heading("Knossos runtime preview"))
	dock.add_child(_button("Загрузить external preview", _on_load_preview))
	dock.add_child(_button("Очистить external preview", _on_clear_preview))
	dock.add_child(_button("Сохранить импортированный HTML", _on_save_html_scene))


func _register_importers() -> void:
	_vrwml_scene_importer = preload(
			"res://integrations/knossos/vrweb_tools/vrwml_avatar_scene_importer.gd").new()
	_plugin.add_scene_format_importer_plugin(_vrwml_scene_importer)


func _build_dialogs() -> void:
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


func _on_import_vrwml_pressed() -> void:
	_vrwml_open_mode = "import"
	_vrwml_open_dialog.popup_centered_ratio(0.6)


func _on_preview_vrwml_pressed() -> void:
	if EditorInterface.get_edited_scene_root() == null:
		_status("Откройте сцену, к которой временно добавить preview.")
		return
	_vrwml_open_mode = "preview"
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
		_status(str(parsed.error))
		return
	var avatar := parsed.avatar as Avatar
	var external: Dictionary = parsed.ext
	if not external.get("targets", []).is_empty():
		var loader_host := Node.new()
		loader_host.name = "VrwmlImportLoaders"
		EditorInterface.get_base_control().add_child(loader_host)
		var image_loader := ImageLoader.new()
		loader_host.add_child(image_loader)
		_status("Загружаю внешние ресурсы VRWML…")
		VrwebExtInjector.inject(external, image_loader, loader_host, func() -> void:
			_finish_vrwml_import(avatar, path)
			loader_host.queue_free())
		return
	_finish_vrwml_import(avatar, path)


func _load_vrwml_preview(path: String) -> void:
	var parsed := _parse_avatar_vrwml(path)
	if not str(parsed.get("error", "")).is_empty():
		_status(str(parsed.error))
		return
	_clear_vrwml_preview()
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		(parsed.avatar as Avatar).free()
		_status("Открытая сцена исчезла до materialization preview.")
		return
	_vrwml_preview_avatar = parsed.avatar as Avatar
	_vrwml_preview_avatar.name = "VRWMLPreview_" + _vrwml_preview_avatar.name
	root.add_child(_vrwml_preview_avatar)
	var external: Dictionary = parsed.ext
	if external.get("targets", []).is_empty():
		_status("Avatar preview загружен в viewport; SceneTree намеренно не меняется.")
		return
	_vrwml_preview_loaders = Node.new()
	_vrwml_preview_loaders.name = "VrwmlPreviewLoaders"
	EditorInterface.get_base_control().add_child(_vrwml_preview_loaders)
	var image_loader := ImageLoader.new()
	_vrwml_preview_loaders.add_child(image_loader)
	_status("Viewport preview создан; загружаю внешние ресурсы…")
	VrwebExtInjector.inject(external, image_loader, _vrwml_preview_loaders, func() -> void:
		_status("Avatar VRWML preview и внешние ресурсы загружены.")
		if is_instance_valid(_vrwml_preview_loaders):
			_vrwml_preview_loaders.queue_free()
		_vrwml_preview_loaders = null)


func _on_clear_vrwml_preview_pressed() -> void:
	_clear_vrwml_preview()
	_status("Avatar VRWML preview очищен.")


func _clear_vrwml_preview() -> void:
	if is_instance_valid(_vrwml_preview_avatar):
		_vrwml_preview_avatar.queue_free()
	_vrwml_preview_avatar = null
	if is_instance_valid(_vrwml_preview_loaders):
		_vrwml_preview_loaders.queue_free()
	_vrwml_preview_loaders = null


func _parse_avatar_vrwml(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
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
	var error := packed.pack(avatar)
	avatar.free()
	if error == OK:
		error = ResourceSaver.save(packed, path)
	if error != OK:
		_status("Не удалось сохранить %s (код %d)." % [path, error])
		return
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	_status("Создана редактируемая сцена: %s" % path)


func _on_load_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_status("Нет открытой сцены.")
		return
	var count := _preview.load_preview(root)
	_status("Превью: запрошено %d внешних ресурсов." % count)


func _on_clear_preview() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	_preview.clear_preview(root)
	_status("Превью очищено.")


func _on_save_html_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		_status("Открытая сцена не является редактируемым HTML с <vrweb>.")
		return
	var result := VrwebHtmlSceneSaver.save_root(root)
	if bool(result.get("ok", false)):
		_status("HTML сохранён: изменён только блок <vrweb>.")
		EditorInterface.get_resource_filesystem().scan()
	else:
		_status("HTML не сохранён: %s" % result.get("error", "unknown error"))


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


func _set_scene_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_scene_owner_recursive(child, root)


func _status(message: String) -> void:
	if _say.is_valid():
		_say.call(message)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	return label


func _button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	return button


func _sep() -> HSeparator:
	return HSeparator.new()
