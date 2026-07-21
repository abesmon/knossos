class_name ReplicatedStateStore
extends RefCounted

const PolicyEvaluatorImpl = preload("res://scripts/network/policy_evaluator.gd")

## Чистая машина реплицируемого состояния. Не вызывает RPC и не знает домены: схема
## описывает wire-типы, команды и reducer, а NetworkManager подставляет sender context.

signal state_changed(object_id: String, schema_id: String, state: Dictionary, changed: Dictionary, revision: int)
signal bindings_changed(object_id: String, schema_id: String, bindings: Dictionary,
		changed: Dictionary, revision: int)

const MAX_STRING_BYTES := 4096
const MAX_ARRAY_ITEMS := 256
const MAX_BYTES := 16384
const MAX_FIELDS := 64
const MAX_BINDINGS := 16
const MAX_BINDING_NAME_CHARS := 64
const MAX_PRINCIPAL_BYTES := 128
const MAX_OBJECTS := 256
const MAX_OBJECT_BYTES := 16 * 1024
const MAX_DELTA_BYTES := 16 * 1024

var _schemas: Dictionary = {} # schema_id -> definition
var _objects: Dictionary = {} # "schema\nobject" -> record
## Snapshot комнаты может прийти раньше, чем страница загрузилась и зарегистрировала свою
## схему. Такие записи нельзя выбрасывать: sequence снимка уже принят, поэтому следующая
## delta этого объекта увидит локальную revision=0 и уйдёт в resync. Храним неприменённые
## records до ensure_object после регистрации схемы; до этого они недоступны потребителям.
var _deferred_objects: Dictionary = {} # "schema\nobject" -> непроверенный schema record
var _epoch := 0
var _seq := 0
var _applied_epoch := 0
var _applied_seq := 0


func register_schema(schema_id: String, definition: Dictionary) -> bool:
	if schema_id.is_empty():
		return false
	var version := int(definition.get("version", 0))
	var fields: Dictionary = definition.get("fields", {})
	var commands: Dictionary = definition.get("commands", {})
	if version <= 0 or fields.is_empty() or fields.size() > MAX_FIELDS:
		return false
	for field in fields:
		if not _valid_field_spec(str(field), fields[field]):
			return false
	for command in commands:
		var spec = commands[command]
		if typeof(spec) != TYPE_DICTIONARY or not (spec as Dictionary).has("reducer") \
				or not ((spec as Dictionary)["reducer"] is Callable):
			return false
	_schemas[schema_id] = definition.duplicate(true)
	return true


func unregister_schema(schema_id: String) -> void:
	_schemas.erase(schema_id)
	for key in _objects.keys():
		if (_objects[key] as Dictionary).get("schema_id", "") == schema_id:
			_objects.erase(key)
	for key in _deferred_objects.keys():
		if (_deferred_objects[key] as Dictionary).get("schema_id", "") == schema_id:
			_deferred_objects.erase(key)


func reset_session() -> void:
	_objects.clear()
	_deferred_objects.clear()
	_epoch = 0
	_seq = 0
	_applied_epoch = 0
	_applied_seq = 0


func ensure_object(object_id: String, schema_id: String, initial: Dictionary = {},
		initial_bindings: Dictionary = {}) -> bool:
	if object_id.is_empty() or not _schemas.has(schema_id):
		return false
	if not _valid_bindings(initial_bindings):
		return false
	var key := _key(object_id, schema_id)
	if _deferred_objects.has(key):
		_materialize_deferred_object(key)
	if _objects.has(key):
		return true
	# Deferred snapshot records consume the same room-wide object budget even though consumers
	# cannot see them yet. Иначе поздняя регистрация схем могла бы поднять Store выше лимита.
	if _objects.size() + _deferred_objects.size() >= MAX_OBJECTS:
		return false
	var state := _default_state(schema_id)
	for field in initial:
		if not _validate_field(schema_id, str(field), initial[field]):
			return false
		state[field] = initial[field]
	var record := {
		"object_id": object_id,
		"schema_id": schema_id,
		"version": int((_schemas[schema_id] as Dictionary)["version"]),
		"revision": 0,
		"bindings": initial_bindings.duplicate(true),
		"state": state,
	}
	if var_to_bytes(record).size() > MAX_OBJECT_BYTES:
		return false
	_objects[key] = record
	return true


func remove_object(object_id: String, schema_id: String) -> void:
	_objects.erase(_key(object_id, schema_id))


