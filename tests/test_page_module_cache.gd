extends SceneTree

var _failed := false


func _initialize() -> void:
	var bytes := "module cache fixture".to_utf8_buffer()
	var stored := PageModuleCache.store(bytes)
	_eq(stored.ok, true, "artifact stored")
	_eq(PageModuleCache.valid_hash(stored.hash), true, "cache key is SHA-256")
	_eq(PageModuleCache.read(stored.hash), bytes, "artifact loads by content hash")
	var again := PageModuleCache.store(bytes)
	_eq(again.hash, stored.hash, "same bytes deduplicate")
	_eq(PageModuleCache.read("bad").is_empty(), true, "invalid key rejected")
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
