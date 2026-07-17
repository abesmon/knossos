@tool
extends EditorPlugin

## Portable VRWeb authoring plugin. Knossos-only preview/import behavior is loaded through an
## optional project-configured integration script and is not a compile-time addon dependency.

const EXPORT_TYPES := [
	"Texture2D", "ImageTexture", "CompressedTexture2D",
	"AudioStreamMP3", "AudioStreamOggVorbis", "AudioStreamWAV",
	"Mesh", "ArrayMesh", "PackedScene",
]
const EXPORT_AS_VRWML_ID := 0x5652574D # "VRWM"
const INTEGRATION_SETTING := "vrweb/tools/integration_script"
const DIST_SETTING := "vrweb/maker/dist_dir"
const BUILD_MODE_SETTING := "vrweb/maker/html_mode"
const JS_ADAPTER_SETTING := "vrweb/maker/javascript_adapter_script"
const NODE_EXECUTABLE_SETTING := "vrweb/maker/node_executable"
const EDITOR_EXECUTABLE_SETTING := "vrweb_maker/knossos_executable"
const EDITOR_LAUNCH_MODE_SETTING := "vrweb_maker/launch_mode"

var _dock: VBoxContainer
var _dock_scroll: ScrollContainer
var _integration_slot: VBoxContainer
var _prop_edit: LineEdit
var _url_edit: LineEdit
var _type_opt: OptionButton
var _status: Label
var _file_dialog: EditorFileDialog
var _knossos_file_dialog: EditorFileDialog
var _local_asset_dialog: EditorFileDialog
var _review_dialog: AcceptDialog
var _knossos_path_edit: LineEdit
var _launch_mode_opt: OptionButton
var _build_run_button: Button
var _cancel_source_build_button: Button
var _pending_launch_path := ""
var _source_build_queue: Array[VrwebWasmSourceComponent] = []
var _current_source_build: VrwebWasmSourceComponent
var _portable_html_importer: EditorSceneFormatImporter
var _integration: Object


func _enter_tree() -> void:
	_ensure_settings()
	_register_export_as_menu()
	_build_dock()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock_scroll)
	_build_export_dialog()
	_register_portable_importer()
	_load_integration()
	scene_changed.connect(_on_editor_scene_changed)
	_on_editor_scene_changed(EditorInterface.get_edited_scene_root())


func _exit_tree() -> void:
	if _current_source_build != null and _current_source_build.is_package_build_running():
		_current_source_build.cancel_package_build()
	_source_build_queue.clear()
	_current_source_build = null
	if scene_changed.is_connected(_on_editor_scene_changed):
		scene_changed.disconnect(_on_editor_scene_changed)
	if _integration != null and _integration.has_method("teardown"):
		_integration.call("teardown")
	_integration = null
	if _portable_html_importer != null:
		remove_scene_format_importer_plugin(_portable_html_importer)
		_portable_html_importer = null
	_unregister_export_as_menu()
	remove_control_from_docks(_dock_scroll)
	if is_instance_valid(_dock_scroll):
		_dock_scroll.queue_free()
	if is_instance_valid(_file_dialog):
		_file_dialog.queue_free()
	if is_instance_valid(_review_dialog):
		_review_dialog.queue_free()
	if is_instance_valid(_knossos_file_dialog):
		_knossos_file_dialog.queue_free()
	if is_instance_valid(_local_asset_dialog):
		_local_asset_dialog.queue_free()


