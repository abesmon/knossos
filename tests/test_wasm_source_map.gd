extends SceneTree

var _failed := false


func _initialize() -> void:
	var map_path := "user://source-map-test.map"
	var file := FileAccess.open(map_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"version": 3,
		"file": "module.bundle.js",
		"x_vrweb_generated": "module.bundle.js",
		"sourceRoot": "vrweb-source:///",
		"sources": ["light-switch.ts"],
		# generated 1:1 -> original 3:5, generated 1:11 -> original 6:5
		"mappings": "AAEI,UAGA",
	}))
	file.close()
	var mapped := WasmSourceMap.map_message(
			"Error: probe\n    at event (module.bundle.js:1:12)", map_path)
	_eq(mapped.source, "vrweb-source:///light-switch.ts", "source path remains logical")
	_eq(mapped.line, 6, "nearest source-map segment resolves original line")
	_eq(mapped.column, 5, "nearest source-map segment resolves original column")
	var unsafe := FileAccess.open(map_path, FileAccess.WRITE)
	unsafe.store_string(JSON.stringify({"version": 3, "file": "module.bundle.js",
		"sources": ["../host/secret.ts"], "mappings": "AAAA"}))
	unsafe.close()
	_eq(WasmSourceMap.map_message("at x (module.bundle.js:1:1)", map_path), {},
			"unsafe source path is not exposed")
	quit(1 if _failed else 0)


func _eq(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
