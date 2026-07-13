@tool
extends EditorSceneFormatImporter

## Native adapter; implementation lives in VrwebHtmlSceneCodec so round-trip is testable
## without instantiating the editor-only importer base class.


func _get_extensions() -> PackedStringArray:
	return PackedStringArray(["html", "htm"])


func _import_scene(path: String, _flags: int, _options: Dictionary) -> Object:
	return VrwebHtmlSceneCodec.build_from_path(path)