func _build_dock() -> void:
	_dock_scroll = ScrollContainer.new()
	_dock_scroll.name = "VRWeb"
	_dock_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dock_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_dock = VBoxContainer.new()
	_dock.name = "Content"
	_dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dock_scroll.add_child(_dock)

	_dock.add_child(_heading("Внешний ресурс → выбранный узел"))
	_prop_edit = LineEdit.new()
	_prop_edit.placeholder_text = "свойство (напр. texture); пусто = ExtScene"
	_dock.add_child(_prop_edit)
	_url_edit = LineEdit.new()
	_url_edit.placeholder_text = "URL (http(s):// или vrweb-адрес)"
	_dock.add_child(_url_edit)
	_type_opt = OptionButton.new()
	for type_name in EXPORT_TYPES:
		_type_opt.add_item(type_name)
	_dock.add_child(_type_opt)
	_dock.add_child(_button("Привязать к узлу", _on_bind_pressed))
	_dock.add_child(_button("Привязать local asset…", _on_bind_local_pressed))
	_dock.add_child(_button("Убрать привязку", _on_unbind_pressed))

	_dock.add_child(_sep())
	_dock.add_child(_heading("Build & Run · production runtime"))
	_knossos_path_edit = LineEdit.new()
	_knossos_path_edit.placeholder_text = "Knossos executable или macOS .app"
	_knossos_path_edit.text = str(EditorInterface.get_editor_settings().get_setting(
			EDITOR_EXECUTABLE_SETTING))
	_dock.add_child(_knossos_path_edit)
	_dock.add_child(_button("Выбрать executable…", _on_choose_knossos_pressed))
	_launch_mode_opt = OptionButton.new()
	for mode in VrwebLauncher.MODES:
		_launch_mode_opt.add_item(mode)
	var saved_mode := str(EditorInterface.get_editor_settings().get_setting(
			EDITOR_LAUNCH_MODE_SETTING))
	_launch_mode_opt.select(1 if saved_mode == VrwebLauncher.MODE_DEEPLINK else 0)
	_dock.add_child(_launch_mode_opt)
	_build_run_button = _button("Build & Run in Knossos", _on_build_run_pressed)
	_dock.add_child(_build_run_button)
	_cancel_source_build_button = _button("Cancel Script Build", _on_cancel_source_build_pressed)
	_cancel_source_build_button.disabled = true
	_dock.add_child(_cancel_source_build_button)
	_dock.add_child(_button("Add VRWeb Script", _on_add_vrweb_script_pressed))

	_integration_slot = VBoxContainer.new()
	_integration_slot.name = "Integration"
	_dock.add_child(_integration_slot)

	_dock.add_child(_sep())
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dock.add_child(_status)


func _build_export_dialog() -> void:
	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_file_dialog.add_filter("*.vrwml", "VRWML scene")
	_file_dialog.add_filter("*.html", "HTML with VRWML wrapper")
	_file_dialog.add_option("HTML scene mode", PackedStringArray([
		VrwebFormat.MODE_COMBINE,
		VrwebFormat.MODE_EXCLUSIVE,
	]), 0)
	_file_dialog.add_option("Validation profile", PackedStringArray([
		VrwebCompatibility.PROFILE_STRICT,
		VrwebCompatibility.PROFILE_COMPATIBLE,
	]), 0)
	_file_dialog.file_selected.connect(_on_export_path_chosen)
	EditorInterface.get_base_control().add_child(_file_dialog)
	_review_dialog = AcceptDialog.new()
	_review_dialog.title = "VRWeb export review"
	_review_dialog.min_size = Vector2i(620, 320)
	EditorInterface.get_base_control().add_child(_review_dialog)
	_review_dialog.confirmed.connect(_on_review_confirmed)
	_review_dialog.canceled.connect(_on_review_canceled)
	_knossos_file_dialog = EditorFileDialog.new()
	_knossos_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_ANY
	_knossos_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_knossos_file_dialog.file_selected.connect(_on_knossos_path_chosen)
	EditorInterface.get_base_control().add_child(_knossos_file_dialog)
	_local_asset_dialog = EditorFileDialog.new()
	_local_asset_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_local_asset_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_local_asset_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp,*.svg", "Web images")
	_local_asset_dialog.add_filter("*.mp3,*.ogg,*.wav", "Web audio")
	_local_asset_dialog.add_filter("*.glb,*.gltf", "glTF scene")
	_local_asset_dialog.file_selected.connect(_on_local_asset_chosen)
	EditorInterface.get_base_control().add_child(_local_asset_dialog)


