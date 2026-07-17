extends SceneTree

## One end-to-end authoring cycle: TypeScript source -> Maker adapter -> .vrmod -> native runtime
## -> failed rebuild preservation -> changed artifact -> in-process reload with persistent state.

const MODULE_ID := "vrweb.example.maker-reload"
const ROOT := "user://maker-wasm-reload"
const SOURCE := ROOT + "/main.ts"
const MANIFEST := ROOT + "/vrweb-module.json"
const PACKAGE := ROOT + "/build/module.vrmod"

var _failed := false


func _initialize() -> void:
	if not NativeWasmBackend.is_available():
		_fail("native WASM backend unavailable")
		quit(1)
		return
	for stale in [PACKAGE, PACKAGE + VrwebWasmSourceComponent.BUILD_METADATA_SUFFIX]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))
	_write(MANIFEST, JSON.stringify({
		"format": 1,
		"id": MODULE_ID,
		"version": "1.0.0",
		"sdk": "1.0.0",
		"runtime": "wasm-component",
		"world": "vrweb:module@1",
		"component": "module.wasm",
		"exports": {"default": {"kind": "scene-component"}},
		"requires": ["vrweb:core/1", "vrweb:scene/1", "vrweb:assets/1",
			"vrweb:state/1", "vrweb:timers/1", "vrweb:input/1", "vrweb:features/1",
			"vrweb:log/1"],
		"optional": [],
		"limits": {"fuel": 50000000},
		"debug": {"source_map": "debug/module.wasm.map"},
	}, "  ") + "\n")

	var component := VrwebWasmSourceComponent.new()
	component.module_id = MODULE_ID
	component.export_name = "default"
	component.source_path = SOURCE
	component.manifest_path = MANIFEST
	component.package_path = PACKAGE
	component.adapter_script = ProjectSettings.globalize_path(
			"res://sdk/javascript/build.mjs")

	_write(SOURCE, _initial_source())
	var initial_build := component.ensure_package()
	_check(bool(initial_build.get("ok", false)) and not bool(initial_build.get("skipped", true)),
			"Maker builds initial TypeScript artifact")
	if not bool(initial_build.get("ok", false)):
		component.free()
		quit(1)
		return
	var initial_bytes := FileAccess.get_file_as_bytes(PACKAGE)
	var initial_module := _unpack(initial_bytes)
	_check(not initial_module.is_empty(), "initial package passes production delivery")
	var backend := NativeWasmBackend.new()
	_check(bool(backend.prepare([initial_module]).ok),
			"initial package compiles in production runtime")
	var made := backend.instantiate_export(MODULE_ID, "default")
	_check(str(made.error).is_empty() and made.node != null, "initial create and mount execute")
	if made.node == null:
		backend.close()
		component.free()
		quit(1)
		return
	get_root().add_child(made.node)
	var old_instance := str(made.context.instance_id)
	_check(bool(backend.deliver_event(MODULE_ID, {"kind": "persist"}).ok),
			"initial event writes module state")

	_write(SOURCE, "export function create( {\n")
	var broken := component.ensure_package()
	_check(not bool(broken.get("ok", true)), "TypeScript compile error is reported")
	_check(FileAccess.get_file_as_bytes(PACKAGE) == initial_bytes,
			"compile error preserves last successful package byte-for-byte")
	_check(bool(backend.deliver_event(MODULE_ID, {"kind": "still-running"}).ok),
			"old instance remains live after failed Maker build")

	_write(SOURCE, _replacement_source())
	var replacement_build := component.ensure_package()
	_check(bool(replacement_build.get("ok", false))
			and not bool(replacement_build.get("skipped", true)),
			"Maker builds corrected replacement artifact")
	var replacement_bytes := FileAccess.get_file_as_bytes(PACKAGE)
	_check(replacement_bytes != initial_bytes, "source change produces a new artifact")
	var replacement_module := _unpack(replacement_bytes)
	_check(not replacement_module.is_empty()
			and str(replacement_module.hash) != str(initial_module.hash),
			"delivery exposes a new content hash")
	var reloaded := backend.reload_module(replacement_module)
	_check(bool(reloaded.get("ok", false)), "validated replacement reload succeeds in-process")
	_check(str(reloaded.get("old_hash", "")) == str(initial_module.hash)
			and str(reloaded.get("new_hash", "")) == str(replacement_module.hash),
			"reload reports exact old and new artifact hashes")
	_check(Array(backend.runtime_object().call("instance_log_codes", old_instance)) ==
			[101, 102, 103, 103, 104], "old JS instance unmounts exactly once")
	var replacements: Array = reloaded.get("replacements", [])
	_check(replacements.size() == 1, "reload replaces the one live scene instance")
	if replacements.size() == 1:
		var replacement: Dictionary = replacements[0]
		var new_instance := str(replacement.context.instance_id)
		_check(Array(backend.runtime_object().call("instance_log_codes", new_instance)) ==
				[201, 205], "corrected JS instance creates and mounts exactly once")
		var persisted: PackedByteArray = replacement.context.services.wasm_host_call(
				"state.read", 0, "persisted".to_utf8_buffer(), [])
		_check(JSON.parse_string(persisted.get_string_from_utf8()) == 41,
				"module-scoped state survives TypeScript reload")

	backend.close()
	component.free()
	print("VRWEB_MAKER_WASM_RELOAD PASS" if not _failed else "VRWEB_MAKER_WASM_RELOAD FAIL")
	quit(1 if _failed else 0)


func _unpack(bytes: PackedByteArray) -> Dictionary:
	var cached := ScriptingModuleCache.store(bytes)
	if not bool(cached.get("ok", false)): return {}
	var unpacked := ScriptingModulePackage.unpack({
		"id": MODULE_ID, "hash": cached.hash, "cache_path": cached.path})
	return unpacked.module if bool(unpacked.get("ok", false)) else {}


func _initial_source() -> String:
	return """import { core, state } from \"@vrweb/sdk\";

export function create(): number { core.logCode(101); return 1; }
export function mount(_instance: number): number { core.logCode(102); return 0; }
export function event(_instance: number, _envelope: Uint8Array): number {
  state.command({ key: \"persisted\", command: \"set\", value: 41 });
  core.logCode(103);
  return 0;
}
export function unmount(_instance: number): number { core.logCode(104); return 0; }
"""


func _replacement_source() -> String:
	return """import { core, state } from \"@vrweb/sdk\";

export function create(): number { core.logCode(201); return 1; }
export function mount(_instance: number): number {
  core.logCode(state.read(\"persisted\") === 41 ? 205 : -205);
  return 0;
}
export function event(_instance: number, _envelope: Uint8Array): number {
  core.logCode(203);
  return 0;
}
export function unmount(_instance: number): number { core.logCode(204); return 0; }
"""


func _write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write " + path)
		return
	file.store_string(content)
	file.close()


func _check(ok: bool, label: String) -> void:
	if ok: print("  [ok]  ", label)
	else: _fail(label)


func _fail(message: String) -> void:
	_failed = true
	push_error("FAIL: " + message)
