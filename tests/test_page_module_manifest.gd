extends SceneTree

var _failed := false


func _initialize() -> void:
	var good := JSON.stringify({
		"format": 1, "id": "acme.lights", "version": "1.2.0", "knossos_api": "1",
		"runtime": "trusted-gdscript",
		"exports": {"LightSwitch": {"script": "scripts/light_switch.gd", "base": "Node3D"}},
		"assets": {"click": {"path": "sounds/click.ogg", "type": "AudioStream"}},
		"permissions": ["network:origin"],
	}).to_utf8_buffer()
	var result := PageModuleManifest.parse(good, "acme.lights")
	_eq(result.ok, true, "valid manifest accepted")
	_eq(result.manifest.exports.LightSwitch.script, "scripts/light_switch.gd", "export normalized")
	_eq(result.manifest.assets.click.path, "sounds/click.ogg", "asset normalized")

	var bad := JSON.stringify({
		"format": 2, "id": "other", "runtime": "native",
		"exports": {"Bad": {"script": "../escape.gd"}},
		"assets": {"escape": {"path": "../secret.txt"}},
	}).to_utf8_buffer()
	result = PageModuleManifest.parse(bad, "declared")
	_eq(result.ok, false, "invalid manifest rejected")
	_eq(result.errors.size() >= 5, true, "format/id/runtime/export/asset errors accumulated")
	_eq(PageModuleManifest.valid_module_path("scenes/main.tscn"), true, "module-local path accepted")
	_eq(PageModuleManifest.valid_module_path("res://client.gd"), false, "res path rejected")
	_eq(PageModuleManifest.valid_module_path("a/../client.gd"), false, "traversal rejected")
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
