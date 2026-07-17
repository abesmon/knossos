extends SceneTree

var _failed := false


func _initialize() -> void:
	var modules := [
		{"id": "z.module", "hash": "bbb", "manifest": {
			"runtime": "wasm-component", "world": "vrweb:module@1"}},
		{"id": "a.module", "hash": "aaa", "manifest": {
			"runtime": "wasm-component", "world": "vrweb:module@1.0.0"}},
	]
	var identity: Array[Dictionary] = ScriptingModuleIdentity.canonical(modules)
	_eq(identity[0].id, "a.module", "module identity is ordered by id")
	_eq(identity[0].world_major, 1, "world major is normalized")
	var reversed_modules := modules.duplicate()
	reversed_modules.reverse()
	_eq(ScriptingModuleIdentity.canonical(reversed_modules), identity,
			"input order does not change identity")
	_eq(ScriptingModuleIdentity.room_key("page", identity),
			ScriptingModuleIdentity.room_key("page", identity), "room key is deterministic")
	_eq(ScriptingModuleIdentity.compare(identity, identity).outcome, "compatible",
			"exact identity is compatible")
	_eq(ScriptingModuleIdentity.compare(identity, identity, false).outcome, "degraded",
			"missing local runtime is explicit degradation")
	var changed: Array = identity.duplicate(true)
	changed[0].hash = "different"
	_eq(ScriptingModuleIdentity.compare(identity, changed).outcome, "rejected",
			"different component hash is rejected")
	_eq(ScriptingModuleIdentity.required_capabilities(modules), [],
			"empty module requirements normalize")
	var gate := ScriptingModulePeerGate.new()
	gate.configure(identity, true, ["vrweb:scene/1"],
			NativeWasmBackend.HOST_CAPABILITIES)
	_eq(gate.result_for(7).outcome, "pending", "late peer waits for descriptor")
	var compatible := gate.descriptor()
	_eq(gate.accept(7, compatible).outcome, "compatible",
			"matching peer descriptor enables replicated state")
	_eq(gate.permits_replicated_state(7), true, "compatible peer passes replication gate")
	var mismatched := compatible.duplicate(true)
	mismatched.identity = changed
	_eq(gate.accept(8, mismatched).outcome, "rejected",
			"different peer artifact is rejected before replication")
	_eq(gate.permits_replicated_state(8), false, "mismatched peer cannot replicate state")
	var missing_runtime := compatible.duplicate(true)
	missing_runtime.runtime_available = false
	_eq(gate.accept(9, missing_runtime).outcome, "degraded",
			"peer without runtime degrades explicitly")
	var missing_capability := compatible.duplicate(true)
	missing_capability.capabilities = []
	_eq(gate.accept(10, missing_capability).code, "capability_unavailable",
			"partial capability peer degrades explicitly")
	gate.remove(7)
	_eq(gate.result_for(7).outcome, "pending", "reconnect requires a fresh descriptor")
	_eq(gate.accept(7, compatible).outcome, "compatible",
			"reconnected peer can complete handshake again")
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
