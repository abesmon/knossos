extends Node

## Byte-for-byte regression test for the portable declarative export path. This scene does not
## compile or invoke Knossos' runtime builder.

var _ok := true


func _ready() -> void:
	var root := Node3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2, 1, 3)
	var mesh_node := MeshInstance3D.new()
	mesh_node.mesh = mesh
	mesh_node.transform = Transform3D(Basis.IDENTITY, Vector3(-10, 0.05, 0))
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2, 1, 3)
	collision.shape = shape
	body.add_child(collision)
	mesh_node.add_child(body)
	root.add_child(mesh_node)

	var light := OmniLight3D.new()
	light.omni_range = 12.0
	light.transform = Transform3D(Basis.IDENTITY, Vector3(-10, 4, 0))
	root.add_child(light)

	var sprite := Sprite3D.new()
	var texture := VrwebExtResource.new()
	texture.url = "https://godotengine.org/assets/press/icon_color.png"
	texture.type = "Texture2D"
	sprite.set_meta(VrwebExtResource.META_BINDINGS, {"texture": texture})
	root.add_child(sprite)

	var scene_placeholder := Node3D.new()
	scene_placeholder.transform = Transform3D(Basis.IDENTITY, Vector3(-13, 0.1, 2))
	var external_scene := VrwebExtResource.new()
	external_scene.url = "https://example.com/duck.glb"
	external_scene.type = "PackedScene"
	scene_placeholder.set_meta(VrwebExtResource.META_SCENE, external_scene)
	root.add_child(scene_placeholder)

	var spawner := VrwebSpawner.new()
	spawner.mode = "random"
	for position in [Vector3(-7, 1.6, 3), Vector3(-13, 1.6, -3)]:
		var point := Marker3D.new()
		point.position = position
		spawner.add_child(point)
	root.add_child(spawner)

	var report := VrwebExporter.export_scene_report(root, VrwebFormat.MODE_EXCLUSIVE)
	var golden := FileAccess.get_file_as_string(
			"res://tests/fixtures/export_core/export_core_expected.html")
	_check(bool(report.get("ok", false)), "portable exporter report succeeds")
	var actual := str(report.get("html", ""))
	if actual != golden:
		print("--- ACTUAL EXPORT ---\n", actual, "--- END ACTUAL EXPORT ---")
	_check(actual == golden,
			"portable exporter matches byte-for-byte golden fixture")
	_check(not FileAccess.get_file_as_string(
			"res://addons/vrweb_tools/vrweb_exporter.gd").contains("VrwebBuilder."),
			"exporter has no compile-time VrwebBuilder dependency")
	root.free()
	print("=== ", ("ALL PASSED" if _ok else "FAILURES ABOVE"), " ===")
	get_tree().quit(0 if _ok else 1)


func _check(condition: bool, label: String) -> void:
	print(("  [ok]  " if condition else "  [FAIL] "), label)
	_ok = condition and _ok
