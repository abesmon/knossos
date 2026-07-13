extends SceneTree

## Document -> module IR, без сети и исполнения кода.

var _failed := false


func _initialize() -> void:
	_test_inline()
	_test_external_script_and_package()
	_test_errors_and_javascript_ignored()
	quit(1 if _failed else 0)


func _test_inline() -> void:
	var source := "\nextends Node3D\nvar marker := '<tag>'\n"
	var html := '<script type="application/vrweb+gdscript" id="tiny" data-base="Node3D">%s</script>' % source
	var result := ScriptingModuleCollector.collect(HtmlParser.parse(html), "https://example.test/world/index.html")
	_eq(result.errors, [], "inline module has no errors")
	_eq(result.modules.size(), 1, "inline module collected")
	if result.modules.size() == 1:
		var module: Dictionary = result.modules[0]
		_eq(module.kind, "inline", "inline kind")
		_eq(module.source, source, "raw source preserved exactly")
		_eq(module.hash, source.sha256_text(), "inline source is content-addressed")
		_eq(module.exports.default.base, "Node3D", "synthetic default export has base")


func _test_external_script_and_package() -> void:
	var html := """
<script type="application/vrweb+gdscript" id="small" src="./small.gd"
        integrity="sha256-one"></script>
<VRWebModule id="acme.lights" src="mods/lights.vrmod"
             integrity="sha256-two" mode="trusted-gdscript"/>
"""
	var result := ScriptingModuleCollector.collect(HtmlParser.parse(html), "https://example.test/world/index.html")
	_eq(result.errors, [], "external modules have no errors")
	_eq(result.modules.size(), 2, "script and package collected")
	if result.modules.size() == 2:
		_eq(result.modules[0].src, "./small.gd", "script keeps document-relative URL")
		_eq(result.modules[0].base_url, "https://example.test/world/index.html", "script keeps base URL")
		_eq(result.modules[1].src, "mods/lights.vrmod", "package keeps document-relative URL")


func _test_errors_and_javascript_ignored() -> void:
	var html := """
<script>window.alert('ignored')</script>
<script type="application/vrweb+gdscript" id="dup">extends Node</script>
<script type="application/vrweb+gdscript" id="dup" src="x.gd"></script>
<script type="application/vrweb+gdscript" id="bad/id">extends Node</script>
<script type="application/vrweb+gdscript" id="both" src="x.gd">extends Node</script>
"""
	var result := ScriptingModuleCollector.collect(HtmlParser.parse(html), "https://example.test/")
	_eq(result.modules.size(), 1, "only first valid VRWeb script accepted")
	_eq(result.errors.size(), 3, "duplicate, invalid id and body+src reported")


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
