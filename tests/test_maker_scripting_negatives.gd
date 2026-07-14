extends Node

var _failed := false


func _ready() -> void:
	var dependency := VrwebPackageExporter._collect_scripts(
			"res://tests/fixtures/scripting_negative/missing_dependency.gd")
	_check(not bool(dependency.get("ok", true)) \
			and str(dependency.get("error", "")).contains("missing_helper.gd"),
			"package reports missing relative dependency")

	var source := FileAccess.get_file_as_string(
			"res://tests/fixtures/scripting_negative/compile_error.gd.txt")
	var compile := ScriptingModuleRegistry.new().prepare([{
		"id": "negative.compile", "kind": "inline", "runtime": "trusted-gdscript",
		"hash": source.sha256_text(), "source": source,
		"exports": {"default": {"base": "Node3D"}},
	}], ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
	_check(not bool(compile.ok) and str(compile.errors).contains("не скомпилирован"),
			"runtime reports compile error")

	var bytes := "fixture".to_utf8_buffer()
	var integrity := ScriptingModuleIntegrity.verify({
		"kind": "package", "integrity": "sha256-wrong",
	}, "https://page.test/world.html", "https://cdn.test/world.vrmod", bytes)
	_check(not bool(integrity.allowed) and integrity.code == "integrity_mismatch",
			"cross-origin wrong integrity is rejected")

	var capability := ScriptingModuleRegistry.new().prepare([{
		"id": "negative.capability", "kind": "package", "runtime": "trusted-gdscript",
		"hash": "00".repeat(32), "module_root": "user://negative-capability",
		"exports": {"default": {"script": "main.gd", "base": "Node3D"}},
		"manifest": {"requires": ["vrweb/future/99"]},
	}], ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
	_check(not bool(capability.ok) and str(capability.errors).contains("vrweb/future/99"),
			"unknown required capability is rejected")

	print("=== ", "ALL PASSED" if not _failed else "FAILURES ABOVE", " ===")
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, label: String) -> void:
	print("  [ok]  " if condition else "  [FAIL] ", label)
	_failed = _failed or not condition
