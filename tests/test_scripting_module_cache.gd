extends SceneTree

var _failed := false


func _initialize() -> void:
	var bytes := "module cache fixture".to_utf8_buffer()
	var stored := ScriptingModuleCache.store(bytes)
	_eq(stored.ok, true, "artifact stored")
	_eq(ScriptingModuleCache.valid_hash(stored.hash), true, "cache key is SHA-256")
	_eq(ScriptingModuleCache.read(stored.hash), bytes, "artifact loads by content hash")
	var again := ScriptingModuleCache.store(bytes)
	_eq(again.hash, stored.hash, "same bytes deduplicate")
	_eq(ScriptingModuleCache.read("bad").is_empty(), true, "invalid key rejected")
	var first := {"id": "one", "runtime": "wasm-component", "world": "vrweb:module@1"}
	var second := first.duplicate()
	second.id = "two"
	var first_key := ScriptingModuleCache.execution_key(stored.hash, first)
	_eq(first_key.length(), 64, "execution cache key is SHA-256")
	_eq(ScriptingModuleCache.execution_key(stored.hash, first), first_key,
			"execution cache key is stable")
	_eq(ScriptingModuleCache.execution_key(stored.hash, second) != first_key, true,
			"same bytes under another module id do not alias execution cache")
	_eq(ScriptingModuleCache.execution_key("bad", first), "", "invalid artifact key rejected")
	var oversized := PackedByteArray()
	oversized.resize(ScriptingModuleCache.MAX_ARTIFACT_BYTES + 1)
	_eq(ScriptingModuleCache.store(oversized).error, "invalid_size",
			"oversized component rejected before cache write")
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