func _ensure_settings() -> void:
	if not ProjectSettings.has_setting(DIST_SETTING):
		ProjectSettings.set_setting(DIST_SETTING, "res://dist")
	ProjectSettings.set_initial_value(DIST_SETTING, "res://dist")
	ProjectSettings.add_property_info({"name": DIST_SETTING, "type": TYPE_STRING})
	if not ProjectSettings.has_setting(BUILD_MODE_SETTING):
		ProjectSettings.set_setting(BUILD_MODE_SETTING, VrwebFormat.MODE_EXCLUSIVE)
	ProjectSettings.set_initial_value(BUILD_MODE_SETTING, VrwebFormat.MODE_EXCLUSIVE)
	ProjectSettings.add_property_info({"name": BUILD_MODE_SETTING, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM, "hint_string": "exclusive,combine"})
	if not ProjectSettings.has_setting(JS_ADAPTER_SETTING):
		ProjectSettings.set_setting(JS_ADAPTER_SETTING, "")
	ProjectSettings.set_initial_value(JS_ADAPTER_SETTING, "")
	ProjectSettings.add_property_info({"name": JS_ADAPTER_SETTING, "type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE, "hint_string": "*.mjs"})
	if not ProjectSettings.has_setting(NODE_EXECUTABLE_SETTING):
		ProjectSettings.set_setting(NODE_EXECUTABLE_SETTING, "node")
	ProjectSettings.set_initial_value(NODE_EXECUTABLE_SETTING, "node")
	ProjectSettings.add_property_info({"name": NODE_EXECUTABLE_SETTING, "type": TYPE_STRING})
	var editor_settings := EditorInterface.get_editor_settings()
	if not editor_settings.has_setting(EDITOR_EXECUTABLE_SETTING):
		editor_settings.set_setting(EDITOR_EXECUTABLE_SETTING, "")
	if not editor_settings.has_setting(EDITOR_LAUNCH_MODE_SETTING):
		editor_settings.set_setting(EDITOR_LAUNCH_MODE_SETTING, VrwebLauncher.MODE_EXECUTABLE)


func _register_portable_importer() -> void:
	_portable_html_importer = preload("res://addons/vrweb_tools/vrweb_portable_html_scene_importer.gd").new()
	add_scene_format_importer_plugin(_portable_html_importer)


func _load_integration() -> void:
	var path := str(ProjectSettings.get_setting(INTEGRATION_SETTING, ""))
	if path.is_empty():
		return
	var script := ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_REUSE) as Script
	if script == null:
		_say("Не удалось загрузить VRWeb integration: %s" % path)
		return
	_integration = script.new()
	if _integration == null or not _integration.has_method("setup"):
		_say("VRWeb integration не реализует setup().")
		_integration = null
		return
	_integration.call("setup", self, _integration_slot, Callable(self, "_say"))


func _register_export_as_menu() -> void:
	var menu := get_export_as_menu()
	if menu.get_item_index(EXPORT_AS_VRWML_ID) >= 0:
		return
	menu.add_item("VRWML Scene…", EXPORT_AS_VRWML_ID)
	var index := menu.get_item_index(EXPORT_AS_VRWML_ID)
	menu.set_item_metadata(index, _on_export_scene_pressed)


func _unregister_export_as_menu() -> void:
	var menu := get_export_as_menu()
	var index := menu.get_item_index(EXPORT_AS_VRWML_ID)
	if index >= 0:
		menu.remove_item(index)


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
	_pending_launch_path = ""
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Нет открытой сцены.")
		return
	var extension := path.get_extension().to_lower()
	var selected_options := _file_dialog.get_selected_options()
	var profile_index := int(selected_options.get("Validation profile", 0))
	var profile := VrwebCompatibility.PROFILE_COMPATIBLE if profile_index == 1 \
			else VrwebCompatibility.PROFILE_STRICT
	var report: Dictionary
	if extension == "vrwml":
		report = VrwebExporter.export_vrwml_report(root, path, profile)
	elif extension == "html":
		var mode_index := int(selected_options.get("HTML scene mode", 0))
		var mode := VrwebFormat.MODE_EXCLUSIVE if mode_index == 1 else VrwebFormat.MODE_COMBINE
		report = VrwebExporter.export_scene_report(root, mode, path, profile)
	else:
		_say("Выберите формат .vrwml или .html.")
		return
	if not bool(report.get("ok", false)):
		_say("Экспорт остановлен: %s" % "; ".join(report.get("errors", [])))
		_show_export_review(report, path, false)
		return
	var output := str(report.get("vrwml" if extension == "vrwml" else "html", ""))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_say("Не удалось записать %s (код %d)." % [path, FileAccess.get_open_error()])
		return
	file.store_string(output)
	file.close()
	report["output_file"] = {"file": path, "sha256": _sha256_text(output)}
	EditorInterface.get_resource_filesystem().scan()
	var warnings: Array = report.get("warnings", [])
	var suffix := "; warnings: %d — смотрите Output" % warnings.size() \
			if not warnings.is_empty() else ""
	_say("Экспортировано: %s; packages: %d%s" % [
		path, report.get("packages", []).size(), suffix])
	_show_export_review(report, path, true)


func _on_choose_knossos_pressed() -> void:
	_knossos_file_dialog.current_path = _knossos_path_edit.text
	_knossos_file_dialog.popup_centered_ratio(0.7)


func _on_knossos_path_chosen(path: String) -> void:
	_knossos_path_edit.text = path
	EditorInterface.get_editor_settings().set_setting(EDITOR_EXECUTABLE_SETTING, path)


func _on_build_run_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Нет открытой сцены для Build & Run.")
		return
	if _source_build_queue.is_empty() and _current_source_build == null:
		_collect_source_components(root, _source_build_queue)
		var source_state := _advance_source_build_queue()
		if source_state != "complete": return
	var basename := root.name.to_snake_case()
	if not root.scene_file_path.is_empty():
		basename = root.scene_file_path.get_file().get_basename()
	if basename.is_empty():
		basename = "world"
	var dist_dir := str(ProjectSettings.get_setting(DIST_SETTING, "res://dist")).trim_suffix("/")
	var path := dist_dir.path_join(basename + ".html")
	var mode := VrwebFormat.normalized_mode(str(ProjectSettings.get_setting(
			BUILD_MODE_SETTING, VrwebFormat.MODE_EXCLUSIVE)))
	var report := VrwebExporter.export_scene_report(root, mode, path,
			VrwebCompatibility.PROFILE_STRICT)
	if not bool(report.get("ok", false)):
		_pending_launch_path = ""
		_say("Build остановлен: %s" % "; ".join(report.get("errors", [])))
		_show_export_review(report, path, false)
		return
	var output := str(report.get("html", ""))
	if not _write_text(path, output):
		report.ok = false
		report.errors.append("Не удалось записать " + path)
		_pending_launch_path = ""
		_say(str(report.errors[-1]))
		_show_export_review(report, path, false)
		return
	report["output_file"] = {"file": path, "sha256": _sha256_text(output)}
	_write_json_report(path.get_basename() + ".report.json", report)
	EditorInterface.get_resource_filesystem().scan()
	var editor_settings := EditorInterface.get_editor_settings()
	editor_settings.set_setting(EDITOR_EXECUTABLE_SETTING, _knossos_path_edit.text.strip_edges())
	editor_settings.set_setting(EDITOR_LAUNCH_MODE_SETTING,
			_launch_mode_opt.get_item_text(_launch_mode_opt.selected))
	_pending_launch_path = path
	_say("Build готов: %s. Подтвердите report для запуска." % path)
	_show_export_review(report, path, true)


func _process(_delta: float) -> void:
	if _current_source_build == null: return
	var result := _current_source_build.poll_package_build()
	if bool(result.get("running", false)):
		_say("Сборка %s…" % _current_source_build.module_id)
		return
	if not bool(result.get("ok", false)):
		_abort_source_builds(str(result.get("error", "source build failed")))
		return
	_current_source_build = null
	var state := _advance_source_build_queue()
	if state == "complete":
		call_deferred("_on_build_run_pressed")


func _advance_source_build_queue() -> String:
	while not _source_build_queue.is_empty():
		var component: VrwebWasmSourceComponent = _source_build_queue.pop_front()
		var result: Dictionary = component.start_package_build()
		if not bool(result.get("ok", false)):
			_abort_source_builds(str(result.get("error", "source build failed")))
			return "error"
		if bool(result.get("running", false)):
			_current_source_build = component
			set_process(true)
			_build_run_button.disabled = true
			_cancel_source_build_button.disabled = false
			_say("Сборка %s…" % component.module_id)
			return "running"
	set_process(false)
	_build_run_button.disabled = false
	_cancel_source_build_button.disabled = true
	return "complete"


func _on_cancel_source_build_pressed() -> void:
	if _current_source_build != null:
		_current_source_build.cancel_package_build()
	_abort_source_builds("Сборка VRWeb Script отменена; последний успешный package сохранён.")


func _abort_source_builds(message: String) -> void:
	_source_build_queue.clear()
	_current_source_build = null
	set_process(false)
	_build_run_button.disabled = false
	_cancel_source_build_button.disabled = true
	_say(message)


func _collect_source_components(node: Node,
		result: Array[VrwebWasmSourceComponent]) -> void:
	if node is VrwebWasmSourceComponent: result.append(node)
	for child in node.get_children(): _collect_source_components(child, result)


func _on_add_vrweb_script_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_say("Сначала откройте или создайте сцену.")
		return
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var parent: Node = selected[0] if not selected.is_empty() else root
	var base_name := "interaction"
	var index := 1
	while DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(
			"res://vrweb_scripts/" + base_name)):
		index += 1
		base_name = "interaction_%d" % index
	var directory := "res://vrweb_scripts/" + base_name
	var source_path := directory.path_join("main.ts")
	var manifest_path := directory.path_join("vrweb-module.json")
	var package_path := directory.path_join("build/module.vrmod")
	var module_id := "vrweb.local." + base_name.replace("_", "-")
	var source := """import { core, scene, state, value } from \"@vrweb/sdk\";

let instance = 1;
export function create(): number { return instance++; }
export function mount(_instance: number): number { return 0; }
export function event(_instance: number, _event: Uint8Array): number {
  const root = scene.root();
  scene.transaction().set(root, \"visible\", value.bool(true)).commit();
  state.command({ key: \"active\", command: \"toggle\" });
  core.logCode(1);
  return 0;
}
export function unmount(_instance: number): number { return 0; }
"""
	var manifest := {
		"format": 1, "id": module_id, "version": "1.0.0", "sdk": "1.0.0",
		"runtime": "wasm-component", "world": "vrweb:module@1",
		"component": "build/module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"requires": ["vrweb:core/1", "vrweb:scene/1", "vrweb:state/1"],
		"optional": [], "limits": {"fuel": 50_000_000},
	}
	if not _write_text(source_path, source) or not _write_text(
			manifest_path, JSON.stringify(manifest, "  ") + "\n"):
		_say("Не удалось создать VRWeb Script template.")
		return
	var component := VrwebWasmSourceComponent.new()
	component.name = base_name.to_pascal_case()
	component.module_id = module_id
	component.export_name = "default"
	component.source_path = source_path
	component.manifest_path = manifest_path
	component.package_path = package_path
	component.adapter_script = str(ProjectSettings.get_setting(JS_ADAPTER_SETTING, ""))
	component.node_executable = str(ProjectSettings.get_setting(NODE_EXECUTABLE_SETTING, "node"))
	parent.add_child(component, true)
	component.owner = root
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(component)
	EditorInterface.get_resource_filesystem().scan()
	_say("VRWeb Script создан: %s. Настройте adapter path в Project Settings и запустите Build & Run." \
			% source_path)


