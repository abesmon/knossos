extends Node

var _failed := false


func _ready() -> void:
	var html := FileAccess.get_file_as_string("res://test_pages/package_script.html")
	var doc := HtmlParser.parse(html)
	var collected := ScriptingModuleCollector.collect(doc, "vrwebresource://package_script.html")
	var module: Dictionary
	if collected.modules.size() == 1:
		_eq(collected.errors, [], "package-demo document parses")
		_eq(collected.modules.size(), 1, "package-demo declares one module")
		module = collected.modules[0]
	else:
		# Imported .html is remapped in an exported PCK, while the raw .vrmod remains an explicit
		# include. Recreate the equivalent declaration and continue through the real loader.
		_eq(OS.has_feature("editor"), false, "raw HTML remap fallback is exported-build only")
		module = {
			"id": "demo.lights", "kind": "package", "runtime": "trusted-gdscript",
			"integrity": "sha256-OWThVNPjw8KyODFORe1BvONJzmkYzGORUK8lBmZNsGM=",
		}
	var bytes := FileAccess.get_file_as_bytes("res://test_pages/lights.vrmod")
	var checked := ScriptingModuleIntegrity.verify(module, "vrwebresource://package_script.html",
			"vrwebresource://lights.vrmod", bytes)
	_eq(checked.allowed, true, "checked-in package matches demo integrity")
	var cached := ScriptingModuleCache.store(bytes)
	module.hash = cached.hash
	module.cache_path = cached.path
	var unpacked := ScriptingModulePackage.unpack(module)
	_eq(unpacked.ok, true, "package-demo validates and unpacks")
	if not unpacked.ok:
		get_tree().quit(1)
		return
	var manifest: Dictionary = unpacked.module.manifest
	_eq("vrweb/core/1" in manifest.requires, true, "demo requires portable core")
	_eq("godot/engine/4" in manifest.requires, true, "demo declares Godot runtime extension")
	var unsupported: Dictionary = unpacked.module.duplicate(true)
	unsupported.manifest.requires.append("vrweb/future/99")
	var rejected := ScriptingModuleRegistry.new().prepare([unsupported],
			ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
	_eq(rejected.ok, false, "unknown required capability rejects only the module")
	_eq(str(rejected.errors[0]).contains("vrweb/future/99"), true,
			"capability rejection is explicit")
	var registry := ScriptingModuleRegistry.new()
	var prepared := registry.prepare([unpacked.module], ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
	_eq(prepared.ok, true, "package-demo prepares with available capabilities")
	var made := registry.instantiate_export("demo.lights", "default")
	_eq(str(made.error), "", "package-demo LightSwitch instantiates")
	if not str(made.error).is_empty():
		get_tree().quit(1)
		return
	var component: Node = made.node
	add_child(component)
	await get_tree().process_frame
	var context: ScriptingModuleContext = made.context
	_eq(context.mounted, true, "package-demo mounts through public lifecycle")
	_eq(context.features.has("vrweb/input/1"), true, "package-demo receives public input API")
	_eq(component.has_meta(ScriptingModuleInputAPI.META), true, "LightSwitch binds portable activation")
	_eq(component.get_node_or_null("ExportedSwitchScene") != null, true,
			"packaged scene and nested asset instantiate")
	component.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
