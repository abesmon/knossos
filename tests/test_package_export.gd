extends Node

var _failed := false


func _ready() -> void:
	var existing_assets := {"icon": {}}
	_eq(VrwebPackageExporter._asset_id("other/icon.png", existing_assets).begins_with("icon_"),
			true, "colliding asset names receive deterministic suffix")
	var script := load("res://tests/fixtures/package_export/main.gd") as GDScript
	var authored := Node3D.new()
	authored.set_script(script)
	authored.set("marker", "authored-package")
	authored.set_meta(VrwebExporter.META_SCRIPT_MODE, VrwebExporter.SCRIPT_MODE_PACKAGE)
	authored.set_meta(VrwebExporter.META_SCRIPT_ID, "exported.package")
	var root := Node3D.new()
	root.add_child(authored)
	var output := "user://package_export/page.html"
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var report := VrwebExporter.export_scene_report(root, VrwebBuilder.MODE_EXCLUSIVE, output)
	var html := str(report.html)
	_eq(report.ok, true, "structured export report succeeds")
	_eq(report.packages.size(), 1, "export report lists package")
	_eq(report.packages[0].assets.has("switch_scene"), true, "export report lists assets")
	var first_package := FileAccess.get_file_as_bytes(
			output.get_base_dir().path_join("exported.package.vrmod"))
	var second_report := VrwebExporter.export_scene_report(root, VrwebBuilder.MODE_EXCLUSIVE, output)
	var second_package := FileAccess.get_file_as_bytes(
			output.get_base_dir().path_join("exported.package.vrmod"))
	_eq(second_report.ok, true, "repeated export succeeds")
	_eq(first_package, second_package, "same inputs produce byte-identical .vrmod")
	root.free()
	var duplicate_root := Node3D.new()
	for index in 2:
		var duplicate := Node3D.new()
		duplicate.set_script(script)
		duplicate.set_meta(VrwebExporter.META_SCRIPT_MODE, VrwebExporter.SCRIPT_MODE_PACKAGE)
		duplicate.set_meta(VrwebExporter.META_SCRIPT_ID, "duplicate.package")
		duplicate_root.add_child(duplicate)
	var failed_report := VrwebExporter.export_scene_report(duplicate_root,
			VrwebBuilder.MODE_EXCLUSIVE, output)
	_eq(failed_report.ok, false, "duplicate package id fails structured report")
	_eq(failed_report.errors.size() > 0, true, "failed report explains export error")
	duplicate_root.free()
	var package_path := output.get_base_dir().path_join("exported.package.vrmod")
	_eq(FileAccess.file_exists(package_path), true, "exporter writes sibling .vrmod")
	_eq(html.contains("<VRWebModule"), true, "exporter writes module declaration")
	var doc := HtmlParser.parse(html)
	var collected := PageModuleCollector.collect(doc, "vrweblocal:///tmp/page.html")
	_eq(collected.modules.size(), 1, "exported package declaration parses")
	if collected.modules.size() == 1:
		var bytes := FileAccess.get_file_as_bytes(package_path)
		var module: Dictionary = collected.modules[0]
		var checked := PageModuleIntegrity.verify(module, "https://page.test/index.html",
				"https://page.test/exported.package.vrmod", bytes)
		_eq(checked.allowed, true, "generated integrity matches package")
		var cached := PageModuleCache.store(bytes)
		module.hash = cached.hash
		module.cache_path = cached.path
		var unpacked := PageModulePackage.unpack(module)
		_eq(unpacked.ok, true, "exported package validates and unpacks")
		if unpacked.ok:
			_eq(unpacked.module.manifest.assets.has("message"), true,
					"exporter declares relative non-script dependency as asset")
			_eq(unpacked.module.manifest.assets.has("switch_scene"), true,
					"exporter declares PackedScene asset")
			_eq(unpacked.module.manifest.assets.switch_scene.type, "PackedScene",
					"exporter records detected asset type")
			_eq(unpacked.module.manifest.assets.has("switch_data"), true,
					"exporter recursively declares scene dependency")
			_eq(unpacked.module.manifest.assets.has("switch_icon"), true,
					"exporter recursively declares imported source asset")
			_eq(unpacked.module.manifest.assets.switch_icon.type.is_empty(), false,
					"converted imported asset keeps a runtime type")
			var registry := PageModuleRegistry.new()
			var prepared := registry.prepare([unpacked.module], PageModuleRegistry.ScriptMode.ALLOW_ALL)
			_eq(prepared.ok, true, "exported package prepares")
			var built := VrwebBuilder.build(doc, "vrweblocal:///tmp/page.html", registry)
			var built_root: Node = built.root
			var component: Node = built_root.get_child(0) if built_root != null else null
			_eq(component != null, true, "exported package component materializes")
			if component != null:
				_eq(component.call("answer"), 105, "exported dependency executes")
				_eq(component.get("marker"), "authored-package", "package property round-trips")
				var context: PageModuleContext = component.get_meta("vrweb_module_context")
				_eq(context.assets.text("message").strip_edges(), "hello from exported asset",
						"exported asset is available through context.assets")
				var packed := context.assets.load("switch_scene") as PackedScene
				_eq(packed != null, true, "rewritten PackedScene loads from module root")
				if packed != null:
					var scene_instance := packed.instantiate()
					_eq(scene_instance.get_meta("value").resource_name, "packaged-switch-data",
							"recursive .tres dependency resolves after rewrite")
					_eq((scene_instance.get_node("Icon") as Sprite3D).texture != null, true,
							"source SVG texture loads without project import cache")
					scene_instance.free()
			if built_root != null:
				built_root.free()
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