func state_of(object_id: String, schema_id: String) -> Dictionary:
	var record: Dictionary = _objects.get(_key(object_id, schema_id), {})
	return (record.get("state", {}) as Dictionary).duplicate(true)


func bindings_of(object_id: String, schema_id: String) -> Dictionary:
	var record: Dictionary = _objects.get(_key(object_id, schema_id), {})
	return (record.get("bindings", {}) as Dictionary).duplicate(true)


func revision_of(object_id: String, schema_id: String) -> int:
	return int((_objects.get(_key(object_id, schema_id), {}) as Dictionary).get("revision", -1))


func validate_sample(object_id: String, schema_id: String, version: int, sample: Dictionary) -> bool:
	if revision_of(object_id, schema_id) < 0 or not _schemas.has(schema_id) \
			or version != int((_schemas[schema_id] as Dictionary)["version"]):
		return false
	var specs: Dictionary = (_schemas[schema_id] as Dictionary).get("sample_fields", {})
	if specs.is_empty() or sample.size() > specs.size():
		return false
	for field in sample:
		if not specs.has(field) or not _valid_value(sample[field], specs[field]):
			return false
	return true


func begin_authority() -> void:
	_epoch = maxi(_epoch, _applied_epoch) + 1
	_seq = 0
	_applied_epoch = _epoch
	_applied_seq = 0


## Возвращает {ok, delta?, error?}. Reducer result is an atomic transaction:
## {state: field_patch, bindings: binding_patch}. Context actor is transport-bound.
func commit_command(object_id: String, schema_id: String, version: int, command: String,
		args: Dictionary, context: Dictionary) -> Dictionary:
	var key := _key(object_id, schema_id)
	if not _objects.has(key) or not _schemas.has(schema_id):
		return _error("unknown_object")
	var schema: Dictionary = _schemas[schema_id]
	var record: Dictionary = _objects[key]
	if version != int(schema["version"]) or version != int(record["version"]):
		return _error("schema_version")
	var commands: Dictionary = schema.get("commands", {})
	if not commands.has(command) or typeof(args) != TYPE_DICTIONARY:
		return _error("unknown_command")
	if not _valid_container(args, 0):
		return _error("invalid_args")
	var command_spec: Dictionary = commands[command]
	var rule = command_spec.get("write_rule", schema.get("default_write_rule", "authority"))
	var access_context := context.duplicate()
	access_context["actor_user_id"] = str(context.get("actor_user_id", ""))
	access_context["bindings"] = (record.get("bindings", {}) as Dictionary).duplicate(true)
	if not PolicyEvaluatorImpl.evaluate(rule, access_context):
		return _error("access_denied")
	var reducer: Callable = command_spec["reducer"]
	var reducer_context := context.duplicate()
	reducer_context["actor_user_id"] = access_context["actor_user_id"]
	reducer_context["bindings"] = access_context["bindings"]
	var transaction = reducer.call((record["state"] as Dictionary).duplicate(true),
			args.duplicate(true), reducer_context)
	if typeof(transaction) != TYPE_DICTIONARY:
		return _error("rejected")
	var state_patch = (transaction as Dictionary).get("state", {})
	var binding_patch = (transaction as Dictionary).get("bindings", {})
	if typeof(state_patch) != TYPE_DICTIONARY or typeof(binding_patch) != TYPE_DICTIONARY \
			or ((state_patch as Dictionary).is_empty() and (binding_patch as Dictionary).is_empty()):
		return _error("rejected")
	for field in state_patch:
		if not _validate_field(schema_id, str(field), state_patch[field]):
			return _error("invalid_patch")
	if not _valid_binding_patch(record.get("bindings", {}), binding_patch):
		return _error("invalid_patch")
	var next_state: Dictionary = (record["state"] as Dictionary).duplicate(true)
	for field in state_patch:
		next_state[field] = state_patch[field]
	var next_bindings: Dictionary = (record.get("bindings", {}) as Dictionary).duplicate(true)
	_apply_binding_patch(next_bindings, binding_patch)
	var next_revision := int(record["revision"]) + 1
	var next_seq := _seq + 1
	var delta := {
		"epoch": _epoch, "seq": next_seq, "object_id": object_id, "schema_id": schema_id,
		"version": version, "revision": next_revision,
		"changed": (state_patch as Dictionary).duplicate(true),
		"binding_changes": (binding_patch as Dictionary).duplicate(true),
	}
	var prospective := record.duplicate(true)
	prospective["state"] = next_state
	prospective["bindings"] = next_bindings
	prospective["revision"] = next_revision
	if var_to_bytes(prospective).size() > MAX_OBJECT_BYTES or var_to_bytes(delta).size() > MAX_DELTA_BYTES:
		return _error("too_large")
	record["state"] = next_state
	record["bindings"] = next_bindings
	record["revision"] = next_revision
	_seq = next_seq
	_applied_epoch = _epoch
	_applied_seq = _seq
	if not (state_patch as Dictionary).is_empty():
		state_changed.emit(object_id, schema_id, next_state.duplicate(true),
				(state_patch as Dictionary).duplicate(true), next_revision)
	if not (binding_patch as Dictionary).is_empty():
		bindings_changed.emit(object_id, schema_id, next_bindings.duplicate(true),
				(binding_patch as Dictionary).duplicate(true), next_revision)
	return {"ok": true, "delta": delta}


