extends Node


func _ready() -> void:
	var bytes := "hello".to_utf8_buffer()
	var entry := {"file": "assets/world/hello.txt", "size": bytes.size(),
		"sha256": VrwebPublishedVerifier.sha256(bytes), "mime": "text/plain"}
	var manifest := JSON.stringify({"version": 1, "assets": [entry]})
	var parsed := VrwebPublishedVerifier.parse_manifest(manifest)
	var ok: bool = bool(parsed.get("ok", false))
	var mime_warning := VrwebPublishedVerifier.validate_response(entry, 200,
			{"content-type": "application/octet-stream"}, bytes)
	ok = ok and bool(mime_warning.ok) and mime_warning.errors.is_empty() \
			and mime_warning.warnings.size() == 1
	var exact := VrwebPublishedVerifier.validate_response(entry, 200,
			{"content-type": "text/plain; charset=utf-8"}, bytes)
	ok = ok and bool(exact.ok) and exact.warnings.is_empty()
	var corrupt := VrwebPublishedVerifier.validate_response(entry, 200,
			{"content-type": "text/plain"}, "changed".to_utf8_buffer())
	ok = ok and not bool(corrupt.ok) and not corrupt.errors.is_empty()
	var missing := VrwebPublishedVerifier.validate_response(entry, 404, {}, PackedByteArray())
	ok = ok and not bool(missing.ok) and str(missing.errors).contains("HTTP 404")
	ok = ok and not VrwebPublishedVerifier.validate_relative_path("../secret").is_empty() \
			and VrwebPublishedVerifier.validate_relative_path("assets/world/hello.txt").is_empty()
	print("CLEAN PUBLISHED VERIFIER ", "PASSED" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)

