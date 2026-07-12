extends SceneTree

## Feasibility spike для page modules. Проверяет именно runtime API, которое понадобится
## trusted-gdscript loader'у. Запускать также в exported debug/release сборках.

var _failed := false


func _initialize() -> void:
	_test_source_compilation()
	_test_set_script()
	_test_compile_error()
	_test_user_module_dependencies()
	quit(1 if _failed else 0)


func _test_source_compilation() -> void:
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc answer(): return 42\n"
	_eq(script.reload(), OK, "GDScript source compiles at runtime")
	_eq(script.can_instantiate(), true, "compiled source can instantiate")
	var instance = script.new()
	_eq(instance.call("answer"), 42, "runtime instance executes")
	instance.free()


func _test_set_script() -> void:
	var script := GDScript.new()
	script.source_code = "extends Node3D\nvar marker := 'attached'\n"
	_eq(script.reload(), OK, "Node3D script compiles")
	var compatible := Node3D.new()
	compatible.set_script(script)
	_eq(compatible.get("marker"), "attached", "set_script attaches to compatible base")
	compatible.free()
	var incompatible := Node.new()
	incompatible.set_script(script)
	_eq(incompatible.get_script(), null, "set_script rejects incompatible base")
	incompatible.free()


func _test_compile_error() -> void:
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc broken(\n"
	_eq(script.reload() != OK, true, "invalid downloaded source is rejected")
	_eq(script.can_instantiate(), false, "invalid source cannot instantiate")


func _test_user_module_dependencies() -> void:
	var base := "user://page_module_spike"
	var a := base.path_join("hash_a")
	var b := base.path_join("hash_b")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(a))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(b))
	_write(a.path_join("dep.gd"), "extends RefCounted\nconst VALUE := 11\n")
	_write(a.path_join("main.gd"),
			"extends Node\nconst Dep = preload('./dep.gd')\nfunc answer(): return Dep.VALUE\n")
	_write(b.path_join("dep.gd"), "extends RefCounted\nconst VALUE := 22\n")
	_write(b.path_join("main.gd"),
			"extends Node\nconst Dep = preload('./dep.gd')\nfunc answer(): return Dep.VALUE\n")
	var script_a = ResourceLoader.load(a.path_join("main.gd"), "GDScript", ResourceLoader.CACHE_MODE_IGNORE)
	var script_b = ResourceLoader.load(b.path_join("main.gd"), "GDScript", ResourceLoader.CACHE_MODE_IGNORE)
	_eq(script_a is GDScript and script_a.can_instantiate(), true,
			"GDScript loads with relative dependency from user cache")
	_eq(script_b is GDScript and script_b.can_instantiate(), true,
			"second content-addressed module loads")
	if script_a is GDScript and script_a.can_instantiate():
		var instance_a = script_a.new()
		_eq(instance_a.call("answer"), 11, "hash_a resolves its own dependency")
		instance_a.free()
	if script_b is GDScript and script_b.can_instantiate():
		var instance_b = script_b.new()
		_eq(instance_b.call("answer"), 22, "hash_b does not reuse hash_a dependency")
		instance_b.free()


func _write(path: String, source: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write runtime fixture %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_string(source)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_fail("%s — expected %s, got %s" % [label, str(expected), str(actual)])


func _fail(message: String) -> void:
	_failed = true
	push_error("FAIL: " + message)
