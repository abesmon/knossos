extends SceneTree

## Deterministic property campaign for the byte/value/handle sandbox boundary. A failing seed is
## printed and can be replayed locally with VRWEB_FUZZ_SEED=<integer>.

const DEFAULT_SEED := 0x565257454246555A
const VALUE_CASES := 4000
const BYTE_CASES := 4000
const HANDLE_CASES := 8000

var _failed := false
var _rng := RandomNumberGenerator.new()
var _seed := DEFAULT_SEED
var _multiplier := 1
var _value_cases := VALUE_CASES
var _byte_cases := BYTE_CASES
var _handle_cases := HANDLE_CASES


func _initialize() -> void:
	if OS.has_environment("VRWEB_FUZZ_SEED"):
		_seed = int(OS.get_environment("VRWEB_FUZZ_SEED"))
	if OS.has_environment("VRWEB_FUZZ_MULTIPLIER"):
		_multiplier = clampi(int(OS.get_environment("VRWEB_FUZZ_MULTIPLIER")), 1, 100)
	_value_cases *= _multiplier
	_byte_cases *= _multiplier
	_handle_cases *= _multiplier
	_rng.seed = _seed
	print("VRWEB_WASM_VALUE_FUZZ seed=%d" % _seed)
	_fuzz_valid_round_trips()
	_fuzz_untrusted_bytes()
	_fuzz_malformed_values()
	_fuzz_handles()
	print("VRWEB_WASM_VALUE_FUZZ %s cases=%d" % [
			"FAIL" if _failed else "PASS", _value_cases * 2 + _byte_cases + _handle_cases])
	quit(1 if _failed else 0)


func _fuzz_valid_round_trips() -> void:
	for case_index in _value_cases:
		var value: Variant = _random_value(0)
		var encoded := WasmValueCodec.encode_bytes(value)
		_check(bool(encoded.ok), "encode", case_index)
		if not bool(encoded.ok): continue
		var decoded := WasmValueCodec.decode_bytes(encoded.value)
		_check(bool(decoded.ok), "decode", case_index)
		if bool(decoded.ok): _check(decoded.value == value, "round_trip", case_index)


func _fuzz_untrusted_bytes() -> void:
	var explicit := [PackedByteArray([0xff]), PackedByteArray([0xc0, 0xaf]),
		PackedByteArray([0xed, 0xa0, 0x80]), PackedByteArray([0xf4, 0x90, 0x80, 0x80])]
	for bytes in explicit:
		_check(WasmValueCodec.decode_bytes(bytes).error == "invalid_utf8", "invalid_utf8", 0)
	for case_index in _byte_cases:
		var bytes := PackedByteArray()
		bytes.resize(_rng.randi_range(0, 512))
		for index in bytes.size(): bytes[index] = _rng.randi_range(0, 255)
		var result := WasmValueCodec.decode_bytes(bytes)
		_check(result is Dictionary and result.has("ok") and result.has("error"),
				"bounded_byte_result", case_index)
	_check(WasmValueCodec.decode({"t": "bytes", "v": "%%%"}).error == "malformed_bytes",
			"malformed_base64", 0)


func _fuzz_malformed_values() -> void:
	var too_deep: Variant = {"t": "null"}
	for _index in WasmValueCodec.MAX_DEPTH + 2:
		too_deep = {"t": "array", "v": [too_deep]}
	_check(not bool(WasmValueCodec.decode(too_deep).ok), "depth_limit", 0)
	var too_many: Array = []
	for _index in WasmValueCodec.MAX_ITEMS + 1: too_many.append({"t": "null"})
	_check(WasmValueCodec.decode({"t": "array", "v": too_many}).error == "max_items",
			"item_limit", 0)
	for case_index in _value_cases:
		var candidate := {"t": _random_ascii(_rng.randi_range(0, 12)),
			"v": _random_value(0)}
		var result := WasmValueCodec.decode(candidate)
		_check(result is Dictionary and result.has("ok") and result.has("error"),
				"bounded_value_result", case_index)


func _fuzz_handles() -> void:
	var handles := WasmHandleTable.new()
	var live: Dictionary = {}
	var stale: Array[int] = []
	for case_index in _handle_cases:
		if live.is_empty() or _rng.randf() < 0.58:
			var value := {"case": case_index, "nonce": _rng.randi()}
			var handle := handles.create(value, "module-a", "page-a", "value")
			live[handle] = value
			_check(bool(handles.resolve(handle, "module-a", "page-a", "value").ok),
					"live_handle", case_index)
			_check(handles.resolve(handle, "module-b", "page-a").error == "foreign_owner",
					"foreign_owner", case_index)
			_check(handles.resolve(handle, "module-a", "page-b").error == "foreign_page",
					"foreign_page", case_index)
		else:
			var keys := live.keys()
			var handle := int(keys[_rng.randi_range(0, keys.size() - 1)])
			_check(handles.invalidate(handle), "invalidate", case_index)
			live.erase(handle)
			stale.append(handle)
			_check(handles.resolve(handle, "module-a", "page-a").error == "stale_handle",
					"stale_handle", case_index)
		var forged := int(_rng.randi()) | (int(_rng.randi()) << 32)
		if not live.has(forged):
			_check(not bool(handles.resolve(forged, "module-a", "page-a").ok),
					"forged_handle", case_index)
	for handle in stale:
		_check(not bool(handles.resolve(handle, "module-a", "page-a").ok),
				"stale_never_revives", handle)
	_check(handles.size() == live.size(), "live_count", _handle_cases)
	handles.invalidate_scope("module-a", "page-a")
	_check(handles.size() == 0, "scope_cleanup", _handle_cases)


func _random_value(depth: int) -> Variant:
	var kind := _rng.randi_range(0, 10 if depth < 4 else 5)
	match kind:
		0: return null
		1: return bool(_rng.randi() & 1)
		2: return _rng.randi_range(-1_000_000_000, 1_000_000_000)
		3: return _rng.randf_range(-1_000_000.0, 1_000_000.0)
		4: return _random_ascii(_rng.randi_range(0, 80))
		5:
			var bytes := PackedByteArray()
			bytes.resize(_rng.randi_range(0, 96))
			for index in bytes.size(): bytes[index] = _rng.randi_range(0, 255)
			return bytes
		6:
			var result: Array = []
			for _index in _rng.randi_range(0, 6): result.append(_random_value(depth + 1))
			return result
		7:
			var result := {}
			for index in _rng.randi_range(0, 6):
				result["k%d_%s" % [index, _random_ascii(4)]] = _random_value(depth + 1)
			return result
		8: return Vector3(_finite_float(), _finite_float(), _finite_float())
		9: return Color(_finite_float(), _finite_float(), _finite_float(), _finite_float())
		_: return Transform3D(Basis.IDENTITY, Vector3(_finite_float(), _finite_float(), _finite_float()))


func _finite_float() -> float:
	return _rng.randf_range(-1000.0, 1000.0)


func _random_ascii(length: int) -> String:
	var result := ""
	for _index in length: result += char(_rng.randi_range(32, 126))
	return result


func _check(ok: bool, property: String, case_index: int) -> void:
	if ok: return
	_failed = true
	push_error("VRWEB_WASM_VALUE_FUZZ seed=%d property=%s case=%d" % [
			_seed, property, case_index])