## ok | duplicate | gap | invalid. Delta принимается только от проверенного authority transport.
func apply_delta(delta: Dictionary) -> String:
	if var_to_bytes(delta).size() > MAX_DELTA_BYTES or not _valid_envelope(delta):
		return "invalid"
	var epoch := int(delta["epoch"])
	var seq := int(delta["seq"])
	if epoch < _applied_epoch or (epoch == _applied_epoch and seq <= _applied_seq):
		return "duplicate"
	# Новую эпоху нельзя угадывать по первому delta: сначала нужен authority snapshot.
	if epoch != _applied_epoch or seq != _applied_seq + 1:
		return "gap"
	var schema_id := str(delta["schema_id"])
	var object_id := str(delta["object_id"])
	var key := _key(object_id, schema_id)
	if not _schemas.has(schema_id) or int(delta["version"]) != int((_schemas[schema_id] as Dictionary)["version"]):
		return "invalid"
	if not _objects.has(key) and not ensure_object(object_id, schema_id):
		return "invalid"
	var record: Dictionary = _objects[key]
	var revision := int(delta["revision"])
	if revision != int(record["revision"]) + 1:
		return "gap"
	var changed: Dictionary = delta["changed"]
	var binding_changes = delta.get("binding_changes", {})
	if typeof(binding_changes) != TYPE_DICTIONARY:
		return "invalid"
	for field in changed:
		if not _validate_field(schema_id, str(field), changed[field]):
			return "invalid"
	var state: Dictionary = record["state"]
	if not _valid_binding_patch(record.get("bindings", {}), binding_changes):
		return "invalid"
	for field in changed:
		state[field] = changed[field]
	var bindings: Dictionary = record.get("bindings", {})
	_apply_binding_patch(bindings, binding_changes)
	record["revision"] = revision
	_applied_epoch = epoch
	_applied_seq = seq
	_epoch = maxi(_epoch, epoch)
	if not changed.is_empty():
		state_changed.emit(object_id, schema_id, state.duplicate(true), changed.duplicate(true), revision)
	if not (binding_changes as Dictionary).is_empty():
		bindings_changed.emit(object_id, schema_id, bindings.duplicate(true),
				(binding_changes as Dictionary).duplicate(true), revision)
	return "ok"


func snapshot() -> Dictionary:
	var objects: Array = []
	for record in _objects.values():
		objects.append((record as Dictionary).duplicate(true))
	return {"epoch": _epoch, "seq": _seq, "objects": objects}


