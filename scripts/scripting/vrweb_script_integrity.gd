class_name VrwebScriptIntegrity
extends RefCounted

## Web-like opt-in Subresource Integrity. Origin does not make SRI mandatory.


static func verify(declaration: Dictionary, bytes: PackedByteArray) -> Dictionary:
	var digest := _sha256(bytes)
	var actual_hex := digest.hex_encode()
	var actual_sri := "sha256-" + Marshalls.raw_to_base64(digest)
	var expected := str(declaration.get("integrity", "")).strip_edges()
	if expected.is_empty():
		return {"ok": true, "code": "not_requested", "hash": actual_hex, "sri": actual_sri}
	var supported := false
	for token in expected.split(" ", false):
		if not token.begins_with("sha256-"):
			continue
		supported = true
		if token == actual_sri:
			return {"ok": true, "code": "verified", "hash": actual_hex, "sri": actual_sri}
	return {"ok": false, "code": "integrity_mismatch" if supported \
			else "unsupported_integrity", "hash": actual_hex, "sri": actual_sri}


static func sri_sha256(bytes: PackedByteArray) -> String:
	return "sha256-" + Marshalls.raw_to_base64(_sha256(bytes))


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return PackedByteArray()
	context.update(bytes)
	return context.finish()
