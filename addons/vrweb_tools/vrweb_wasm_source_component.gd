@tool
class_name VrwebWasmSourceComponent
extends VrwebWasmComponent

## Authoring-only source binding. It invokes an explicitly configured external language adapter
## with argv (never a shell), then hands the resulting .vrmod to the normal prebuilt package path.

const BUILD_METADATA_SUFFIX := ".build.json"

@export_category("VRWeb source build")
@export_enum("javascript-typescript") var language_adapter := "javascript-typescript"
@export_file("*.ts", "*.js") var source_path := ""
@export_file("*.json") var manifest_path := ""
@export var node_executable := "node"
@export_global_file("*.mjs") var adapter_script := ""

var _build_process: Dictionary = {}
var _build_output := ""


func ensure_package() -> Dictionary:
	if language_adapter != "javascript-typescript":
		return _error("unsupported language adapter: " + language_adapter)
	for required in [source_path, manifest_path, package_path]:
		if str(required).is_empty(): return _error("source, manifest and package paths are required")
		if not FileAccess.file_exists(str(required)) and str(required) != package_path:
			return _error("source build input not found: " + str(required))
	if adapter_script.is_empty() or not FileAccess.file_exists(adapter_script):
		return _error("JavaScript adapter is not installed or configured")
	var fingerprint := _build_fingerprint()
	if fingerprint.is_empty(): return _error("cannot hash source build inputs")
	var metadata_path := package_path + BUILD_METADATA_SUFFIX
	var previous = JSON.parse_string(FileAccess.get_file_as_string(metadata_path)) \
			if FileAccess.file_exists(metadata_path) else null
	if previous is Dictionary and str(previous.get("fingerprint", "")) == fingerprint:
		var cached := inspect_package(package_path, module_id.strip_edges(), export_name.strip_edges())
		if bool(cached.get("ok", false)):
			return {"ok": true, "error": "", "skipped": true, "fingerprint": fingerprint,
				"package": cached}
	var output: Array = []
	var arguments := PackedStringArray([
		adapter_script,
		"--entry", ProjectSettings.globalize_path(source_path),
		"--manifest", ProjectSettings.globalize_path(manifest_path),
		"--output", ProjectSettings.globalize_path(package_path),
	])
	var exit_code := OS.execute(node_executable, arguments, output, true, false)
	if exit_code != 0:
		return _error("adapter failed (%d): %s" % [exit_code, "\n".join(output)])
	var checked := inspect_package(package_path, module_id.strip_edges(), export_name.strip_edges())
	if not bool(checked.get("ok", false)):
		return _error("adapter output is invalid: " + str(checked.get("error", "")))
	var metadata := {"format": 1, "adapter": language_adapter,
		"fingerprint": fingerprint, "package_sha256": str(checked.hash)}
	if not _write_text(metadata_path, JSON.stringify(metadata, "  ") + "\n"):
		return _error("cannot write source build metadata")
	return {"ok": true, "error": "", "skipped": false, "fingerprint": fingerprint,
		"package": checked, "output": output}


func start_package_build() -> Dictionary:
	if not _build_process.is_empty(): return _error("source build is already running")
	var validation := _validate_inputs()
	if not bool(validation.ok): return validation
	var fingerprint := _build_fingerprint()
	if fingerprint.is_empty(): return _error("cannot hash source build inputs")
	var previous = JSON.parse_string(FileAccess.get_file_as_string(
			package_path + BUILD_METADATA_SUFFIX)) \
			if FileAccess.file_exists(package_path + BUILD_METADATA_SUFFIX) else null
	if previous is Dictionary and str(previous.get("fingerprint", "")) == fingerprint:
		var cached := inspect_package(package_path, module_id.strip_edges(), export_name.strip_edges())
		if bool(cached.get("ok", false)):
			return {"ok": true, "running": false, "skipped": true,
				"fingerprint": fingerprint, "package": cached}
	var launched := OS.execute_with_pipe(node_executable, _adapter_arguments(), false)
	if launched.is_empty(): return _error("cannot start JavaScript adapter process")
	_build_process = launched
	_build_process["fingerprint"] = fingerprint
	_build_output = ""
	return {"ok": true, "running": true, "skipped": false,
		"pid": int(launched.pid), "fingerprint": fingerprint}