func _write_text(path: String, content: String) -> bool:
	var absolute_dir := ProjectSettings.globalize_path(path.get_base_dir())
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return true


func _write_json_report(path: String, report: Dictionary) -> void:
	var summary := report.duplicate(true)
	summary.erase("html")
	summary.erase("vrwml")
	_write_text(path, JSON.stringify(summary, "  ") + "\n")


func _on_review_confirmed() -> void:
	if _pending_launch_path.is_empty():
		return
	var path := _pending_launch_path
	_pending_launch_path = ""
	var result := VrwebLauncher.launch(path, _knossos_path_edit.text.strip_edges(),
			_launch_mode_opt.get_item_text(_launch_mode_opt.selected))
	if not bool(result.get("ok", false)):
		_say("Knossos не запущен: %s" % result.get("error", "unknown error"))
		return
	_say("Knossos запущен: %s" % result.get("url", ""))


func _on_review_canceled() -> void:
	_pending_launch_path = ""


func _show_export_review(report: Dictionary, path: String, written: bool) -> void:
	if _review_dialog == null:
		return
	var lines: Array[String] = [
		"Result: %s" % ("written" if written else "blocked"),
		"Output: %s" % path,
		"Profile: %s (policy %s)" % [report.get("profile", ""),
			report.get("policy_version", "")],
		"Packages: %d" % report.get("packages", []).size(),
		"Assets: %d" % report.get("assets", []).size(),
	]
	var output_file: Dictionary = report.get("output_file", {})
	if not output_file.is_empty():
		lines.append("Output SHA-256: %s" % output_file.get("sha256", ""))
	for package in report.get("packages", []):
		lines.append("Package: %s; SHA-256: %s; files: %d" % [
			package.get("file", ""), package.get("hash", ""), package.get("files", []).size()])
	var asset_manifest: Dictionary = report.get("asset_manifest", {})
	if not asset_manifest.is_empty():
		lines.append("Asset manifest: %s; SHA-256: %s" % [asset_manifest.get("file", ""),
			asset_manifest.get("sha256", "")])
	var errors: Array = report.get("errors", [])
	var warnings: Array = report.get("warnings", [])
	if not errors.is_empty():
		lines.append("\nErrors (%d):" % errors.size())
		for message in errors:
			lines.append("• " + str(message))
	if not warnings.is_empty():
		lines.append("\nWarnings (%d):" % warnings.size())
		for message in warnings:
			lines.append("• " + str(message))
	if errors.is_empty() and warnings.is_empty():
		lines.append("\nNo known compatibility losses.")
	_review_dialog.ok_button_text = "Run in Knossos" if not _pending_launch_path.is_empty() else "OK"
	_review_dialog.dialog_text = "\n".join(lines)
	_review_dialog.popup_centered()


