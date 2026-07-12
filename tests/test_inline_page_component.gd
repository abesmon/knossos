extends Node

var _failed := false


func _ready() -> void:
	var html := FileAccess.get_file_as_string("res://test_pages/inline_script.html")
	var doc := HtmlParser.parse(html)
	var collected := PageModuleCollector.collect(doc, "vrwebresource://inline_script.html")
	_eq(collected.errors, [], "inline page module collected")
	var registry := PageModuleRegistry.new()
	var denied := registry.prepare_inline(collected.modules, PageModuleRegistry.ScriptMode.DENY_ALL)
	_eq(denied.pending.size(), 1, "deny-all leaves executable module pending")
	var selected := registry.prepare_inline(collected.modules, PageModuleRegistry.ScriptMode.SELECTED,
			{collected.modules[0].hash: true})
	_eq(selected.ok, true, "selected mode compiles exact approved hash")
	var prepared := registry.prepare_inline(collected.modules, PageModuleRegistry.ScriptMode.ALLOW_ALL)
	_eq(prepared.ok, true, "allow-all preflight compiles inline module")
	var built := VrwebBuilder.build(doc, "vrwebresource://inline_script.html", registry)
	var root: Node = built.get("root")
	var component := root.get_node_or_null("InlineComponent") if root != null else null
	_eq(component != null, true, "VRWebComponent materialized from registry")
	if component != null:
		_eq(component.call("answer"), 42, "page-defined method executes")
		_eq(component.get("marker"), "from-html", "HTML attributes initialize script property")
		_eq(component.call("presentation_text"), "INLINE SCRIPT: from-html = 42",
				"scene presentation uses page-defined behavior")
		_eq(component.position, Vector3(0, 1.7, -3), "base Node3D property applied")
		_eq(component.has_node("ChildLabel"), true, "declarative child attached to page class")
	_eq(root.get_node_or_null("Ground/StaticBody3D/CollisionShape3D") != null, true,
			"demo has collidable ground")
	root.free()
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