func poll_package_build() -> Dictionary:
	if _build_process.is_empty(): return _error("source build is not running")
	_drain_build_pipes()
	var pid := int(_build_process.pid)
	if OS.is_process_running(pid):
		return {"ok": true, "running": true, "output": _build_output}
	_drain_build_pipes()
	var exit_code := OS.get_process_exit_code(pid)
	var fingerprint := str(_build_process.fingerprint)
	_build_process.clear()
	if exit_code != 0:
		return _error("adapter failed (%d): %s" % [exit_code, _build_output])
	var checked := inspect_package(package_path, module_id.strip_edges(), export_name.strip_edges())
	if not bool(checked.get("ok", false)):
		return _error("adapter output is invalid: " + str(checked.get("error", "")))
	var metadata := {"format": 1, "adapter": language_adapter,
		"fingerprint": fingerprint, "package_sha256": str(checked.hash)}
	if not _write_text(package_path + BUILD_METADATA_SUFFIX,
			JSON.stringify(metadata, "  ") + "\n"):
		return _error("cannot write source build metadata")
	return {"ok": true, "running": false, "skipped": false,
		"fingerprint": fingerprint, "package": checked, "output": _build_output}


func cancel_package_build() -> Dictionary:
	if _build_process.is_empty(): return _error("source build is not running")
	var pid := int(_build_process.pid)
	var result := OS.kill(pid) if OS.is_process_running(pid) else OK
	_drain_build_pipes()
	_build_process.clear()
	return {"ok": result == OK, "running": false, "canceled": true,
		"error": "" if result == OK else "cannot terminate adapter process"}


func is_package_build_running() -> bool:
	return not _build_process.is_empty()


func _validate_inputs() -> Dictionary:
	if language_adapter != "javascript-typescript":
		return _error("unsupported language adapter: " + language_adapter)
	for required in [source_path, manifest_path, package_path]:
		if str(required).is_empty(): return _error("source, manifest and package paths are required")
		if not FileAccess.file_exists(str(required)) and str(required) != package_path:
			return _error("source build input not found: " + str(required))
	if adapter_script.is_empty() or not FileAccess.file_exists(adapter_script):
		return _error("JavaScript adapter is not installed or configured")
	return {"ok": true, "error": ""}


func _adapter_arguments() -> PackedStringArray:
	return PackedStringArray([
		adapter_script,
		"--entry", ProjectSettings.globalize_path(source_path),
		"--manifest", ProjectSettings.globalize_path(manifest_path),
		"--output", ProjectSettings.globalize_path(package_path),
	])


func _drain_build_pipes() -> void:
	for key in ["stdio", "stderr"]:
		var pipe := _build_process.get(key) as FileAccess
		if pipe == null: continue
		var available := pipe.get_length()
		if available > 0:
			_build_output += pipe.get_buffer(available).get_string_from_utf8()


func _build_fingerprint() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var inputs := [source_path, manifest_path, adapter_script]
	var adapter_lock := adapter_script.get_base_dir().path_join("package-lock.json")
	if FileAccess.file_exists(adapter_lock): inputs.append(adapter_lock)
	for path in inputs:
		if not FileAccess.file_exists(path): return ""
		context.update(str(path).to_utf8_buffer())
		context.update(PackedByteArray([0]))
		context.update(FileAccess.get_file_as_bytes(path))
		context.update(PackedByteArray([0]))
	context.update(language_adapter.to_utf8_buffer())
	context.update(node_executable.to_utf8_buffer())
	return context.finish().hex_encode()


func _write_text(path: String, value: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
			path.get_base_dir())) != OK:
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(value)
	file.close()
	return true
