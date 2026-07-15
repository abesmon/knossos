extends SceneTree

## Lossless HTML envelope regression. Run:
##   godot --headless --path . --script res://tests/test_html_scene_document.gd

var _failed := false


func _initialize() -> void:
	var prefix := "<!doctype html>\r\n<script>const fake = '<vrwml>x</vrwml>';</script>\r\n<body>до\r\n"
	var original_block := "<VRWML mode='combine'>\r\n  <Node3D name=\"Old\"/>\r\n</VRWML>"
	var suffix := "\r\nпосле<!-- <vrwml>fake</vrwml> --></body>\r\n"
	var source := prefix + original_block + suffix
	var span := VrwebHtmlDocument.locate(source)
	_check(bool(span.get("ok", false)), "находит реальный блок, пропуская script/comment")
	_check(str(span.get("block", "")) == original_block, "возвращает исходный блок без нормализации")
	var replacement := "<vrwml mode=\"combine\">\n  <Node3D name=\"New\"/>\n</vrwml>"
	var changed := VrwebHtmlDocument.replace_block(source, replacement)
	_check(str(changed.get("html", "")) == prefix + replacement + suffix,
		"prefix/suffix сохраняются побайтно на уровне строки")
	_check(not bool(VrwebHtmlDocument.locate("<html></html>").get("ok", false)),
		"документ без VRWML отклоняется")
	quit(1 if _failed else 0)


func _check(ok: bool, label: String) -> void:
	print(("[ok] " if ok else "[FAIL] ") + label)
	_failed = _failed or not ok
