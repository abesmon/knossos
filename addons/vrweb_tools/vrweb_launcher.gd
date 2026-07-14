@tool
class_name VrwebLauncher
extends RefCounted

## Optional production-runtime launcher. It only knows how to pass a built local HTML URL to
## an executable or registered OS handler; it does not import any Knossos runtime code.

const LOCAL_SCHEME := "vrweblocal://"
const MODE_EXECUTABLE := "executable"
const MODE_DEEPLINK := "deeplink"
const MODES := [MODE_EXECUTABLE, MODE_DEEPLINK]


static func local_url(output_path: String, platform: String = "") -> String:
	var path := output_path
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	path = path.replace("\\", "/")
	var target_platform := OS.get_name() if platform.is_empty() else platform
	if target_platform == "Windows" and path.length() >= 2 and path[1] == ":":
		path = "/" + path
	elif not path.begins_with("/"):
		path = "/" + path
	return LOCAL_SCHEME + path


static func launch_plan(url: String, executable_path: String, mode: String,
		platform: String = "") -> Dictionary:
	if not url.begins_with(LOCAL_SCHEME):
		return {"ok": false, "error": "launch URL must use vrweblocal://"}
	var safe_mode := mode if mode in MODES else MODE_EXECUTABLE
	if safe_mode == MODE_DEEPLINK:
		return {"ok": true, "action": "shell_open", "command": "", "args": [], "url": url}
	var executable := executable_path.strip_edges()
	if executable.is_empty():
		return {"ok": false, "error": "Knossos executable не настроен"}
	var target_platform := OS.get_name() if platform.is_empty() else platform
	if target_platform == "macOS" and executable.to_lower().ends_with(".app"):
		return {"ok": true, "action": "process", "command": "/usr/bin/open",
			"args": ["-n", executable, "--args", url], "url": url}
	return {"ok": true, "action": "process", "command": executable, "args": [url], "url": url}


static func launch(output_path: String, executable_path: String, mode: String) -> Dictionary:
	var url := local_url(output_path)
	var plan := launch_plan(url, executable_path, mode)
	if not bool(plan.get("ok", false)):
		return plan
	if str(plan.action) == "shell_open":
		var open_error := OS.shell_open(url)
		if open_error != OK:
			return {"ok": false, "error": "OS handler не открыл %s (code %d)" % [url, open_error],
				"url": url}
		return {"ok": true, "url": url, "pid": -1, "mode": MODE_DEEPLINK}
	var command := str(plan.command)
	if command != "/usr/bin/open" and not FileAccess.file_exists(command):
		return {"ok": false, "error": "Knossos executable не найден: " + command, "url": url}
	if command == "/usr/bin/open":
		var app_path := str((plan.args as Array)[1])
		if not DirAccess.dir_exists_absolute(app_path):
			return {"ok": false, "error": "Knossos app не найден: " + app_path, "url": url}
	var args := PackedStringArray(plan.args)
	var pid := OS.create_process(command, args)
	if pid < 0:
		return {"ok": false, "error": "Не удалось запустить Knossos: " + command, "url": url}
	return {"ok": true, "url": url, "pid": pid, "mode": MODE_EXECUTABLE}

