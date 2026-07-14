extends SceneTree

## Headless Maker Kit entry point.
## godot --headless --path PROJECT --script res://addons/vrweb_tools/vrweb_cli.gd -- \
##   --scene=res://world.tscn --output=res://dist/world.html --report=res://dist/report.json


func _initialize() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var scene_path := str(options.get("scene", ""))
	var output_path := str(options.get("output", ""))
	var report_path := str(options.get("report", ""))
	var mode := VrwebFormat.normalized_mode(str(options.get("mode", VrwebFormat.MODE_EXCLUSIVE)))
	var profile := VrwebCompatibility.normalized_profile(str(options.get(
		"profile", VrwebCompatibility.PROFILE_STRICT)))
	if scene_path.is_empty() or output_path.is_empty():
		_finish_with_usage("--scene and --output are required", report_path)
		return
	if output_path.get_extension().to_lower() not in ["html", "vrwml"]:
		_finish_with_usage("--output must end with .html or .vrwml", report_path)
		return

	var packed := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE) \
			as PackedScene
	if packed == null:
		_finish_with_usage("cannot load scene: " + scene_path, report_path)
		return
	var root := packed.instantiate()
	var report: Dictionary
	if output_path.get_extension().to_lower() == "vrwml":
		report = VrwebExporter.export_vrwml_report(root, output_path, profile)
	else:
		report = VrwebExporter.export_scene_report(root, mode, output_path, profile)
	root.free()
	report["scene"] = scene_path
	report["output"] = output_path
	if bool(report.get("ok", false)):
		var payload_key := "vrwml" if output_path.ends_with(".vrwml") else "html"
		if not _write_text(output_path, str(report.get(payload_key, ""))):
			report.ok = false
			report.errors.append("cannot write output: " + output_path)
		else:
			report["output_file"] = {"file": output_path,
				"sha256": _sha256_text(str(report.get(payload_key, "")))}
	_write_report(report_path, report)
	_print_report(report)
	quit(0 if bool(report.get("ok", false)) else 1)


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {}
	for argument in arguments:
		if not argument.begins_with("--") or not argument.contains("="):
			continue
		var separator := argument.find("=")
		result[argument.substr(2, separator - 2)] = argument.substr(separator + 1)
	return result


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


func _sha256_text(content: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(content.to_utf8_buffer())
	return context.finish().hex_encode()


func _write_report(path: String, report: Dictionary) -> void:
	if path.is_empty():
		return
	var summary := report.duplicate(true)
	summary.erase("html")
	summary.erase("vrwml")
	if not _write_text(path, JSON.stringify(summary, "  ") + "\n"):
		push_error("VRWeb Maker: cannot write report: " + path)


func _print_report(report: Dictionary) -> void:
	print("VRWeb Maker: %s; profile=%s; warnings=%d; errors=%d; output=%s" % [
		"OK" if bool(report.get("ok", false)) else "FAILED",
		report.get("profile", ""), report.get("warnings", []).size(),
		report.get("errors", []).size(), report.get("output", "")])
	for message in report.get("warnings", []):
		print("warning: ", message)
	for message in report.get("errors", []):
		print("error: ", message)


func _finish_with_usage(message: String, report_path: String) -> void:
	var report := {"ok": false, "profile": VrwebCompatibility.PROFILE_STRICT,
		"catalog_version": VrwebCompatibility.CATALOG_VERSION, "packages": [], "warnings": [],
		"errors": [message]}
	_write_report(report_path, report)
	_print_report(report)
	print("Usage: --scene=res://world.tscn --output=res://dist/world.html " +
		"[--profile=strict|compatible] [--mode=exclusive|combine] [--report=res://report.json]")
	quit(2)