func _sha256_text(content: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(content.to_utf8_buffer())
	return context.finish().hex_encode()


func _on_bind_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	var url := _url_edit.text.strip_edges()
	if url.is_empty():
		_say("Укажите URL.")
		return
	var external := VrwebExtResource.new()
	external.url = url
	external.type = _type_opt.get_item_text(_type_opt.selected)
	var property_name := _prop_edit.text.strip_edges()
	if property_name.is_empty():
		external.type = "PackedScene"
		node.set_meta(VrwebExtResource.META_SCENE, external)
		_say("Привязан <ExtScene> к «%s»." % node.name)
	else:
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {}).duplicate()
		bindings[property_name] = external
		node.set_meta(VrwebExtResource.META_BINDINGS, bindings)
		_say("Привязано %s ← %s (%s)." % [property_name, url, external.type])
	_mark_dirty()


func _on_bind_local_pressed() -> void:
	if _selected_node() == null:
		return
	_local_asset_dialog.popup_centered_ratio(0.7)


func _on_local_asset_chosen(path: String) -> void:
	var node := _selected_node()
	if node == null:
		return
	var local := VrwebLocalAsset.new()
	local.source_path = path
	local.type = _type_opt.get_item_text(_type_opt.selected)
	var property_name := _prop_edit.text.strip_edges()
	if property_name.is_empty():
		local.type = "PackedScene"
		node.set_meta(VrwebExtResource.META_SCENE, local)
		_say("Привязан local <ExtScene>: %s" % path)
	else:
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {}).duplicate()
		bindings[property_name] = local
		node.set_meta(VrwebExtResource.META_BINDINGS, bindings)
		_say("Привязан local asset %s ← %s." % [property_name, path])
	_mark_dirty()


