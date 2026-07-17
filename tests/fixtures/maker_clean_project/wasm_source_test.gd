extends Node


func _ready() -> void:
	var adapter := OS.get_environment("VRWEB_JS_ADAPTER")
	var component := VrwebWasmSourceComponent.new()
	component.module_id = "vrweb.example.maker-source"
	component.export_name = "default"
	component.source_path = "res://wasm source/main.ts"
	component.manifest_path = "res://wasm source/vrweb-module.json"
	component.package_path = "res://wasm source/build/source.vrmod"
	component.adapter_script = adapter
	var first := component.ensure_package()
	var first_bytes := FileAccess.get_file_as_bytes(component.package_path)
	var second := component.ensure_package()
	var ok: bool = bool(first.get("ok", false)) and not bool(first.get("skipped", true)) \
			and bool(second.get("ok", false)) and bool(second.get("skipped", false)) \
			and first_bytes == FileAccess.get_file_as_bytes(component.package_path)
	var source := FileAccess.get_file_as_string(component.source_path)
	_write(component.source_path, source + "\n// content hash rebuild\n")
	var changed := component.ensure_package()
	ok = ok and bool(changed.get("ok", false)) and not bool(changed.get("skipped", true)) \
			and str(changed.get("fingerprint", "")) != str(first.get("fingerprint", ""))
	var good_bytes := FileAccess.get_file_as_bytes(component.package_path)
	_write(component.source_path, "export function create( {\n")
	var compile_error := component.ensure_package()
	ok = ok and not bool(compile_error.get("ok", true)) \
			and FileAccess.get_file_as_bytes(component.package_path) == good_bytes
	_write(component.source_path, source)
	component.adapter_script = adapter
	_write(component.source_path, source + "\n// canceled build\n")
	var started := component.start_package_build()
	var canceled := component.cancel_package_build()
	ok = ok and bool(started.get("ok", false)) and bool(started.get("running", false)) \
			and bool(canceled.get("ok", false)) and bool(canceled.get("canceled", false)) \
			and FileAccess.get_file_as_bytes(component.package_path) == good_bytes
	_write(component.source_path, source)
	component.adapter_script = "/missing/vrweb-adapter.mjs"
	var missing := component.ensure_package()
	ok = ok and not bool(missing.get("ok", true)) \
			and FileAccess.get_file_as_bytes(component.package_path) == good_bytes
	print("CLEAN MAKER WASM SOURCE ", "PASSED" if ok else "FAILED")
	component.free()
	get_tree().quit(0 if ok else 1)


func _write(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()
