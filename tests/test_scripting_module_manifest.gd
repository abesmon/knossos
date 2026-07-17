extends SceneTree

var _failed := false


func _initialize() -> void:
	var good := JSON.stringify({
		"format": 1, "id": "acme.lights", "version": "1.2.0",
		"runtime": "wasm-component", "world": "vrweb:module@1", "sdk": "1.0.0",
		"component": "module.wasm",
		"exports": {"LightSwitch": {"kind": "scene-component"}},
		"assets": {"click": {"path": "sounds/click.ogg", "type": "AudioStream"}},
		"requires": ["vrweb/core/1", "vrweb/scene/1"],
		"optional": ["vrweb/state/1"],
		"limits": {"fuel": 250000, "memory_bytes": 8388608,
			"deadline_ms": 20, "host_calls": 16},
		"debug": {"source_map": "debug/module.wasm.map"},
	}).to_utf8_buffer()
	var result := ScriptingModuleManifest.parse(good, "acme.lights")
	_eq(result.ok, true, "valid WASM manifest accepted")
	_eq(result.manifest.component, "module.wasm", "component normalized")
	_eq(result.manifest.sdk, "1.0.0", "SDK version preserved")
	_eq(result.manifest.exports.LightSwitch.kind, "scene-component", "export normalized")
	_eq(result.manifest.assets.click.path, "sounds/click.ogg", "asset normalized")
	_eq(result.manifest.requires, ["vrweb/core/1", "vrweb/scene/1"], "required capabilities normalized")
	_eq(result.manifest.optional, ["vrweb/state/1"], "optional capabilities normalized")
	_eq(result.manifest.limits.fuel, 250000, "fuel hint normalized")
	_eq(result.manifest.limits.memory_bytes, 8388608, "memory hint normalized")
	_eq(result.manifest.limits.instances, 16, "missing limit uses safe default")
	_eq(result.manifest.debug.source_map, "debug/module.wasm.map",
			"optional debug sidecar path normalized")

	var bad := JSON.stringify({
		"format": 2, "id": "other", "runtime": "unsupported-runtime", "world": "unsupported",
		"component": "../escape.wasm", "knossos_api": "1", "permissions": [],
		"exports": {"Bad": {"script": "../escape.gd"}},
		"assets": {"escape": {"path": "../secret.txt"}},
	}).to_utf8_buffer()
	result = ScriptingModuleManifest.parse(bad, "declared")
	_eq(result.ok, false, "unsupported and invalid manifest rejected")
	_eq(result.errors.size() >= 8, true,
			"format/id/runtime/world/component/export/asset/unknown-field errors accumulated")
	_eq(ScriptingModuleManifest.valid_module_path("module.wasm"), true, "module-local path accepted")
	_eq(ScriptingModuleManifest.valid_module_path("res://client.wasm"), false, "res path rejected")
	_eq(ScriptingModuleManifest.valid_module_path("a/../client.wasm"), false, "traversal rejected")
	var duplicate_capability := JSON.stringify({
		"format": 1, "id": "acme.duplicate", "runtime": "wasm-component",
		"world": "vrweb:module@1", "component": "module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"requires": ["vrweb/core/1"], "optional": ["vrweb/core/1"],
	}).to_utf8_buffer()
	result = ScriptingModuleManifest.parse(duplicate_capability)
	_eq(result.ok, false, "required and optional capability cannot overlap")
	var unsafe_limits := JSON.stringify({
		"format": 1, "id": "acme.limits", "runtime": "wasm-component",
		"world": "vrweb:module@1", "component": "module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"limits": {"fuel": 50000001, "memory_bytes": 0, "mystery": 1.5},
	}).to_utf8_buffer()
	result = ScriptingModuleManifest.parse(unsafe_limits)
	_eq(result.ok, false, "manifest cannot enlarge or invent runtime limits")
	_eq(result.errors.size(), 3, "all invalid runtime limits reported")
	var unsafe_debug := JSON.stringify({
		"format": 1, "id": "acme.debug", "runtime": "wasm-component",
		"world": "vrweb:module@1", "component": "module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"debug": {"source_map": "../host/source.map", "execute": true},
	}).to_utf8_buffer()
	result = ScriptingModuleManifest.parse(unsafe_debug)
	_eq(result.ok, false, "unsafe or capability-like debug metadata rejected")
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
