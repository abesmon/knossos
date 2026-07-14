extends Node


func _ready() -> void:
	var script := load("res://modules/interaction_example.gd") as GDScript
	var output := "res://module-dist/acme.clean.vrmod"
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var result := VrwebPackageExporter.build(script, "acme.clean", output, "Node3D",
			VrwebModuleMetadata.DEFAULT_REQUIRES, VrwebModuleMetadata.DEFAULT_OPTIONAL, {
				"version": "1.2.3", "permissions": ["network:origin"],
				"requires": ["vrweb/core/1", "godot/engine/4"],
				"optional": ["vrweb/log/1"],
			})
	var ok := bool(result.get("ok", false))
	var reader := ZIPReader.new()
	ok = ok and reader.open(output) == OK
	if ok:
		var manifest = JSON.parse_string(reader.read_file("vrweb-module.json").get_string_from_utf8())
		ok = typeof(manifest) == TYPE_DICTIONARY \
				and manifest.get("id") == "acme.clean" \
				and manifest.get("version") == "1.2.3" \
				and manifest.get("permissions") == ["network:origin"] \
				and manifest.get("requires") == ["vrweb/core/1", "godot/engine/4"] \
				and manifest.get("optional") == ["vrweb/log/1"]
	reader.close()
	var invalid := VrwebModuleMetadata.normalize({"id": "bad id", "version": "latest"})
	ok = ok and not bool(invalid.get("ok", true))
	var inline := VrwebInlineExporter.prepare(script, "acme.inline", "StaticBody3D")
	ok = ok and bool(inline.get("ok", false)) \
			and inline.definition.get("runtime") == "trusted-gdscript"
	var dependent := GDScript.new()
	dependent.source_code = "extends Node3D\nvar dependency = preload('./other.gd')\n"
	ok = ok and not bool(VrwebInlineExporter.prepare(
			dependent, "acme.invalid", "Node3D").get("ok", true))
	print("CLEAN MAKER MODULE ", "PASSED" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)
