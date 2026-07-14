extends SceneTree

## godot --headless --script res://addons/vrweb_tools/vrweb_verify_published.gd -- \
##   --base-url=https://example.com/world --page=world.html --manifest=world.assets.json \
##   --report=res://dist/published-report.json


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var options := _parse_options(OS.get_cmdline_user_args())
	var base_url := str(options.get("base-url", "")).trim_suffix("/")
	var page := str(options.get("page", "world.html"))
	var manifest_name := str(options.get("manifest", page.get_basename() + ".assets.json"))
	var report_path := str(options.get("report", ""))
	var report := {"ok": true, "base_url": base_url, "page": page,
		"manifest": manifest_name, "assets": [], "warnings": [], "errors": []}
	if not base_url.begins_with("http://") and not base_url.begins_with("https://"):
		report.ok = false
		report.errors.append("--base-url must use http:// or https://")
		_finish(report, report_path, 2)
		return
	for relative in [page, manifest_name]:
		var path_error := VrwebPublishedVerifier.validate_relative_path(relative)
		if not path_error.is_empty():
			report.ok = false
			report.errors.append(path_error)
	if not bool(report.ok):
		_finish(report, report_path, 2)
		return

	var page_response: Dictionary = await _fetch(VrwebPublishedVerifier.join_url(base_url, page))
	if not _response_ok(page_response):
		report.ok = false
		report.errors.append("page %s: %s" % [page, _response_error(page_response)])
		_finish(report, report_path, 1)
		return
	var manifest_response: Dictionary = await _fetch(
			VrwebPublishedVerifier.join_url(base_url, manifest_name))
	if not _response_ok(manifest_response):
		report.ok = false
		report.errors.append("manifest %s: %s" % [manifest_name, _response_error(manifest_response)])
		_finish(report, report_path, 1)
		return
	var parsed := VrwebPublishedVerifier.parse_manifest(
			(manifest_response.body as PackedByteArray).get_string_from_utf8())
	if not bool(parsed.get("ok", false)):
		report.ok = false
		report.errors.append(str(parsed.get("error", "invalid manifest")))
		_finish(report, report_path, 1)
		return
	for entry in parsed.manifest.assets:
		var response: Dictionary = await _fetch(VrwebPublishedVerifier.join_url(
				base_url, str(entry.file)))
		if int(response.get("result", -1)) != HTTPRequest.RESULT_SUCCESS:
			report.ok = false
			report.errors.append("%s: network result %d" % [entry.file, response.get("result", -1)])
			continue
		var checked := VrwebPublishedVerifier.validate_response(entry, int(response.code),
				response.headers, response.body)
		report.assets.append({"file": entry.file, "ok": checked.ok,
			"sha256": checked.get("sha256", ""), "size": checked.get("size", 0),
			"content_type": checked.get("content_type", "")})
		report.warnings.append_array(checked.warnings)
		report.errors.append_array(checked.errors)
	if not report.errors.is_empty():
		report.ok = false
	_finish(report, report_path, 0 if bool(report.ok) else 1)


func _fetch(url: String) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 30.0
	get_root().add_child(request)
	var start_error := request.request(url)
	if start_error != OK:
		request.queue_free()
		return {"result": -1, "code": 0, "headers": {}, "body": PackedByteArray(),
			"error": "request start code %d" % start_error}
	var response: Array = await request.request_completed
	request.queue_free()
	return {"result": int(response[0]), "code": int(response[1]),
		"headers": _headers(PackedStringArray(response[2])), "body": response[3]}


func _headers(lines: PackedStringArray) -> Dictionary:
	var result := {}
	for line in lines:
		var separator := line.find(":")
		if separator > 0:
			result[line.substr(0, separator).strip_edges().to_lower()] = \
					line.substr(separator + 1).strip_edges()
	return result


func _response_ok(response: Dictionary) -> bool:
	return int(response.get("result", -1)) == HTTPRequest.RESULT_SUCCESS \
			and int(response.get("code", 0)) >= 200 and int(response.get("code", 0)) < 300


func _response_error(response: Dictionary) -> String:
	if response.has("error"):
		return str(response.error)
	return "network result %d, HTTP %d" % [response.get("result", -1), response.get("code", 0)]


func _parse_options(arguments: PackedStringArray) -> Dictionary:
	var result := {}
	for argument in arguments:
		if argument.begins_with("--") and argument.contains("="):
			var separator := argument.find("=")
			result[argument.substr(2, separator - 2)] = argument.substr(separator + 1)
	return result


func _finish(report: Dictionary, path: String, exit_code: int) -> void:
	if not path.is_empty():
		var absolute_dir := ProjectSettings.globalize_path(path.get_base_dir())
		DirAccess.make_dir_recursive_absolute(absolute_dir)
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  ") + "\n")
			file.close()
	print("VRWeb published verify: %s; warnings=%d; errors=%d" % [
		"OK" if bool(report.ok) else "FAILED", report.warnings.size(), report.errors.size()])
	for message in report.warnings:
		print("warning: ", message)
	for message in report.errors:
		print("error: ", message)
	quit(exit_code)

