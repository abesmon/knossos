extends SceneTree

## Reproducible demo builder:
## godot --headless --path . --log-file /tmp/knossos-package-demo.log \
##   --script tests/build_package_demo.gd


func _initialize() -> void:
	var output := "res://test_pages/lights.vrmod"
	var script := load("res://tests/fixtures/package_demo/light_switch.gd") as GDScript
	var report := VrwebPackageExporter.build(script, "demo.lights", output, "StaticBody3D",
			["vrweb/core/1", "vrweb/scene/1", "vrweb/state/1", "vrweb/input/1",
			"vrweb/log/1", "godot/engine/4"], ["vrweb/assets/1", "vrweb/timers/1"])
	if not bool(report.get("ok", false)):
		push_error("package-demo export failed: %s" % str(report.get("error", "unknown")))
		quit(1)
		return
	print("package-demo integrity: ", report.integrity)
	print("package-demo hash: ", report.hash)
	quit(0)
