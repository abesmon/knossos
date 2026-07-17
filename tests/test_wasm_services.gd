extends SceneTree

var _failed := false


func _initialize() -> void:
	var module := {"manifest": {"assets": {
		"icon": {"path": "assets/icon.png", "type": "image/png"},
	}}}
	var services := WasmModuleServices.new("example.module", module,
		["vrweb:assets/1", "vrweb:timers/1"])
	_eq(services.wasm_host_call("features.has", 0,
			"vrweb:assets/1".to_utf8_buffer(), []), true, "declared host feature visible")
	_eq(services.wasm_host_call("features.has", 0,
			"wasi:filesystem".to_utf8_buffer(), []), false, "ambient feature absent")
	var asset: Variant = services.wasm_host_call("assets.lookup", 0,
			"icon".to_utf8_buffer(), [])
	_eq(asset is PackedByteArray, true, "declared asset resolves")
	if asset is PackedByteArray:
		_eq(JSON.parse_string(asset.get_string_from_utf8()).uri,
				"vrweb-asset://example.module/icon", "asset exposes logical URI only")
	_eq(services.wasm_host_call("assets.lookup", 0, "missing".to_utf8_buffer(), []),
			"asset_not_found", "undeclared asset rejected")

	var subscription := int(services.wasm_host_call("state.subscribe", 0,
			"light".to_utf8_buffer(), []))
	var set_command := {"key": "light", "command": "set", "value": true}
	_eq(services.wasm_host_call("state.command", 0,
			JSON.stringify(set_command).to_utf8_buffer(), []), PackedByteArray(),
			"namespaced state command accepted")
	_eq(JSON.parse_string((services.wasm_host_call("state.read", 0,
			"light".to_utf8_buffer(), []) as PackedByteArray).get_string_from_utf8()), true,
			"namespaced state read returns value")
	var state_events := services.drain_events()
	_eq(state_events.size(), 1, "state subscription queues event")
	_eq(int(state_events[0].subscription), subscription, "state event identifies subscription")

	var timer_id := int(services.wasm_host_call("timers.start", 0,
			JSON.stringify({"delay_ms": 10, "repeat": false}).to_utf8_buffer(), []))
	services.poll(Time.get_ticks_msec() + 20)
	var timer_events := services.drain_events()
	_eq(timer_events.size(), 1, "lifecycle timer queues event")
	_eq(int(timer_events[0].timer), timer_id, "timer event identifies timer")

	_eq(services.wasm_host_call("input.enable", 0,
			JSON.stringify({"kind": "activate", "enabled": true}).to_utf8_buffer(), []),
			PackedByteArray(), "portable input enabled")
	_eq(services.enqueue_input("activate", {"pressed": true}), true,
			"enabled input normalized into queue")
	_eq(services.drain_events()[0].kind, "input", "portable input event queued")
	var oversized_log := PackedByteArray()
	oversized_log.resize(WasmModuleServices.MAX_LOG_BYTES + 1)
	_eq(services.wasm_host_call("log.write", 0, oversized_log, []), "log_too_large",
			"oversized guest log rejected before parsing")
	_eq(services.wasm_host_call("features.has", 0, PackedByteArray([255]), []), false,
			"invalid UTF-8 cannot become a feature name or engine diagnostic flood")
	services.close()
	_eq(services.wasm_host_call("state.read", 0, "light".to_utf8_buffer(), []),
			"instance_stopped", "services reject callbacks after close")
	quit(1 if _failed else 0)


func _eq(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
