@tool
extends SceneTree

const TIMEOUT_FRAMES := 3600
const SOURCE := "res://vrweb_scripts/interaction/main.ts"
const MANIFEST := "res://vrweb_scripts/interaction/vrweb-module.json"
const PACKAGE := "res://vrweb_scripts/interaction/build/module.vrmod"
const METADATA := PACKAGE + ".build.json"

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var adapter := OS.get_environment("VRWEB_JS_ADAPTER")
	_check(not adapter.is_empty() and FileAccess.file_exists(adapter), "adapter path is available")
	ProjectSettings.set_setting("vrweb/maker/javascript_adapter_script", adapter)
	ProjectSettings.set_setting("vrweb/maker/node_executable", OS.get_environment(
			"VRWEB_NODE") if OS.has_environment("VRWEB_NODE") else "node")
	EditorInterface.open_scene_from_path("res://world.tscn")
	await _wait_until(func() -> bool: return EditorInterface.get_edited_scene_root() != null,
			"world scene opened")

	await _wait_until(func() -> bool: return _find_button("Add VRWeb Script") != null,
			"Maker dock exposes Add VRWeb Script")
	var add_button := _find_button("Add VRWeb Script")
	if add_button != null: add_button.pressed.emit()
	await _frames(5)
	_check(FileAccess.file_exists(SOURCE), "Add button creates TypeScript source")
	_check(FileAccess.file_exists(MANIFEST), "Add button creates module manifest")
	var component := _find_source_component(EditorInterface.get_edited_scene_root())
	_check(component != null, "Add button attaches source component to edited scene")
	if component == null:
		_finish()
		return
	_check(component.adapter_script == adapter, "source component captures configured adapter")

	await _wait_until(func() -> bool: return _find_button("Build & Run in Knossos") != null,
			"Maker dock exposes Build & Run")
	var build_button := _find_button("Build & Run in Knossos")
	if build_button == null:
		_finish()
		return
	build_button.pressed.emit()
	await _wait_until(func() -> bool:
		return FileAccess.file_exists(PACKAGE) and FileAccess.file_exists(METADATA) \
				and FileAccess.file_exists("res://dist/world.html"), "initial editor build")
	var first_package := FileAccess.get_file_as_bytes(PACKAGE)
	var first_metadata := _read_json(METADATA)
	_check(not first_package.is_empty(), "initial package is non-empty")
	_check(not str(first_metadata.get("package_sha256", "")).is_empty(),
			"initial build metadata records package hash")
	_close_review()

	var valid_source := FileAccess.get_file_as_string(SOURCE)
	_write(SOURCE, valid_source + "\nthis is not valid TypeScript;\n")
	build_button.pressed.emit()
	await _wait_until(func() -> bool:
		return not build_button.disabled and _status_text().contains("adapter failed"),
			"compile error reported in Maker dock")
	_check(FileAccess.get_file_as_bytes(PACKAGE) == first_package,
			"compile error preserves last successful package byte-for-byte")
	_check(_read_json(METADATA) == first_metadata,
			"compile error preserves last successful metadata")

	_write(SOURCE, valid_source.replace("core.logCode(1);", "core.logCode(2);"))
	build_button.pressed.emit()
	await _wait_until(func() -> bool:
		var metadata := _read_json(METADATA)
		return not build_button.disabled and FileAccess.file_exists("res://dist/world.report.json") \
				and str(metadata.get("package_sha256", "")) != str(
						first_metadata.get("package_sha256", "")), "corrected editor rebuild")
	var second_package := FileAccess.get_file_as_bytes(PACKAGE)
	var second_metadata := _read_json(METADATA)
	_check(second_package != first_package, "source edit produces a new package")
	_check(str(second_metadata.get("fingerprint", "")) != str(first_metadata.get("fingerprint", "")),
			"source edit produces a new build fingerprint")
	_check(not FileAccess.file_exists("res://dist/main.ts"), "creator source is absent from dist")
	_close_review()
	_finish()


func _find_button(text: String) -> Button:
	return _find_button_below(EditorInterface.get_base_control(), text)


func _find_button_below(node: Node, text: String) -> Button:
	if node is Button and node.text == text:
		return node
	for child in node.get_children():
		var found := _find_button_below(child, text)
		if found != null: return found
	return null


func _find_source_component(node: Node) -> VrwebWasmSourceComponent:
	if node is VrwebWasmSourceComponent: return node
	for child in node.get_children():
		var found := _find_source_component(child)
		if found != null: return found
	return null


func _status_text() -> String:
	var base := EditorInterface.get_base_control()
	return _all_label_text(base)


func _all_label_text(node: Node) -> String:
	var result: String = node.text + "\n" if node is Label else ""
	for child in node.get_children(): result += _all_label_text(child)
	return result


func _close_review() -> void:
	for child in EditorInterface.get_base_control().get_children():
		if child is AcceptDialog and child.title == "VRWeb export review":
			child.hide()
			child.canceled.emit()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "can update " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _wait_until(condition: Callable, label: String) -> void:
	for _frame in TIMEOUT_FRAMES:
		if condition.call():
			_pass(label)
			return
		await EditorInterface.get_base_control().get_tree().process_frame
	_fail("timeout: " + label)


func _frames(count: int) -> void:
	for _frame in count:
		await EditorInterface.get_base_control().get_tree().process_frame


func _check(value: bool, label: String) -> void:
	if value: _pass(label)
	else: _fail(label)


func _pass(label: String) -> void:
	print("VRWEB_MAKER_EDITOR PASS: " + label)


func _fail(label: String) -> void:
	_failed = true
	push_error("VRWEB_MAKER_EDITOR FAIL: " + label)


func _finish() -> void:
	print("VRWEB_MAKER_EDITOR %s" % ("FAIL" if _failed else "PASS"))
	if not _failed: _write("res://maker-editor-smoke.pass", "PASS\n")
	EditorInterface.get_base_control().get_tree().quit(1 if _failed else 0)
