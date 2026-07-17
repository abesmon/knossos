class_name WasmHandleTable
extends RefCounted

var _slots: Array[Dictionary] = []
var _free: Array[int] = []
var _object_handles: Dictionary = {}
var _live := 0


func create(value: Variant, owner: String, page: String, type_tag: String) -> int:
	var identity_key := _identity_key(value, owner, page, type_tag)
	if not identity_key.is_empty() and _object_handles.has(identity_key):
		var existing := int(_object_handles[identity_key])
		if bool(resolve(existing, owner, page, type_tag).ok):
			return existing
		_object_handles.erase(identity_key)
	var index: int = int(_free.pop_back()) if not _free.is_empty() else _slots.size()
	if index == _slots.size():
		_slots.append({"generation": 1})
	var generation := int(_slots[index].get("generation", 1))
	_slots[index] = {"generation": generation, "alive": true, "owner": owner, "page": page,
		"type": type_tag, "value": weakref(value) if value is Object else value,
		"weak": value is Object, "identity_key": identity_key}
	_live += 1
	var handle := (generation << 32) | (index + 1)
	if not identity_key.is_empty(): _object_handles[identity_key] = handle
	return handle


func resolve(handle: int, owner: String, page: String, expected_type: String = "") -> Dictionary:
	var decoded := _decode(handle)
	if not bool(decoded.ok): return decoded
	var slot: Dictionary = _slots[decoded.index]
	if not bool(slot.get("alive", false)) or int(slot.generation) != int(decoded.generation):
		return _error("stale_handle")
	if str(slot.owner) != owner:
		return _error("foreign_owner")
	if str(slot.page) != page:
		return _error("foreign_page")
	if not expected_type.is_empty() and str(slot.type) != expected_type:
		return _error("wrong_type")
	var value: Variant = slot.value.get_ref() if bool(slot.weak) else slot.value
	if value == null:
		invalidate(handle)
		return _error("stale_handle")
	return {"ok": true, "value": value, "type": str(slot.type), "error": ""}


func invalidate(handle: int) -> bool:
	var decoded := _decode(handle)
	if not bool(decoded.ok): return false
	var slot: Dictionary = _slots[decoded.index]
	if not bool(slot.get("alive", false)) or int(slot.generation) != int(decoded.generation):
		return false
	var identity_key := str(slot.get("identity_key", ""))
	if not identity_key.is_empty() and int(_object_handles.get(identity_key, 0)) == handle:
		_object_handles.erase(identity_key)
	slot.alive = false
	slot.value = null
	slot.generation = int(slot.generation) + 1
	_slots[decoded.index] = slot
	_free.append(decoded.index)
	_live -= 1
	return true


func invalidate_scope(owner: String, page: String) -> void:
	for index in _slots.size():
		var slot: Dictionary = _slots[index]
		if bool(slot.get("alive", false)) and str(slot.owner) == owner and str(slot.page) == page:
			invalidate((int(slot.generation) << 32) | (index + 1))


func size() -> int:
	return _live


func _decode(handle: int) -> Dictionary:
	var index := int(handle & 0xffffffff) - 1
	var generation := int((handle >> 32) & 0x7fffffff)
	if handle <= 0 or index < 0 or index >= _slots.size() or generation <= 0:
		return _error("invalid_handle")
	return {"ok": true, "index": index, "generation": generation, "error": ""}


func _identity_key(value: Variant, owner: String, page: String, type_tag: String) -> String:
	if not (value is Object): return ""
	return "%s\u001f%s\u001f%s\u001f%d" % [owner, page, type_tag, value.get_instance_id()]


func _error(code: String) -> Dictionary:
	return {"ok": false, "value": null, "type": "", "error": code}
