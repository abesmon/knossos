extends SceneTree

var _failed := false


func _initialize() -> void:
	var package_bytes := FileAccess.get_file_as_bytes(
			"res://test_pages/wasm_scene_demo.vrmod")
	var cached := ScriptingModuleCache.store(package_bytes)
	var unpacked := ScriptingModulePackage.unpack({
		"id": "demo.wasm-scene", "hash": cached.hash, "cache_path": cached.path,
	})
	_eq(unpacked.ok, true, "visible demo package validates")
	if not bool(unpacked.ok):
		quit(1)
		return
	var backend := NativeWasmBackend.new()
	_eq(backend.prepare([unpacked.module]).ok, true, "visible demo component prepares")
	var made := backend.instantiate_export("demo.wasm-scene", "default")
	_eq(str(made.error), "", "visible demo component instantiates")
	if made.node != null:
		var labels: Array[Node] = made.node.find_children("*", "Label3D", true, false)
		var meshes: Array[Node] = made.node.find_children("*", "MeshInstance3D", true, false)
		var lights: Array[Node] = made.node.find_children("*", "OmniLight3D", true, false)
		_eq(labels.size(), 1, "demo creates its visible caption through Scene API")
		_eq(meshes.size(), 1, "demo creates its mesh through Scene API")
		_eq(lights.size(), 1, "demo creates its light through Scene API")
		if not labels.is_empty():
			_eq((labels[0] as Label3D).text,
					"CREATED BY A SANDBOXED WASM COMPONENT", "caption explains visible result")
		if not meshes.is_empty():
			_eq((meshes[0] as MeshInstance3D).mesh is BoxMesh, true,
					"demo binds a guest-owned BoxMesh")
		made.node.free()
	backend.close()
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