func apply_snapshot(data: Dictionary) -> bool:
	if typeof(data.get("objects")) != TYPE_ARRAY or (data["objects"] as Array).size() > MAX_OBJECTS:
		return false
	var incoming: Dictionary = {}
	var deferred: Dictionary = {}
	for value in data["objects"]:
		if typeof(value) != TYPE_DICTIONARY:
			return false
		var record: Dictionary = value
		var schema_id := str(record.get("schema_id", ""))
		var object_id := str(record.get("object_id", ""))
		if object_id.is_empty() or schema_id.is_empty() or int(record.get("version", 0)) <= 0:
			return false
		var state = record.get("state")
		if typeof(state) != TYPE_DICTIONARY:
			return false
		# Схема может появиться после snapshot (страница/portable item ещё грузится).
		# Пока её нет, проверяем общий контейнер и бюджет; поля провалидируем при регистрации.
		if not _schemas.has(schema_id):
			var pending := record.duplicate(true)
			if not _valid_container(pending, 0) or var_to_bytes(pending).size() > MAX_OBJECT_BYTES:
				return false
			deferred[_key(object_id, schema_id)] = pending
			continue
		if int(record["version"]) != int((_schemas[schema_id] as Dictionary)["version"]):
			continue
		for field in state:
			if not _validate_field(schema_id, str(field), state[field]):
				return false
		var bindings = record.get("bindings", {})
		if typeof(bindings) != TYPE_DICTIONARY or not _valid_bindings(bindings):
			return false
		var normalized := {
			"object_id": object_id, "schema_id": schema_id, "version": int(record["version"]),
			"revision": maxi(0, int(record.get("revision", 0))),
			"bindings": (bindings as Dictionary).duplicate(true),
			"state": (state as Dictionary).duplicate(true),
		}
		if var_to_bytes(normalized).size() > MAX_OBJECT_BYTES:
			return false
		incoming[_key(object_id, schema_id)] = normalized
	var previous_objects := _objects
	_objects = incoming
	_deferred_objects = deferred
	_applied_epoch = maxi(0, int(data.get("epoch", 0)))
	_applied_seq = maxi(0, int(data.get("seq", 0)))
	_epoch = maxi(_epoch, _applied_epoch)
	for record in _objects.values():
		var r: Dictionary = record
		state_changed.emit(r["object_id"], r["schema_id"], (r["state"] as Dictionary).duplicate(true),
				(r["state"] as Dictionary).duplicate(true), int(r["revision"]))
		var bindings: Dictionary = r.get("bindings", {})
		var previous_record: Dictionary = previous_objects.get(
				_key(str(r["object_id"]), str(r["schema_id"])), {})
		var previous_bindings: Dictionary = previous_record.get("bindings", {})
		var binding_changes := bindings.duplicate(true)
		for name in previous_bindings:
			if not bindings.has(name):
				binding_changes[name] = ""
		if not binding_changes.is_empty():
			bindings_changed.emit(r["object_id"], r["schema_id"], bindings.duplicate(true),
					binding_changes, int(r["revision"]))
	return true


## Активировать канонический record, приехавший до того, как consumer объявил свою схему и
## объект. Запись с несовместимой версией/полями локально отбрасывается.
func _materialize_deferred_object(key: String) -> void:
	var record: Dictionary = _deferred_objects.get(key, {})
	_deferred_objects.erase(key)
	if record.is_empty():
		return
	var schema_id := str(record.get("schema_id", ""))
	if not _schemas.has(schema_id) \
			or int(record.get("version", 0)) != int((_schemas[schema_id] as Dictionary)["version"]):
		return
	var state = record.get("state")
	if typeof(state) != TYPE_DICTIONARY:
		return
	for field in state:
		if not _validate_field(schema_id, str(field), state[field]):
			return
	var bindings = record.get("bindings", {})
	if typeof(bindings) != TYPE_DICTIONARY or not _valid_bindings(bindings):
		return
	var normalized := {
		"object_id": str(record.get("object_id", "")), "schema_id": schema_id,
		"version": int(record["version"]), "revision": maxi(0, int(record.get("revision", 0))),
		"bindings": (bindings as Dictionary).duplicate(true),
		"state": (state as Dictionary).duplicate(true),
	}
	if normalized["object_id"].is_empty() or var_to_bytes(normalized).size() > MAX_OBJECT_BYTES:
		return
	_objects[key] = normalized
	state_changed.emit(normalized["object_id"], schema_id,
			(normalized["state"] as Dictionary).duplicate(true),
			(normalized["state"] as Dictionary).duplicate(true), int(normalized["revision"]))
	var normalized_bindings: Dictionary = normalized.get("bindings", {})
	if not normalized_bindings.is_empty():
		bindings_changed.emit(normalized["object_id"], schema_id,
				normalized_bindings.duplicate(true), normalized_bindings.duplicate(true),
				int(normalized["revision"]))


func _valid_envelope(delta: Dictionary) -> bool:
	return int(delta.get("epoch", 0)) > 0 and int(delta.get("seq", 0)) > 0 \
			and int(delta.get("revision", 0)) > 0 and typeof(delta.get("changed")) == TYPE_DICTIONARY \
			and not str(delta.get("object_id", "")).is_empty() and not str(delta.get("schema_id", "")).is_empty()


