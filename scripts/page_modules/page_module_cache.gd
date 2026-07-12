class_name PageModuleCache
extends RefCounted

## Immutable content-addressed bytes. URL metadata/trust decisions сюда не входят.

const ROOT := "user://page_module_cache/objects/"
const MAX_ARTIFACT_BYTES := 32 * 1024 * 1024


static func store(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > MAX_ARTIFACT_BYTES:
		return {"ok": false, "hash": "", "path": "", "error": "invalid_size"}
	var hash := _hash(bytes)
	var path := path_for(hash)
	var absolute := Sandbox.resolve(path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if FileAccess.file_exists(absolute):
		var existing := FileAccess.get_file_as_bytes(absolute)
		if _hash(existing) == hash:
			return {"ok": true, "hash": hash, "path": path, "error": ""}
	var temp := absolute + ".part"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "hash": hash, "path": "", "error": "write_failed"}
	file.store_buffer(bytes)
	file.close()
	if DirAccess.rename_absolute(temp, absolute) != OK:
		DirAccess.remove_absolute(temp)
		return {"ok": false, "hash": hash, "path": "", "error": "rename_failed"}
	return {"ok": true, "hash": hash, "path": path, "error": ""}


static func read(hash: String) -> PackedByteArray:
	if not valid_hash(hash):
		return PackedByteArray()
	var absolute := Sandbox.resolve(path_for(hash))
	if not FileAccess.file_exists(absolute):
		return PackedByteArray()
	var bytes := FileAccess.get_file_as_bytes(absolute)
	return bytes if _hash(bytes) == hash else PackedByteArray()


static func has(hash: String) -> bool:
	return not read(hash).is_empty()


static func path_for(hash: String) -> String:
	return ROOT.path_join(hash.left(2)).path_join(hash)


static func valid_hash(hash: String) -> bool:
	if hash.length() != 64:
		return false
	for c in hash:
		if not (c >= "0" and c <= "9") and not (c >= "a" and c <= "f"):
			return false
	return true


static func _hash(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()
