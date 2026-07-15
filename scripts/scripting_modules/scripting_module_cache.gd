class_name ScriptingModuleCache
extends RefCounted

## Immutable content-addressed bytes. URL metadata/trust decisions сюда не входят.

const ROOT := "user://scripting_module_cache/objects/"
const MAX_ARTIFACT_BYTES := 32 * 1024 * 1024


static func store(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > MAX_ARTIFACT_BYTES:
		return {"ok": false, "hash": "", "path": "", "error": "invalid_size"}
	var content_hash := _sha256_hex(bytes)
	var path := path_for(content_hash)
	var absolute := Sandbox.resolve(path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if FileAccess.file_exists(absolute):
		var existing := FileAccess.get_file_as_bytes(absolute)
		if _sha256_hex(existing) == content_hash:
			return {"ok": true, "hash": content_hash, "path": path, "error": ""}
	var temp := absolute + ".part"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "hash": content_hash, "path": "", "error": "write_failed"}
	file.store_buffer(bytes)
	file.close()
	if DirAccess.rename_absolute(temp, absolute) != OK:
		DirAccess.remove_absolute(temp)
		return {"ok": false, "hash": content_hash, "path": "", "error": "rename_failed"}
	return {"ok": true, "hash": content_hash, "path": path, "error": ""}


static func read(content_hash: String) -> PackedByteArray:
	if not valid_hash(content_hash):
		return PackedByteArray()
	var absolute := Sandbox.resolve(path_for(content_hash))
	if not FileAccess.file_exists(absolute):
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(absolute)
	return bytes if _sha256_hex(bytes) == content_hash else PackedByteArray()


static func has(content_hash: String) -> bool:
	return not read(content_hash).is_empty()


static func path_for(content_hash: String) -> String:
	return ROOT.path_join(content_hash.left(2)).path_join(content_hash)


static func valid_hash(content_hash: String) -> bool:
	if content_hash.length() != 64:
		return false
	for c in content_hash:
		if not (c >= "0" and c <= "9") and not (c >= "a" and c <= "f"):
			return false
	return true


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()
