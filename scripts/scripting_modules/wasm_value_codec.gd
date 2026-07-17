class_name WasmValueCodec
extends RefCounted

const MAX_DEPTH := 16
const MAX_ITEMS := 4096
const MAX_STRING_BYTES := 64 * 1024
const MAX_BYTE_BUFFER := 4 * 1024 * 1024


static func encode(value: Variant) -> Dictionary:
	var budget := {"items": 0}
	return _encode(value, 0, budget)


static func decode(value: Variant) -> Dictionary:
	var budget := {"items": 0}
	return _decode(value, 0, budget)


static func encode_bytes(value: Variant) -> Dictionary:
	var encoded := encode(value)
	if not bool(encoded.ok):
		return encoded
	return {"ok": true, "value": JSON.stringify(encoded.value).to_utf8_buffer(), "error": ""}


static func decode_bytes(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() > MAX_BYTE_BUFFER:
		return _error("buffer_too_large")
	if not is_valid_utf8(bytes):
		return _error("invalid_utf8")
	var text := bytes.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		return _error("malformed_json")
	return decode(json.data)


static func _encode(value: Variant, depth: int, budget: Dictionary) -> Dictionary:
	if depth > MAX_DEPTH:
		return _error("max_depth")
	budget.items = int(budget.items) + 1
	if int(budget.items) > MAX_ITEMS:
		return _error("max_items")
	match typeof(value):
		TYPE_NIL:
			return _ok({"t": "null"})
		TYPE_BOOL:
			return _ok({"t": "bool", "v": value})
		TYPE_INT:
			return _ok({"t": "i64", "v": str(value)})
		TYPE_FLOAT:
			if not is_finite(float(value)):
				return _error("non_finite_float")
			return _ok({"t": "f64", "v": value})
		TYPE_STRING, TYPE_STRING_NAME:
			var text := str(value)
			if text.to_utf8_buffer().size() > MAX_STRING_BYTES:
				return _error("string_too_large")
			return _ok({"t": "string", "v": text})
		TYPE_PACKED_BYTE_ARRAY:
			if value.size() > MAX_BYTE_BUFFER:
				return _error("buffer_too_large")
			return _ok({"t": "bytes", "v": "" if value.is_empty() \
					else Marshalls.raw_to_base64(value)})
		TYPE_ARRAY:
			var values: Array = []
			for item in value:
				var encoded := _encode(item, depth + 1, budget)
				if not bool(encoded.ok):
					return encoded
				values.append(encoded.value)
			return _ok({"t": "array", "v": values})
		TYPE_DICTIONARY:
			var keys: Array[String] = []
			for key in value:
				if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
					return _error("dictionary_key_not_string")
				keys.append(str(key))
			keys.sort()
			var entries: Array = []
			for key in keys:
				var encoded := _encode(value[key], depth + 1, budget)
				if not bool(encoded.ok):
					return encoded
				entries.append([key, encoded.value])
			return _ok({"t": "map", "v": entries})
		TYPE_VECTOR2:
			return _math("vec2", [value.x, value.y])
		TYPE_VECTOR3:
			return _math("vec3", [value.x, value.y, value.z])
		TYPE_VECTOR4:
			return _math("vec4", [value.x, value.y, value.z, value.w])
		TYPE_QUATERNION:
			return _math("quat", [value.x, value.y, value.z, value.w])
		TYPE_COLOR:
			return _math("color", [value.r, value.g, value.b, value.a])
		TYPE_BASIS:
			return _math("basis", [value.x.x, value.x.y, value.x.z,
				value.y.x, value.y.y, value.y.z, value.z.x, value.z.y, value.z.z])
		TYPE_TRANSFORM3D:
			return _math("transform3d", [value.basis.x.x, value.basis.x.y, value.basis.x.z,
				value.basis.y.x, value.basis.y.y, value.basis.y.z,
				value.basis.z.x, value.basis.z.y, value.basis.z.z,
				value.origin.x, value.origin.y, value.origin.z])
		_:
			return _error("unsupported_type")


static func _decode(value: Variant, depth: int, budget: Dictionary) -> Dictionary:
	if depth > MAX_DEPTH or typeof(value) != TYPE_DICTIONARY:
		return _error("malformed_value")
	budget.items = int(budget.items) + 1
	if int(budget.items) > MAX_ITEMS:
		return _error("max_items")
	var tag := str(value.get("t", ""))
	var payload: Variant = value.get("v")
	match tag:
		"null": return _ok(null)
		"bool": return _ok(bool(payload)) if typeof(payload) == TYPE_BOOL else _error("malformed_bool")
		"i64":
			var text := str(payload)
			return _ok(int(text)) if text.is_valid_int() else _error("malformed_i64")
		"f64":
			return _ok(float(payload)) if typeof(payload) in [TYPE_FLOAT, TYPE_INT] \
					and is_finite(float(payload)) else _error("malformed_f64")
		"string":
			return _ok(str(payload)) if typeof(payload) == TYPE_STRING \
					and str(payload).to_utf8_buffer().size() <= MAX_STRING_BYTES \
					else _error("malformed_string")
		"bytes":
			if typeof(payload) != TYPE_STRING or not _valid_base64(payload):
				return _error("malformed_bytes")
			var bytes := PackedByteArray() if payload.is_empty() else Marshalls.base64_to_raw(payload)
			if not payload.is_empty() and Marshalls.raw_to_base64(bytes) != payload:
				return _error("malformed_bytes")
			return _ok(bytes) if bytes.size() <= MAX_BYTE_BUFFER else _error("buffer_too_large")
		"array":
			if typeof(payload) != TYPE_ARRAY:
				return _error("malformed_array")
			var array: Array = []
			for item in payload:
				var decoded := _decode(item, depth + 1, budget)
				if not bool(decoded.ok): return decoded
				array.append(decoded.value)
			return _ok(array)
		"map":
			if typeof(payload) != TYPE_ARRAY:
				return _error("malformed_map")
			var map := {}
			for entry in payload:
				if typeof(entry) != TYPE_ARRAY or entry.size() != 2 or typeof(entry[0]) != TYPE_STRING \
						or map.has(entry[0]):
					return _error("malformed_map_entry")
				var decoded := _decode(entry[1], depth + 1, budget)
				if not bool(decoded.ok): return decoded
				map[entry[0]] = decoded.value
			return _ok(map)
		"vec2": return _decode_math(payload, 2, func(v): return Vector2(v[0], v[1]))
		"vec3": return _decode_math(payload, 3, func(v): return Vector3(v[0], v[1], v[2]))
		"vec4": return _decode_math(payload, 4, func(v): return Vector4(v[0], v[1], v[2], v[3]))
		"quat": return _decode_math(payload, 4, func(v): return Quaternion(v[0], v[1], v[2], v[3]))
		"color": return _decode_math(payload, 4, func(v): return Color(v[0], v[1], v[2], v[3]))
		"basis": return _decode_math(payload, 9, func(v): return Basis(
			Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]), Vector3(v[6], v[7], v[8])))
		"transform3d": return _decode_math(payload, 12, func(v): return Transform3D(Basis(
			Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]), Vector3(v[6], v[7], v[8])),
			Vector3(v[9], v[10], v[11])))
		_: return _error("unknown_tag")


