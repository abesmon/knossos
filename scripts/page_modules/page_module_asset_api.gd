class_name PageModuleAssetAPI
extends RefCounted

## Read-only facade over assets explicitly declared by one module manifest.

const MAX_RAW_READ_BYTES := 8 * 1024 * 1024

var _root: String
var _assets: Dictionary
var _valid := true


func _init(root: String, assets: Dictionary) -> void:
	_root = root
	_assets = assets.duplicate(true)


func has(name: String) -> bool:
	return _valid and _assets.has(name)


func bytes(name: String) -> PackedByteArray:
	var path := _path(name)
	if path.is_empty():
		return PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_RAW_READ_BYTES:
		return PackedByteArray()
	return file.get_buffer(file.get_length())


func text(name: String) -> String:
	return bytes(name).get_string_from_utf8()


func load(name: String) -> Resource:
	var path := _path(name)
	if path.is_empty():
		return null
	var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if resource == null:
		return null
	var expected := str((_assets[name] as Dictionary).get("type", ""))
	if not expected.is_empty() and not resource.is_class(expected):
		return null
	return resource


func invalidate() -> void:
	_valid = false
	_root = ""
	_assets.clear()


func _path(name: String) -> String:
	if not _valid or _root.is_empty() or not _assets.has(name):
		return ""
	var relative := str((_assets[name] as Dictionary).get("path", ""))
	if not PageModuleManifest.valid_module_path(relative):
		return ""
	return _root.path_join(relative)
