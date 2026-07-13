@tool
class_name VrwebHtmlSceneSaver
extends RefCounted

## Explicit writer used only by the editor plugin on a live edited scene. It is deliberately
## not a ResourceFormatSaver: Godot calls format savers while creating import cache, which
## would make an import overwrite its own HTML source.


static func save_root(root: Node, output_path: String = "") -> Dictionary:
	if root == null or not bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)):
		return {"ok": false, "code": ERR_INVALID_PARAMETER, "error": "сцена не импортирована из HTML"}
	var source_path := str(root.get_meta(VrwebHtmlDocument.META_SOURCE_PATH, ""))
	if source_path.is_empty():
		return {"ok": false, "code": ERR_FILE_NOT_FOUND, "error": "не записан source path HTML"}
	if output_path.is_empty():
		output_path = source_path
	var source := FileAccess.get_file_as_string(source_path)
	if source.is_empty() and not FileAccess.file_exists(source_path):
		return {"ok": false, "code": ERR_FILE_CANT_READ, "error": "не удалось прочитать %s" % source_path}
	var span := VrwebHtmlDocument.locate(source)
	if not bool(span.ok):
		return {"ok": false, "code": ERR_PARSE_ERROR, "error": str(span.error)}

	# Не затираем параллельную ручную правку исходного <vrweb> после импорта.
	var imported_hash := str(root.get_meta(VrwebHtmlDocument.META_BLOCK_HASH, ""))
	var current_hash := str(span.block).sha256_text()
	if not imported_hash.is_empty() and imported_hash != current_hash:
		return {"ok": false, "code": ERR_ALREADY_IN_USE,
			"error": "<vrweb> в %s изменился на диске; переимпортируйте сцену" % source_path}

	var mode := str(root.get_meta(VrwebHtmlDocument.META_MODE, VrwebBuilder.MODE_COMBINE))
	var report := VrwebExporter.export_vrweb_block_report(root, mode, output_path)
	if not bool(report.ok):
		return {"ok": false, "code": ERR_CANT_CREATE, "error": "; ".join(report.errors)}
	var replaced := VrwebHtmlDocument.replace_block(source, str(report.vrweb))
	if not bool(replaced.ok):
		return {"ok": false, "code": ERR_PARSE_ERROR, "error": str(replaced.error)}
	var output := str(replaced.html)
	if output != source or output_path != source_path:
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file == null:
			return {"ok": false, "code": FileAccess.get_open_error(),
				"error": "не удалось записать %s" % output_path}
		file.store_string(output)
		file.close()
	root.set_meta(VrwebHtmlDocument.META_SOURCE_PATH, output_path)
	root.set_meta(VrwebHtmlDocument.META_BLOCK_HASH, str(report.vrweb).sha256_text())
	return {"ok": true, "code": OK, "error": "", "html": output}
