extends SceneTree

var _failed := false


func _initialize() -> void:
	var root := Node3D.new()
	var component := VrwebWasmComponent.new()
	component.name = "PortableLight"
	component.module_id = "external.tiny"
	component.export_name = "default"
	component.package_path = "res://test_pages/lights.vrmod"
	component.position = Vector3(1, 2, 3)
	root.add_child(component)
	var spawner := VrwebSpawner.new()
	spawner.add_child(Marker3D.new())
	root.add_child(spawner)
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	root.add_child(collision)
	var output := "user://maker-wasm-test/world.html"
	var report := VrwebExporter.export_scene_report(root, VrwebFormat.MODE_EXCLUSIVE, output,
			VrwebCompatibility.PROFILE_STRICT)
	_eq(report.ok, true, "prebuilt WASM package exports without executing it")
	_eq(report.packages.size(), 1, "package appears once in build report")
	var html := str(report.html)
	_eq(html.contains("<VRWebModule id=\"external.tiny\""), true,
			"HTML declares content-addressed module")
	_eq(html.contains("<VRWebComponent module=\"external.tiny\" export=\"default\""), true,
			"scene binds selected export")
	_eq(html.contains(", 1, 2, 3)\""), true,
			"authoring transform is preserved")
	if report.packages.size() == 1:
		var package: Dictionary = report.packages[0]
		_eq(str(package.file).begins_with("modules/"), true,
				"published package path is content-addressed")
		_eq(FileAccess.get_file_as_bytes(output.get_base_dir().path_join(package.file)),
				FileAccess.get_file_as_bytes("res://test_pages/lights.vrmod"),
				"published package bytes are exact")
	var standalone := VrwebExporter.export_vrwml_report(root, "user://maker-wasm-test/world.vrwml",
			VrwebCompatibility.PROFILE_STRICT)
	_eq(standalone.ok, false, "standalone VRWML rejects module without HTML declaration envelope")
	root.free()
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
