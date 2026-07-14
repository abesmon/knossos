@tool
class_name VrwebPublishedVerifier
extends RefCounted

## Pure verification rules shared by the network CLI and tests. MIME differences are deliberately
## warnings: static hosts often serve valid bytes as application/octet-stream.


static func parse_manifest(text: String) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return {"ok": false, "error": "asset manifest is not valid JSON object"}
	if int(parsed.get("version", 0)) != 1:
		return {"ok": false, "error": "unsupported asset manifest version"}
	if not parsed.get("assets", null) is Array:
		return {"ok": false, "error": "asset manifest has no assets array"}
	for entry in parsed.assets:
		if not entry is Dictionary:
			return {"ok": false, "error": "asset manifest entry is not an object"}
		var path_error := validate_relative_path(str(entry.get("file", "")))
		if not path_error.is_empty():
			return {"ok": false, "error": path_error}
		if str(entry.get("sha256", "")).length() != 64:
			return {"ok": false, "error": "asset has invalid SHA-256: " + str(entry.get("file", ""))}
	return {"ok": true, "manifest": parsed}


static func validate_response(entry: Dictionary, status: int, headers: Dictionary,
		body: PackedByteArray) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var file := str(entry.get("file", ""))
	if status < 200 or status >= 300:
		errors.append("%s: HTTP %d" % [file, status])
		return {"ok": false, "errors": errors, "warnings": warnings}
	var expected_size := int(entry.get("size", -1))
	if expected_size >= 0 and body.size() != expected_size:
		errors.append("%s: size %d, expected %d" % [file, body.size(), expected_size])
	var actual_hash := sha256(body)
	var expected_hash := str(entry.get("sha256", "")).to_lower()
	if actual_hash != expected_hash:
		errors.append("%s: SHA-256 mismatch" % file)
	var expected_mime := str(entry.get("mime", "")).to_lower()
	var actual_mime := str(headers.get("content-type", "")).get_slice(";", 0).strip_edges().to_lower()
	if not expected_mime.is_empty() and actual_mime != expected_mime:
		warnings.append("%s: Content-Type %s, expected %s" % [
			file, actual_mime if not actual_mime.is_empty() else "<missing>", expected_mime])
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings,
		"sha256": actual_hash, "size": body.size(), "content_type": actual_mime}


static func validate_relative_path(path: String) -> String:
	if path.is_empty() or path.begins_with("/") or path.contains("\\"):
		return "asset path must be a non-empty relative URL: " + path
	if path.split("/", false).has("..") or path.contains(":"):
		return "asset path escapes published base: " + path
	return ""


static func join_url(base_url: String, relative: String) -> String:
	return base_url.trim_suffix("/") + "/" + relative.trim_prefix("/")


static func sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