func _on_unbind_pressed() -> void:
	var node := _selected_node()
	if node == null:
		return
	var property_name := _prop_edit.text.strip_edges()
	if property_name.is_empty():
		if node.has_meta(VrwebExtResource.META_SCENE):
			node.remove_meta(VrwebExtResource.META_SCENE)
		_say("Снята <ExtScene>-привязка с «%s»." % node.name)
	else:
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS, {})
		if bindings.has(property_name):
			bindings = bindings.duplicate()
			bindings.erase(property_name)
			if bindings.is_empty():
				node.remove_meta(VrwebExtResource.META_BINDINGS)
			else:
				node.set_meta(VrwebExtResource.META_BINDINGS, bindings)
		_say("Снята привязка свойства «%s»." % property_name)
	_mark_dirty()


func _save_external_data() -> void:
	if _integration != null and _integration.has_method("save_external_data"):
		_integration.call("save_external_data")


func _on_editor_scene_changed(root: Node) -> void:
	if _integration != null and _integration.has_method("on_scene_changed"):
		_integration.call("on_scene_changed", root)


func _selected_node() -> Node:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.is_empty():
		_say("Выберите узел в дереве сцены.")
		return null
	return selected[0]


func _mark_dirty() -> void:
	if EditorInterface.get_edited_scene_root() != null:
		EditorInterface.mark_scene_as_unsaved()


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


func _say(text: String) -> void:
	if _status != null and _status.text == text:
		return
	if _status != null: _status.text = text
	print("[VRWeb Tools] ", text)