static func _math(tag: String, values: Array) -> Dictionary:
	for value in values:
		if not is_finite(float(value)):
			return _error("non_finite_float")
	return _ok({"t": tag, "v": values})


static func _decode_math(payload: Variant, size: int, constructor: Callable) -> Dictionary:
	if typeof(payload) != TYPE_ARRAY or payload.size() != size:
		return _error("malformed_math")
	var values: Array[float] = []
	for item in payload:
		if typeof(item) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(item)):
			return _error("malformed_math")
		values.append(float(item))
	return _ok(constructor.call(values))


static func _valid_base64(text: String) -> bool:
	if text.is_empty(): return true
	if text.length() % 4 != 0: return false
	var padding := 0
	if text.ends_with("="):
		padding = 1
		if text.length() >= 2 and text[text.length() - 2] == "=": padding = 2
	for index in text.length():
		var code := text.unicode_at(index)
		var is_data := (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
				or (code >= 48 and code <= 57) or code in [43, 47]
		if index < text.length() - padding:
			if not is_data: return false
		elif code != 61:
			return false
	return true


static func is_valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var first := int(bytes[index])
		if first <= 0x7f:
			index += 1
			continue
		var count := 0
		var minimum := 0
		var codepoint := 0
		if first >= 0xc2 and first <= 0xdf:
			count = 1; minimum = 0x80; codepoint = first & 0x1f
		elif first >= 0xe0 and first <= 0xef:
			count = 2; minimum = 0x800; codepoint = first & 0x0f
		elif first >= 0xf0 and first <= 0xf4:
			count = 3; minimum = 0x10000; codepoint = first & 0x07
		else:
			return false
		if index + count >= bytes.size(): return false
		for offset in range(1, count + 1):
			var continuation := int(bytes[index + offset])
			if continuation < 0x80 or continuation > 0xbf: return false
			codepoint = (codepoint << 6) | (continuation & 0x3f)
		if codepoint < minimum or codepoint > 0x10ffff \
				or (codepoint >= 0xd800 and codepoint <= 0xdfff):
			return false
		index += count + 1
	return true


static func _ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "value": null, "error": code}
