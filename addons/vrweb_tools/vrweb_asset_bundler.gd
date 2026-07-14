@tool
class_name VrwebAssetBundler
extends RefCounted

const ASSET_DIR := "assets"
const MIME_TYPES := {
	"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
	"svg": "image/svg+xml", "mp3": "audio/mpeg", "ogg": "audio/ogg", "wav": "audio/wav",
	"glb": "model/gltf-binary", "gltf": "model/gltf+json", "bin": "application/octet-stream",
}


static func asset_dir(output_path: String) -> String:
	return ASSET_DIR.path_join(_safe_stem(output_path.get_file().get_basename()))


static func bundle(asset: VrwebLocalAsset, output_path: String) -> Dictionary:
	var source := asset.source_path.strip_edges()
	if not source.begins_with("res://"):
		return {"ok": false, "error": "local asset должен использовать res:// path: " + source}
	if output_path.is_empty():
		return {"ok": false, "error": "local asset требует output path: " + source}
	var loaded := _read(source)
	if not bool(loaded.ok):
		return loaded
	var bytes: PackedByteArray = loaded.bytes
	var dependencies: Array[Dictionary] = []
	if source.get_extension().to_lower() == "gltf":
		var rewritten := _rewrite_gltf(bytes, source, output_path, dependencies)
		if not bool(rewritten.ok):
			return rewritten
		bytes = rewritten.bytes
	var written := _write_asset(bytes, source, output_path)
	if not bool(written.ok):
		return written
	return {"ok": true, "url": written.entry.file, "entry": written.entry,
		"dependencies": dependencies}


static func _rewrite_gltf(bytes: PackedByteArray, source: String, output_path: String,
		dependencies: Array[Dictionary]) -> Dictionary:
	var document = JSON.parse_string(bytes.get_string_from_utf8())
	if not document is Dictionary:
		return {"ok": false, "error": "invalid glTF JSON: " + source}
	for collection_name in ["buffers", "images"]:
		var collection = document.get(collection_name, [])
		if not collection is Array:
			continue
		for index in collection.size():
			var item = collection[index]
			if not item is Dictionary or not item.has("uri"):
				continue
			var uri := str(item.uri)
			if uri.begins_with("data:"):
				continue
			if uri.begins_with("http://") or uri.begins_with("https://"):
				return {"ok": false, "error": "local glTF содержит remote dependency: " + uri}
			if uri.contains("?") or uri.contains("#"):
				return {"ok": false, "error": "glTF dependency query/fragment не поддержан: " + uri}
			var dependency_source := source.get_base_dir().path_join(uri).simplify_path()
			if not dependency_source.begins_with("res://"):
				return {"ok": false, "error": "glTF dependency выходит за project: " + uri}
			var loaded := _read(dependency_source)
			if not bool(loaded.ok):
				return loaded
			var written := _write_asset(loaded.bytes, dependency_source, output_path)
			if not bool(written.ok):
				return written
			dependencies.append(written.entry)
			item.uri = str(written.entry.file).get_file()
			collection[index] = item
		document[collection_name] = collection
	return {"ok": true, "bytes": JSON.stringify(document).to_utf8_buffer()}


static func _read(source: String) -> Dictionary:
	if source.begins_with("res://") and not _has_exact_case(source):
		return {"ok": false,
			"error": "local asset path отсутствует или отличается регистром: " + source}
	var file := FileAccess.open(source, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "local asset не найден: " + source}
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return {"ok": true, "bytes": bytes}


static func _write_asset(bytes: PackedByteArray, source: String, output_path: String) -> Dictionary:
	var hash := _sha256(bytes)
	var extension := source.get_extension().to_lower()
	if not MIME_TYPES.has(extension):
		return {"ok": false, "error": "неподдерживаемый web asset format: " + source}
	var stem := _safe_stem(source.get_file().get_basename())
	var filename := "%s.%s.%s" % [stem, hash.substr(0, 12), extension]
	var relative_dir := asset_dir(output_path)
	var relative := relative_dir.path_join(filename)
	var absolute_dir := ProjectSettings.globalize_path(output_path.get_base_dir().path_join(relative_dir))
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		return {"ok": false, "error": "не удалось создать asset dir: " + absolute_dir}
	var target := output_path.get_base_dir().path_join(relative)
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "не удалось записать asset: " + target}
	file.store_buffer(bytes)
	file.close()
	return {"ok": true, "entry": {"file": relative, "source": source, "sha256": hash,
		"size": bytes.size(), "mime": MIME_TYPES[extension]}}


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


static func _safe_stem(value: String) -> String:
	var result := ""
	for character in value.to_lower():
		result += character if character in "abcdefghijklmnopqrstuvwxyz0123456789_-" else "_"
	return result if not result.is_empty() else "asset"


static func _has_exact_case(source: String) -> bool:
	var parts := source.trim_prefix("res://").split("/", false)
	var directory := "res://"
	for index in parts.size():
		var dir := DirAccess.open(directory)
		if dir == null:
			return false
		var expected := str(parts[index])
		var entries := dir.get_files() if index == parts.size() - 1 else dir.get_directories()
		if not expected in entries:
			return false
		directory = directory.path_join(expected)
	return true
