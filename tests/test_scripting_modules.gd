extends SceneTree

## Document -> WASM module IR, без сети и исполнения кода.

var _failed := false


func _initialize() -> void:
	_test_package()
	_test_direct_component()
	_test_errors_and_scripts_ignored()
	quit(1 if _failed else 0)


func _test_package() -> void:
	var html := """
<VRWebModule id="acme.lights" src="mods/lights.vrmod"
             integrity="sha256-two" runtime="wasm-component"
             world="vrweb:module@1"/>
"""
	var result := ScriptingModuleCollector.collect(HtmlParser.parse(html), "https://example.test/world/index.html")
	_eq(result.errors, [], "WASM module has no errors")
	_eq(result.modules.size(), 1, "package collected")
	if result.modules.size() == 1:
		var module: Dictionary = result.modules[0]
		_eq(module.kind, "package", "package kind")
		_eq(module.runtime, "wasm-component", "runtime normalized")
		_eq(module.world, "vrweb:module@1", "world normalized")
		_eq(module.src, "mods/lights.vrmod", "relative URL preserved")
		_eq(module.base_url, "https://example.test/world/index.html", "base URL preserved")


func _test_errors_and_scripts_ignored() -> void:
	var html := """
<script>window.alert('ignored')</script>
<script type="text/javascript">window.alert('ignored')</script>
<VRWebModule id="dup" src="one.vrmod"/>
<VRWebModule id="dup" src="two.vrmod"/>
<VRWebModule id="bad/id" src="bad.vrmod"/>
<VRWebModule id="unsupported" src="unsupported.vrmod" runtime="unsupported-runtime"/>
<VRWebModule id="world" src="world.vrmod" world="vrweb:module@2"/>
"""
	var result := ScriptingModuleCollector.collect(HtmlParser.parse(html), "https://example.test/")
	_eq(result.modules.size(), 1, "only first valid WASM module accepted")
	_eq(result.errors.size(), 4, "duplicate, invalid id, runtime and world reported")


func _test_direct_component() -> void:
	var metadata := JSON.stringify({
		"format": 1, "id": "acme.direct", "runtime": "wasm-component",
		"world": "vrweb:module@1", "component": "module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"requires": ["vrweb:core/1"], "optional": [],
	})
	var html := "<VRWebModule id=\"acme.direct\" src=\"direct.wasm?rev=1\" " \
			+ "manifest='%s'/>" % metadata
	var result := ScriptingModuleCollector.collect(HtmlParser.parse(html),
			"https://example.test/world/index.html")
	_eq(result.errors, [], "direct WASM with manifest metadata accepted")
	_eq(result.modules.size(), 1, "direct component collected")
	if result.modules.size() == 1:
		_eq(result.modules[0].kind, "component", "direct artifact kind preserved")
		_eq(result.modules[0].exports.default.kind, "scene-component",
				"direct manifest exports normalized")
	var missing := ScriptingModuleCollector.collect(HtmlParser.parse(
			"<VRWebModule id='acme.missing' src='missing.wasm'/>") ,
			"https://example.test/world/index.html")
	_eq(missing.modules, [], "direct WASM without metadata rejected")
	_eq(missing.errors.size(), 1, "missing direct manifest has one diagnostic")


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