func _valid_bindings(value: Dictionary) -> bool:
	if value.size() > MAX_BINDINGS:
		return false
	for key in value:
		if typeof(key) != TYPE_STRING or typeof(value[key]) != TYPE_STRING:
			return false
		var name: String = key
		var principal: String = value[key]
		if not _valid_binding_name(name) or principal.is_empty() \
				or principal.to_utf8_buffer().size() > MAX_PRINCIPAL_BYTES:
			return false
	return true


func _valid_binding_patch(current, patch) -> bool:
	if typeof(current) != TYPE_DICTIONARY or typeof(patch) != TYPE_DICTIONARY:
		return false
	for key in patch:
		if typeof(key) != TYPE_STRING or typeof((patch as Dictionary)[key]) != TYPE_STRING \
				or not _valid_binding_name(key) \
				or ((patch as Dictionary)[key] as String).to_utf8_buffer().size() > MAX_PRINCIPAL_BYTES:
			return false
	var prospective: Dictionary = (current as Dictionary).duplicate(true)
	_apply_binding_patch(prospective, patch)
	return _valid_bindings(prospective)


func _apply_binding_patch(target: Dictionary, patch: Dictionary) -> void:
	for key in patch:
		var name := str(key)
		var principal := str(patch[key])
		if principal.is_empty():
			target.erase(name)
		else:
			target[name] = principal


func _valid_binding_name(name: String) -> bool:
	return not name.is_empty() and name.length() <= MAX_BINDING_NAME_CHARS \
			and name.is_valid_identifier()


func _default_state(schema_id: String) -> Dictionary:
	var result := {}
	var fields: Dictionary = (_schemas[schema_id] as Dictionary)["fields"]
	for field in fields:
		result[field] = (fields[field] as Dictionary).get("default")
	return result


func _validate_field(schema_id: String, field: String, value) -> bool:
	var fields: Dictionary = (_schemas[schema_id] as Dictionary).get("fields", {})
	return fields.has(field) and _valid_value(value, fields[field])


func _valid_field_spec(field: String, spec) -> bool:
	return not field.is_empty() and typeof(spec) == TYPE_DICTIONARY \
			and (spec as Dictionary).has("type") and (spec as Dictionary).has("default") \
			and _valid_value((spec as Dictionary)["default"], spec)


func _valid_value(value, spec) -> bool:
	var d: Dictionary = spec
	match str(d.get("type", "")):
		"bool": return typeof(value) == TYPE_BOOL
		"int":
			return typeof(value) == TYPE_INT and int(value) >= int(d.get("min", -9223372036854775807)) \
					and int(value) <= int(d.get("max", 9223372036854775807))
		"float":
			return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and is_finite(float(value)) \
					and float(value) >= float(d.get("min", -1.79769e308)) and float(value) <= float(d.get("max", 1.79769e308))
		"string": return typeof(value) == TYPE_STRING and (value as String).to_utf8_buffer().size() <= int(d.get("max_bytes", MAX_STRING_BYTES))
		"bytes": return typeof(value) == TYPE_PACKED_BYTE_ARRAY and (value as PackedByteArray).size() <= int(d.get("max_bytes", MAX_BYTES))
		"array":
			if typeof(value) != TYPE_ARRAY or (value as Array).size() > int(d.get("max_items", MAX_ARRAY_ITEMS)):
				return false
			var item_spec = d.get("items")
			if typeof(item_spec) != TYPE_DICTIONARY: return false
			for item in value:
				if not _valid_value(item, item_spec): return false
			return true
		_: return false


func _valid_container(value, depth: int) -> bool:
	if depth > 3:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return true
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_STRING:
			return (value as String).to_utf8_buffer().size() <= MAX_STRING_BYTES
		TYPE_PACKED_BYTE_ARRAY:
			return (value as PackedByteArray).size() <= MAX_BYTES
		TYPE_ARRAY:
			if (value as Array).size() > MAX_ARRAY_ITEMS: return false
			for child in value:
				if not _valid_container(child, depth + 1): return false
			return true
		TYPE_DICTIONARY:
			if (value as Dictionary).size() > MAX_FIELDS: return false
			for key in value:
				if typeof(key) != TYPE_STRING or not _valid_container((value as Dictionary)[key], depth + 1):
					return false
			return true
		_:
			return false


func _key(object_id: String, schema_id: String) -> String:
	return schema_id + "\n" + object_id


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
