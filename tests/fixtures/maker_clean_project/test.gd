extends Node


func _ready() -> void:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 1, 3)
	mesh.mesh = box
	root.add_child(mesh)
	var spawner := VrwebSpawner.new()
	var marker := Marker3D.new()
	marker.position = Vector3(0, 1.6, 0)
	spawner.add_child(marker)
	root.add_child(spawner)
	var report := VrwebExporter.export_scene_report(root, VrwebFormat.MODE_EXCLUSIVE, "",
			VrwebCompatibility.PROFILE_STRICT)
	var html := str(report.get("html", ""))
	var ok := bool(report.get("ok", false)) \
			and html.contains("<MeshInstance3D") \
			and html.contains("<Resource id=\"r0\" type=\"BoxMesh\"") \
			and html.contains("<VRWebSpawner mode=\"first\">")
	var unsupported := Camera3D.new()
	unsupported.name = "UnsupportedCamera"
	root.add_child(unsupported)
	var rejected := VrwebExporter.export_scene_report(root, VrwebFormat.MODE_EXCLUSIVE, "",
			VrwebCompatibility.PROFILE_STRICT)
	ok = ok and not bool(rejected.get("ok", true)) \
			and str(rejected.get("errors", [])).contains("/Node3D/UnsupportedCamera")
	print("CLEAN MAKER CORE ", "PASSED" if ok else "FAILED")
	root.free()
	get_tree().quit(0 if ok else 1)
