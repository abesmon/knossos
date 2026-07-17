extends SceneTree

var _failed := false
var _bytes := "wasm component bytes".to_utf8_buffer()


func _initialize() -> void:
	_test_same_origin()
	_test_cross_origin()
	quit(1 if _failed else 0)


func _test_same_origin() -> void:
	var module := {"kind": "package", "integrity": ""}
	var result := ScriptingModuleIntegrity.verify(module, "https://example.test/page",
			"https://example.test/code.gd", _bytes)
	_eq(result.allowed, true, "same-origin integrity is optional")
	_eq(result.warnings, [], "first same-origin load has no warning")
	result = ScriptingModuleIntegrity.verify(module, "https://example.test/page",
			"https://example.test/code.gd", _bytes, "00".repeat(32))
	_eq(result.allowed, true, "changed same-origin module is not hard denied")
	_eq(result.warnings.size(), 1, "changed same-origin module warns")
	module.integrity = "sha256-wrong"
	result = ScriptingModuleIntegrity.verify(module, "https://example.test/page",
			"https://example.test/code.gd", _bytes)
	_eq(result.allowed, true, "same-origin declared mismatch is warning")
	_eq(result.code, "ok_with_warning", "same-origin mismatch marked for preflight")


func _test_cross_origin() -> void:
	var module := {"kind": "package", "integrity": ""}
	var result := ScriptingModuleIntegrity.verify(module, "https://example.test/page",
			"https://cdn.test/code.vrmod", _bytes)
	_eq(result.allowed, false, "cross-origin integrity is required")
	_eq(result.code, "cross_origin_integrity_required", "missing integrity code")
	module.integrity = "sha256-wrong"
	result = ScriptingModuleIntegrity.verify(module, "https://example.test/page",
			"https://cdn.test/code.vrmod", _bytes)
	_eq(result.allowed, false, "cross-origin mismatch is hard denied")
	module.integrity = ScriptingModuleIntegrity.sri_sha256(_bytes)
	result = ScriptingModuleIntegrity.verify(module, "https://example.test/page",
			"https://cdn.test/code.vrmod", _bytes)
	_eq(result.allowed, true, "cross-origin exact integrity passes")

func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
