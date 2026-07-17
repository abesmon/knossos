extends SceneTree

var _failed := false
var _scene_host_calls := 0


func _initialize() -> void:
	_eq(NativeWasmBackend.is_available(), true, "native WASM backend detected")
	if not NativeWasmBackend.is_available():
		quit(1)
		return
	var runtime: Object = ClassDB.instantiate("VrwebWasmRuntime")
	_eq(bool(runtime.call("is_available")), true, "Wasmtime engine initialized")
	_eq(str(runtime.call("runtime_version")), "wasmtime-46.0.1", "runtime version pinned")
	var answer_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/answer.wasm")
	_eq(bool(runtime.call("prepare_component", "answer", answer_path)), true,
			"valid component prepared")
	for iteration in 100:
		_eq(int(runtime.call("call_i32", "answer", "answer")), 42,
				"answer call %d" % iteration)
		_eq(int(runtime.call("live_store_count")), 0, "store dropped after call %d" % iteration)
	_eq(int(runtime.call("component_count")), 1, "compiled component retained")
	_eq(bool(runtime.call("drop_component", "answer")), true, "component dropped")
	_eq(int(runtime.call("component_count")), 0, "component table empty")

	var invalid_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/invalid.wasm")
	_eq(bool(runtime.call("prepare_component", "invalid", invalid_path)), false,
			"invalid component rejected")
	_eq(str(runtime.call("get_last_error")).contains("invalid WebAssembly component"), true,
			"invalid component diagnostic preserved")

	var package_bytes := FileAccess.get_file_as_bytes("res://test_pages/lights.vrmod")
	var cached := ScriptingModuleCache.store(package_bytes)
	var unpacked := ScriptingModulePackage.unpack({
		"id": "external.tiny", "hash": cached.hash, "cache_path": cached.path,
	})
	_eq(unpacked.ok, true, "delivery package unpacked")
	if bool(unpacked.ok):
		var backend := NativeWasmBackend.new()
		_eq(backend.prepare([unpacked.module]).ok, true,
				"native backend prepares delivered component")
		_eq(int(backend.runtime_object().call("component_count")), 1,
				"backend owns compiled component")
		var made := backend.instantiate_export("external.tiny", "default")
		_eq(str(made.error), "", "lifecycle scene export instantiated")
		if made.node != null:
			_eq(str(made.context.module_hash), str(unpacked.module.hash),
					"instance context exposes content hash without host path")
			get_root().add_child(made.node)
			var instance_id := str(made.context.instance_id)
			_eq(Array(backend.runtime_object().call("instance_log_codes", instance_id)), [1, 2],
					"create and mount order recorded")
			_eq(backend.deliver_event("external.tiny", {"code": 9}).ok, true,
					"event delivered")
			_eq(Array(backend.runtime_object().call("instance_log_codes", instance_id)), [1, 2, 123],
					"serialized event envelope follows mount")
			made.node.free()
			_eq(Array(backend.runtime_object().call("instance_log_codes", instance_id)),
					[1, 2, 123, 4], "tree exit invokes one unmount")
			_eq(bool(backend.runtime_object().call("deliver_event_code", instance_id, 10)), false,
					"event after unmount rejected")
			_eq(bool(backend.runtime_object().call("unmount_instance", instance_id)), false,
					"duplicate unmount is idempotently rejected without guest callback")
		backend.close()
		_eq(int(backend.runtime_object().call("component_count")), 0,
				"backend close releases components")
	var diagnostic_backend := NativeWasmBackend.new()
	var diagnostic_prepare := diagnostic_backend.prepare([{
		"id": "fixture.missing", "hash": "abc123", "base_url": "https://example.test/world/",
		"component_path": "",
	}])
	_eq(diagnostic_prepare.diagnostics[0].code, "component_path_missing",
			"prepare diagnostic has stable code")
	_eq(diagnostic_prepare.diagnostics[0].module, "fixture.missing",
			"prepare diagnostic identifies module")
	_eq(diagnostic_prepare.diagnostics[0].origin, "https://example.test/world/",
			"prepare diagnostic identifies origin")
	_eq(diagnostic_prepare.diagnostics[0].hash, "abc123",
			"prepare diagnostic identifies content hash")
	_eq(diagnostic_prepare.diagnostics[0].has("guest_stack"), true,
			"diagnostic schema includes bounded guest stack")
	_eq(diagnostic_prepare.diagnostics[0].has("source_location"), true,
			"diagnostic schema includes source location")
	_eq(diagnostic_prepare.diagnostics[0].has("debug_sidecar"), true,
			"diagnostic schema includes logical debug sidecar only")
	var missing_instance := diagnostic_backend.instantiate_export("fixture.missing", "default")
	_eq(missing_instance.diagnostic.code, "module_not_prepared",
			"instantiate failure has stable diagnostic code")
	diagnostic_backend.close()

	var signature_module := {"manifest": {
		"exports": {"Door": {"kind": "scene-component"}},
		"requires": ["vrweb:scene/1"], "optional": ["vrweb:state/1"],
	}}
	_eq(NativeWasmBackend.validate_signature(
		["vrweb:scene/host@1.0.0"], ["create", "mount", "event", "unmount"], signature_module,
		["vrweb:scene/1"]), [], "declared compatible import accepted")
	_eq(NativeWasmBackend.validate_signature(
		["wasi:filesystem/types@0.2.0"], ["create", "mount", "event", "unmount"], signature_module, []).size(), 1,
		"WASI import rejected")
	_eq(NativeWasmBackend.validate_signature(
		["vendor:secret/api@1.0.0"], ["create", "mount", "event", "unmount"], signature_module, []).size(), 1,
		"unknown import rejected")
	_eq(NativeWasmBackend.validate_signature(
		["vrweb:input/host@1.0.0"], ["create", "mount", "event", "unmount"], signature_module,
		["vrweb:input/1"]).size(), 1, "hidden import rejected")
	_eq(NativeWasmBackend.validate_signature(
		["vrweb:scene/host@2.0.0"], ["create", "mount", "event", "unmount"], signature_module,
		["vrweb:scene/1"]).size(), 1, "incompatible major rejected")
	_eq(NativeWasmBackend.validate_signature([], [], signature_module, []).size(), 4,
		"missing lifecycle world exports rejected")
	var scene_lifecycle_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/scene_lifecycle.wasm")
	_eq(bool(runtime.call("prepare_component", "scene-lifecycle", scene_lifecycle_path)), true,
			"scene WIT lifecycle component prepared")
	_eq(str(runtime.call("get_last_error")), "", "scene WIT component validates")
	_eq(bool(runtime.call("instantiate_lifecycle_with_host", "scene-lifecycle",
			"scene-instance", Callable(self, "_scene_host_probe"))), true,
			"scene WIT imports link to scoped host callback")
	_eq(_scene_host_calls, 2, "guest scene and feature calls cross WIT boundary")
	_eq(bool(runtime.call("unmount_instance", "scene-instance")), true,
			"scene WIT lifecycle unmounted")
	runtime.call("drop_component", "scene-lifecycle")
	var scene_backend := NativeWasmBackend.new()
	var scene_module := {
		"id": "fixture.scene", "component_path": scene_lifecycle_path,
		"hash": "fixture-page", "exports": {"default": {"kind": "scene-component"}},
		"manifest": {"requires": ["vrweb:scene/1", "vrweb:features/1"],
			"exports": {"default": {"kind": "scene-component"}}},
	}
	_eq(bool(scene_backend.prepare([scene_module]).ok), true,
			"scene fixture accepted by capability policy")
	var scene_made := scene_backend.instantiate_export("fixture.scene", "default")
	_eq(str(scene_made.error), "", "guest query reaches real SceneAuthority")
	if scene_made.node != null:
		_eq(int(scene_made.context.scene_root_handle) > 0, true,
				"real SceneAuthority publishes scoped root")
		scene_made.node.free()
	scene_backend.close()

	var portable_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/portable_services.wasm")
	var portable_backend := NativeWasmBackend.new()
	var portable_module := {
		"id": "fixture.portable", "component_path": portable_path,
		"hash": "portable-page", "exports": {"default": {"kind": "scene-component"}},
		"manifest": {
			"requires": ["vrweb:core/1", "vrweb:state/1", "vrweb:assets/1",
				"vrweb:timers/1", "vrweb:input/1", "vrweb:features/1", "vrweb:log/1"],
			"exports": {"default": {"kind": "scene-component"}},
			"assets": {"icon": {"path": "assets/icon.png", "type": "image/png"}},
		},
	}
	_eq(bool(portable_backend.prepare([portable_module]).ok), true,
			"portable WIT imports accepted by capability policy")
	var portable_made := portable_backend.instantiate_export("fixture.portable", "default")
	_eq(str(portable_made.error), "", "guest calls portable services during create")
	if portable_made.node != null:
		var portable_instance := str(portable_made.context.instance_id)
		_eq(Array(portable_backend.runtime_object().call(
				"instance_log_codes", portable_instance)), [13],
				"portable guest reached end of all host calls")
		var portable_services: WasmModuleServices = portable_made.context.services
		var portable_state: PackedByteArray = portable_services.wasm_host_call(
				"state.read", 0, "light".to_utf8_buffer(), [])
		_eq(JSON.parse_string(portable_state.get_string_from_utf8()), true,
				"guest state command changed module-scoped state")
		_eq(portable_services.conformance_trace(), ["features.has", "assets.lookup",
				"state.command", "state.read", "state.subscribe", "state.unsubscribe",
				"timers.start", "input.enable", "log.write", "state.read"],
				"portable guest matches canonical host-call trace")
		portable_services.poll(Time.get_ticks_msec() + 20)
		_eq(portable_services.drain_events()[0].kind, "timer",
				"guest-created timer produces lifecycle event")
		_eq(portable_services.enqueue_input("activate", {"pressed": true}), true,
				"guest enabled portable input through WIT")
		portable_made.node.free()
	portable_backend.close()

	var reload_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/lifecycle.wasm")
	var reload_backend := NativeWasmBackend.new()
	var reload_module := {
		"id": "fixture.reload", "component_path": reload_path, "hash": "reload-initial",
		"exports": {"default": {"kind": "scene-component"}},
		"manifest": {"requires": ["vrweb:core/1"],
			"exports": {"default": {"kind": "scene-component"}}},
	}
	_eq(reload_backend.prepare([reload_module]).ok, true, "reload fixture prepared")
	var reload_made := reload_backend.instantiate_export("fixture.reload", "default")
	_eq(str(reload_made.error), "", "reload fixture instantiated")
	if reload_made.node != null:
		get_root().add_child(reload_made.node)
		var old_reload_instance := str(reload_made.context.instance_id)
		var state_command := JSON.stringify({"key": "persisted", "command": "set",
			"value": 41}).to_utf8_buffer()
		reload_made.context.services.wasm_host_call(
				"state.command", 0, state_command, [])
		var broken_reload := reload_module.duplicate(true)
		broken_reload.component_path = invalid_path
		broken_reload.hash = "reload-broken"
		_eq(reload_backend.reload_module(broken_reload).ok, false,
				"compile error preserves running reload instance")
		_eq(reload_backend.deliver_event("fixture.reload", {"kind": "probe"}).ok, true,
				"old instance still runs after rejected reload")
		var updated_reload := reload_module.duplicate(true)
		updated_reload.hash = "reload-replacement"
		var reloaded := reload_backend.reload_module(updated_reload)
		_eq(reloaded.ok, true, "validated component reload succeeds")
		_eq(reloaded.old_hash, "reload-initial", "reload reports old artifact hash")
		_eq(reloaded.new_hash, "reload-replacement", "reload reports new artifact hash")
		_eq(reloaded.replacements.size(), 1, "reload replaces every live instance once")
		_eq(Array(reload_backend.runtime_object().call(
				"instance_log_codes", old_reload_instance)), [1, 2, 123, 4],
				"reload unmounts old instance exactly once")
		if not reloaded.replacements.is_empty():
			var replacement: Dictionary = reloaded.replacements[0]
			var new_reload_instance := str(replacement.context.instance_id)
			_eq(Array(reload_backend.runtime_object().call(
					"instance_log_codes", new_reload_instance)), [1, 2],
					"reload creates and mounts replacement exactly once")
			_eq(str(replacement.context.module_hash), "reload-replacement",
					"replacement context exposes new artifact hash")
			var persisted: PackedByteArray = replacement.context.services.wasm_host_call(
					"state.read", 0, "persisted".to_utf8_buffer(), [])
			_eq(JSON.parse_string(persisted.get_string_from_utf8()), 41,
					"vrweb state persists while guest-local memory is replaced")
			replacement.node.free()
	reload_backend.close()

	_test_import_fixture(runtime, "wasi_import", signature_module, [], "WASI fixture rejected")
	_test_import_fixture(runtime, "unknown_import", signature_module, [],
			"unknown import fixture rejected")
	_test_import_fixture(runtime, "scene_import_unavailable", signature_module, [],
			"unavailable required import fixture rejected")
	_test_import_fixture(runtime, "scene_import_incompatible_major", signature_module,
			["vrweb:scene/1"], "major mismatch fixture rejected")
	var core_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/core_module.wasm")
	_eq(bool(runtime.call("prepare_component", "core", core_path)), false,
			"core module rejected instead of component")

	for hostile in ["infinite_loop", "memory_grow", "table_grow", "trap"]:
		var hostile_path := ProjectSettings.globalize_path(
				"res://native/vrweb_wasm_runtime/fixtures/%s.wasm" % hostile)
		_eq(bool(runtime.call("prepare_component", hostile, hostile_path)), true,
				"%s prepared" % hostile)
		var started := Time.get_ticks_msec()
		runtime.call("call_i32", hostile, "run")
		_eq(Time.get_ticks_msec() - started < 1000, true, "%s stopped within deadline" % hostile)
		_eq(str(runtime.call("get_last_error")).is_empty(), false,
				"%s reports bounded failure" % hostile)
		_eq(int(runtime.call("live_store_count")), 0, "%s store released" % hostile)
		_eq(bool(runtime.call("drop_component", hostile)), true, "%s component dropped" % hostile)
		_eq(bool(runtime.call("prepare_component", "answer-after-hostile", answer_path)), true,
				"healthy component prepares after %s" % hostile)
		_eq(int(runtime.call("call_i32", "answer-after-hostile", "answer")), 42,
				"healthy component runs after %s" % hostile)
		runtime.call("drop_component", "answer-after-hostile")

	for phase in ["create", "mount"]:
		var phase_fixture := "lifecycle_trap_%s" % phase
		var phase_path := ProjectSettings.globalize_path(
				"res://native/vrweb_wasm_runtime/fixtures/%s.wasm" % phase_fixture)
		_eq(bool(runtime.call("prepare_component", phase_fixture, phase_path)), true,
				"%s lifecycle trap prepared" % phase)
		_eq(bool(runtime.call("instantiate_lifecycle", phase_fixture,
				"%s-trap-instance" % phase)), false,
				"exception in %s stops lifecycle" % phase)
		_eq(str(runtime.call("get_last_error")).contains("lifecycle instantiation failed"), true,
				"%s exception has bounded diagnostic" % phase)
		_eq(int(runtime.call("live_store_count")), 0,
				"%s exception releases store" % phase)
		runtime.call("drop_component", phase_fixture)
	var event_unmount_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/lifecycle_trap_event_unmount.wasm")
	_eq(bool(runtime.call("prepare_component", "lifecycle-trap-event-unmount",
			event_unmount_path)), true, "event/unmount lifecycle traps prepared")
	_eq(bool(runtime.call("instantiate_lifecycle", "lifecycle-trap-event-unmount",
			"event-trap-instance")), true, "event trap fixture mounted")
	_eq(bool(runtime.call("deliver_event_code", "event-trap-instance", 1)), false,
			"exception in event stops lifecycle")
	_eq(str(runtime.call("get_last_error")).contains("event failed"), true,
			"event exception has bounded diagnostic")
	_eq(bool(runtime.call("unmount_instance", "event-trap-instance")), true,
			"stopped event instance drops without another guest callback")
	_eq(bool(runtime.call("instantiate_lifecycle", "lifecycle-trap-event-unmount",
			"unmount-trap-instance")), true, "unmount trap fixture mounted")
	_eq(bool(runtime.call("unmount_instance", "unmount-trap-instance")), false,
			"exception in unmount still drops instance")
	_eq(str(runtime.call("get_last_error")).contains("unmount failed"), true,
			"unmount exception has bounded diagnostic")
	_eq(bool(runtime.call("unmount_instance", "unmount-trap-instance")), false,
			"failed unmount cannot execute twice")
	_eq(int(runtime.call("live_store_count")), 0,
			"event/unmount exceptions release stores")
	runtime.call("drop_component", "lifecycle-trap-event-unmount")

	var flood_path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/host_call_flood.wasm")
	_eq(bool(runtime.call("prepare_component", "flood", flood_path)), true,
			"host-call flood prepared")
	_eq(bool(runtime.call("instantiate_lifecycle", "flood", "flood-instance")), true,
			"host-call flood mounted")
	_eq(bool(runtime.call("deliver_event_code", "flood-instance", 1)), false,
			"host-call flood stopped")
	_eq(str(runtime.call("get_last_error")).contains("host call budget exceeded"), true,
			"host-call budget diagnostic preserved")
	_eq(Array(runtime.call("instance_log_codes", "flood-instance")).size(), 64,
			"host-call log bounded")
	_eq(bool(runtime.call("deliver_event_code", "flood-instance", 2)), false,
			"stopped flood receives no later callback")
	runtime.call("unmount_instance", "flood-instance")
	_eq(bool(runtime.call("instantiate_lifecycle_with_host_limits", "flood",
			"limited-flood-instance", Callable(self, "_scene_host_probe"),
			1_000_000, 16 * 1024 * 1024, 50, 2, 16, 16, 8)), true,
			"manifest-style reduced limits accepted")
	_eq(bool(runtime.call("deliver_event_code", "limited-flood-instance", 1)), false,
			"per-instance host-call hint stops guest")
	_eq(Array(runtime.call("instance_log_codes", "limited-flood-instance")).size(), 2,
			"per-instance host-call hint is enforced")
	runtime.call("unmount_instance", "limited-flood-instance")
	_eq(bool(runtime.call("instantiate_lifecycle_with_host_limits", "flood",
			"oversized-limit-instance", Callable(self, "_scene_host_probe"),
			50_000_001, 16 * 1024 * 1024, 50, 64, 16, 16, 8)), false,
			"instance cannot enlarge local fuel policy")
	_eq(str(runtime.call("get_last_error")).contains("invalid runtime limits"), true,
			"invalid limit reports stable pre-instantiation error")
	runtime.call("drop_component", "flood")
	quit(1 if _failed else 0)


func _test_import_fixture(runtime: Object, fixture: String, module: Dictionary,
		provided: Array[String], label: String) -> void:
	var path := ProjectSettings.globalize_path(
			"res://native/vrweb_wasm_runtime/fixtures/%s.wasm" % fixture)
	_eq(bool(runtime.call("prepare_component", fixture, path)), true,
			"%s compiles as component" % fixture)
	var imports := Array(runtime.call("component_imports", fixture))
	_eq(NativeWasmBackend.validate_signature(imports,
			["create", "mount", "event", "unmount"], module, provided).is_empty(),
			false, label)
	runtime.call("drop_component", fixture)


func _scene_host_probe(operation: String, _id: int, _payload: PackedByteArray,
		_nested: Array) -> Variant:
	_scene_host_calls += 1
	if operation == "features.has": return true
	return PackedByteArray([49])


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
