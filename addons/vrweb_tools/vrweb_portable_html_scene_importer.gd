@tool
extends EditorSceneFormatImporter


func _get_extensions() -> PackedStringArray:
	return PackedStringArray(["html", "htm"])


func _import_scene(path: String, _flags: int, _options: Dictionary) -> Object:
	return VrwebPortableHtmlSceneCodec.build_from_path(path)

