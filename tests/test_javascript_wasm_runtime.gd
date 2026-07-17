extends SceneTree

var _failed := false


func _initialize() -> void:
	_eq(NativeWasmBackend.is_available(), true, "native WASM backend detected")
	var package_path := "res://sdk/javascript/dist/lifecycle.vrmod"
	_eq(FileAccess.file_exists(package_path), true, "pinned JavaScript toolchain produced .vrmod")
	if not NativeWasmBackend.is_available() or not FileAccess.file_exists(package_path):
		quit(1)
		return
	var cached := ScriptingModuleCache.store(FileAccess.get_file_as_bytes(package_path))
	var unpacked := ScriptingModulePackage.unpack({
		"id": "vrweb.example.javascript-lifecycle",
		"hash": cached.hash,
		"cache_path": cached.path,
	})
	_eq(unpacked.ok, true, "JavaScript package passes normal delivery validation")
	if not bool(unpacked.ok):
		quit(1)
		return
	_eq(unpacked.module.manifest.sdk, "1.0.0", "package records SDK version")
	var rust_package_path := "res://sdk/rust/dist/conformance.vrmod"
	_eq(FileAccess.file_exists(rust_package_path), true,
			"pinned Rust toolchain produced conformance .vrmod")
	if not FileAccess.file_exists(rust_package_path):
		quit(1)
		return
	var rust_cached := ScriptingModuleCache.store(FileAccess.get_file_as_bytes(rust_package_path))
	var rust_unpacked := ScriptingModulePackage.unpack({
		"id": "vrweb.example.rust-conformance",
		"hash": rust_cached.hash,
		"cache_path": rust_cached.path,
	})
	_eq(rust_unpacked.ok, true, "Rust oracle passes normal delivery validation")
	if not bool(rust_unpacked.ok):
		quit(1)
		return
	_eq(rust_unpacked.module.manifest.sdk, "1.0.0", "Rust package records SDK version")
	var backend := NativeWasmBackend.new()
	var prepare_started := Time.get_ticks_msec()
	var prepared := backend.prepare([unpacked.module, rust_unpacked.module])
	var prepare_ms := Time.get_ticks_msec() - prepare_started
	_eq(prepared.ok, true, "ComponentizeJS output passes the same import policy")
	if bool(prepared.ok):
		var instantiate_started := Time.get_ticks_msec()
		var made := backend.instantiate_export("vrweb.example.javascript-lifecycle", "default")
		var instantiate_ms := Time.get_ticks_msec() - instantiate_started
		_eq(str(made.error), "", "JavaScript lifecycle instance created")
		_eq(made.node != null, true, "JavaScript lifecycle returns a scene node")
		if made.node != null:
			get_root().add_child(made.node)
			var instance_id := str(made.context.instance_id)
			var javascript_host: WasmHostContext = made.context.host_context
			_eq(Array(backend.runtime_object().call("instance_log_codes", instance_id)),
					[81, 82, 83, 84, 71, 72],
					"JavaScript has no browser/Node globals and crosses WIT ABI")
			var light_trace_start := javascript_host.conformance_trace().size()
			var event_started := Time.get_ticks_usec()
			_eq(backend.deliver_event("vrweb.example.javascript-lifecycle",
					{"kind": "activate", "value": {"pressed": true}}).ok, true,
					"event reaches JavaScript guest")
			var event_us := Time.get_ticks_usec() - event_started
			var javascript_light_trace := javascript_host.conformance_trace().slice(
					light_trace_start)
			_eq(javascript_light_trace, ["scene.query", "scene.mutate", "scene.commit",
					"state.command", "state.read"],
					"TypeScript LightSwitch crosses the canonical host operations")
			_eq(Array(backend.runtime_object().call("instance_log_codes", instance_id)),
					[81, 82, 83, 84, 71, 72, 73], "JavaScript event observes WIT byte envelope")
			made.node.free()
			var javascript_logs := Array(backend.runtime_object().call(
					"instance_log_codes", instance_id))
			_eq(javascript_logs,
					[81, 82, 83, 84, 71, 72, 73, 74], "JavaScript unmount completes lifecycle")
			var rust_made := backend.instantiate_export(
					"vrweb.example.rust-conformance", "default")
			_eq(str(rust_made.error), "", "Rust conformance instance created")
			if rust_made.node != null:
				get_root().add_child(rust_made.node)
				var rust_instance := str(rust_made.context.instance_id)
				var rust_host: WasmHostContext = rust_made.context.host_context
				_eq(backend.deliver_event("vrweb.example.rust-conformance",
						{"kind": "activate", "value": {"pressed": true}}).ok, true,
						"event reaches Rust oracle")
				rust_made.node.free()
				var rust_logs := Array(backend.runtime_object().call(
						"instance_log_codes", rust_instance))
				_eq(rust_logs, [71, 72, 73, 74], "Rust oracle completes lifecycle")
				_eq(rust_host.conformance_trace(), javascript_light_trace,
						"Rust and TypeScript use the same Scene/state LightSwitch trace")
				_eq(_lifecycle_trace(javascript_logs), rust_logs,
						"TypeScript and Rust produce the same portable lifecycle trace")
			print("VRWEB_JS_BENCHMARK ", JSON.stringify({
				"component_bytes": FileAccess.get_file_as_bytes(
						"res://sdk/javascript/dist/module.wasm").size(),
				"cold_prepare_ms": prepare_ms,
				"cold_instantiate_ms": instantiate_ms,
				"event_us": event_us,
			}))
		var hostile := backend.instantiate_export("vrweb.example.javascript-lifecycle", "default")
		_eq(str(hostile.error), "", "second JavaScript instance created for hostile event")
		_eq(hostile.node != null, true, "hostile JavaScript instance returns a scene node")
		if hostile.node != null:
			get_root().add_child(hostile.node)
			var hostile_id := str(hostile.context.instance_id)
			var started := Time.get_ticks_msec()
			_eq(bool(backend.runtime_object().call("deliver_event_bytes", hostile_id,
					PackedByteArray([255]))), false, "JavaScript infinite loop is interrupted")
			_eq(Time.get_ticks_msec() - started < 1000, true,
					"hostile JavaScript stops within bounded deadline")
			hostile.node.free()
		var memory_hostile := backend.instantiate_export(
				"vrweb.example.javascript-lifecycle", "default")
		_eq(str(memory_hostile.error), "", "third JavaScript instance created for memory growth")
		if memory_hostile.node != null:
			get_root().add_child(memory_hostile.node)
			var memory_id := str(memory_hostile.context.instance_id)
			var memory_started := Time.get_ticks_msec()
			_eq(bool(backend.runtime_object().call("deliver_event_bytes", memory_id,
					PackedByteArray([254]))), false, "JavaScript memory growth is interrupted")
			_eq(Time.get_ticks_msec() - memory_started < 1000, true,
					"JavaScript memory growth stops within bounded deadline")
			memory_hostile.node.free()
		var source_map_hostile := backend.instantiate_export(
				"vrweb.example.javascript-lifecycle", "default")
		_eq(str(source_map_hostile.error), "", "debug JavaScript instance created")
		if source_map_hostile.node != null:
			get_root().add_child(source_map_hostile.node)
			var mapped_failure := backend.deliver_event(
					"vrweb.example.javascript-lifecycle", {"kind": "source-map-probe"})
			_eq(mapped_failure.ok, false, "JavaScript exception becomes structured diagnostic")
			if not mapped_failure.diagnostics.is_empty():
				var diagnostic: Dictionary = mapped_failure.diagnostics[-1]
				print("VRWEB_JS_SOURCE_MAP_DIAGNOSTIC ", JSON.stringify(diagnostic))
				_eq(str(diagnostic.source_location).contains("lifecycle.ts"), true,
						"debug exception maps to creator TypeScript source")
				_eq(str(diagnostic.source_location).contains(ProjectSettings.globalize_path("res://")),
						false, "mapped diagnostic does not expose checkout path")
				_eq(str(diagnostic.message).contains("/var/"), false,
						"JavaScript diagnostic removes adapter host paths")
			source_map_hostile.node.free()
		var oversized_error := backend.instantiate_export(
				"vrweb.example.javascript-lifecycle", "default")
		_eq(str(oversized_error.error), "", "JavaScript instance created for bounded diagnostic")
		if oversized_error.node != null:
			get_root().add_child(oversized_error.node)
			var oversized_failure := backend.deliver_event(
					"vrweb.example.javascript-lifecycle", {"kind": "oversized-error"})
			_eq(oversized_failure.ok, false, "oversized guest error becomes diagnostic")
			if not oversized_failure.diagnostics.is_empty():
				_eq(str(oversized_failure.diagnostics[-1].message).to_utf8_buffer().size() < 12 * 1024,
						true, "guest diagnostic text is bounded by host")
			oversized_error.node.free()
	backend.close()
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


func _lifecycle_trace(codes: Array) -> Array:
	return codes.filter(func(code: Variant) -> bool: return int(code) >= 71 and int(code) <= 74)
