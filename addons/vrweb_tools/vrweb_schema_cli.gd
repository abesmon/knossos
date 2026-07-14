extends SceneTree

const SchemaGenerator = preload("res://addons/vrweb_tools/vrweb_schema_generator.gd")

## Usage:
##   godot --headless --path . --script res://addons/vrweb_tools/vrweb_schema_cli.gd -- \
##     --output=res://schemas/vrweb-html-data.json [--check]


func _initialize() -> void:
	var output := "res://schemas/vrweb-html-data.json"
	var check := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
		elif arg == "--check":
			check = true
	var expected: String = SchemaGenerator.json_text()
	if check:
		if not FileAccess.file_exists(output):
			push_error("VRWeb schema is missing: " + output)
			quit(1)
			return
		if FileAccess.get_file_as_string(output) != expected:
			push_error("VRWeb schema is stale; regenerate " + output)
			quit(1)
			return
		print("VRWeb schema is current: " + output)
		quit(0)
		return
	var absolute := ProjectSettings.globalize_path(output) if output.begins_with("res://") \
			or output.begins_with("user://") else output
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write VRWeb schema: " + output)
		quit(1)
		return
	file.store_string(expected)
	file.close()
	print("VRWeb schema generated: " + output)
	quit(0)
