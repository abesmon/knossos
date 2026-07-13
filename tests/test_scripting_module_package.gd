extends Node

var _failed := false


func _ready() -> void:
	var zip_path := "user://package_fixture.vrmod"
	var packer := ZIPPacker.new()
	_eq(packer.open(zip_path), OK, "fixture zip opened")
	_add(packer, "vrweb-module.json", JSON.stringify({
		"format": 1, "id": "acme.package", "version": "1.0.0", "knossos_api": "1",
		"runtime": "trusted-gdscript",
		"exports": {"PackageNode": {"script": "scripts/main.gd", "base": "Node3D"}},
		"assets": {"message": {"path": "data/message.txt", "type": ""}},
		"permissions": [],
	}))
	_add(packer, "data/message.txt", "hello from package")
	_add(packer, "scripts/dep.gd", "extends RefCounted\nconst VALUE := 91\n")
	_add(packer, "scripts/main.gd",
			"extends Node3D\nconst Dep = preload('./dep.gd')\nfunc answer(): return Dep.VALUE\n")
	packer.close()
	var bytes := FileAccess.get_file_as_bytes(zip_path)
	var cached := ScriptingModuleCache.store(bytes)
	var module := {"id": "acme.package", "kind": "package", "runtime": "trusted-gdscript",
		"hash": cached.hash, "cache_path": cached.path}
	var unpacked := ScriptingModulePackage.unpack(module)
	_eq(unpacked.ok, true, "package validates and unpacks")
	if unpacked.ok:
		var registry := ScriptingModuleRegistry.new()
		var prepared := registry.prepare([unpacked.module], ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
		_eq(prepared.ok, true, "package exports prepare")
		var made := registry.instantiate_export("acme.package", "PackageNode")
		_eq(str(made.error), "", "package class instantiates")
		if made.node != null:
			_eq(made.node.call("answer"), 91, "package-relative dependency executes")
			_eq(made.context.has("assets/1"), true, "package context advertises assets")
			_eq(made.context.assets.has("message"), true, "declared asset is visible")
			_eq(made.context.assets.text("message"), "hello from package",
					"declared module-local text is read")
			_eq(made.context.assets.has("../message"), false, "undeclared traversal is hidden")
			made.node.free()
	get_tree().quit(1 if _failed else 0)


func _add(packer: ZIPPacker, path: String, content: String) -> void:
	_eq(packer.start_file(path), OK, "zip entry %s started" % path)
	_eq(packer.write_file(content.to_utf8_buffer()), OK, "zip entry %s written" % path)
	packer.close_file()


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
