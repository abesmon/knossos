extends Node

var _failed := false


func _ready() -> void:
	var source := "extends Node3D\n@export var marker := 'default'\nfunc answer(): return 42\n"
	var script := GDScript.new()
	script.source_code = source
	_eq(script.reload(), OK, "export fixture script compiles")
	var authored := Node3D.new()
	authored.set_script(script)
	authored.set("marker", "authored")
	authored.position = Vector3(3, 2, 1)
	authored.set_meta(VrwebExporter.META_SCRIPT_MODE, VrwebExporter.SCRIPT_MODE_INLINE)
	authored.set_meta(VrwebExporter.META_SCRIPT_ID, "exported.inline")
	var label := Label3D.new()
	label.name = "Label"
	label.text = "child"
	authored.add_child(label)
	var export_root := Node3D.new()
	export_root.add_child(authored)
	var html := VrwebExporter.export_scene(export_root, VrwebBuilder.MODE_EXCLUSIVE)
	export_root.free()
	_eq(html.contains('type="application/vrweb+gdscript"'), true, "export writes script block")
	_eq(html.contains('<VRWebComponent module="#exported.inline"'), true, "export writes component")

	var doc := HtmlParser.parse(html)
	var collected := ScriptingModuleCollector.collect(doc, "vrwebresource://exported.html")
	var registry := ScriptingModuleRegistry.new()
	var prepared := registry.prepare_inline(collected.modules, ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
	_eq(prepared.ok, true, "exported inline source compiles in registry")
	var built := VrwebBuilder.build(doc, "vrwebresource://exported.html", registry)
	var root: Node = built.root
	var component: Node = root.get_child(0) if root != null and root.get_child_count() > 0 else null
	_eq(component != null, true, "exported component materialized")
	if component != null:
		_eq(component.call("answer"), 42, "exported behavior preserved")
		_eq(component.get("marker"), "authored", "script property round-trips")
		_eq(component.position, Vector3(3, 2, 1), "base property round-trips")
		_eq(component.get_child_count(), 1, "children round-trip")
		if component.get_child_count() == 1:
			_eq(component.get_child(0).text, "child", "child properties round-trip")
	if root != null:
		root.free()
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
