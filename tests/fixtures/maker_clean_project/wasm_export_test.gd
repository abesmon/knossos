extends Node


func _ready() -> void:
	var root := Node3D.new()
	var component := VrwebWasmComponent.new()
	component.module_id = "fixture.delivery-lifecycle"
	component.export_name = "default"
	component.package_path = "res://wasm/lifecycle.vrmod"
	component.position = Vector3(1, 2, 3)
	root.add_child(component)
	var spawner := VrwebSpawner.new()
	spawner.add_child(Marker3D.new())
	root.add_child(spawner)
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	root.add_child(collision)

	var output := "res://dist/wasm-world.html"
	var report := VrwebExporter.export_scene_report(root, VrwebFormat.MODE_EXCLUSIVE, output,
			VrwebCompatibility.PROFILE_STRICT)
	var html := str(report.get("html", ""))
	var ok: bool = bool(report.get("ok", false)) and report.packages.size() == 1 \
			and html.contains("<VRWebModule id=\"fixture.delivery-lifecycle\"") \
			and html.contains("<VRWebComponent module=\"fixture.delivery-lifecycle\" export=\"default\"")
	if ok:
		ok = _write(output, html)
		var summary := report.duplicate(true)
		summary.erase("html")
		ok = ok and _write("res://dist/wasm-world.report.json",
				JSON.stringify(summary, "  ") + "\n")
	print("CLEAN MAKER WASM ", "PASSED" if ok else "FAILED")
	root.free()
	get_tree().quit(0 if ok else 1)


func _write(path: String, value: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(value)
	file.close()
	return true
