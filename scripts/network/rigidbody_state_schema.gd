class_name RigidbodyStateSchema
extends RefCounted

## Переносимый state/sample профиль обычного VRWML <RigidBody3D>. Сам физический узел остаётся
## Godot-тегом один-к-одному; эта схема только связывает его с Subject Bindings и транспортом.

const VERSION := 1
const POSE_IDENTITY: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
const VECTOR_ZERO: Array = [0.0, 0.0, 0.0]


static func definition(extra_commands: Dictionary = {}, extra_fields: Dictionary = {}) -> Dictionary:
	var commands := {
		"claim_simulation": {"_host_reducer": true, "reducer": reduce_claim},
		"commit_keyframe": {"_host_reducer": true,
			"write_rule": {"assigned": "simulator"}, "reducer": reduce_keyframe},
	}
	for command_name in extra_commands:
		if not commands.has(command_name):
			commands[command_name] = extra_commands[command_name]
	var fields := {
			"pose": _array_spec(7, POSE_IDENTITY),
			"linear_velocity": _array_spec(3, VECTOR_ZERO),
			"angular_velocity": _array_spec(3, VECTOR_ZERO),
			"sleeping": {"type": "bool", "default": false},
			"simulation_epoch": {"type": "int", "default": 0},
			"tick": {"type": "int", "default": 0},
	}
	for field_name in extra_fields:
		if not fields.has(field_name):
			fields[field_name] = extra_fields[field_name]
	return {
		"version": VERSION,
		"fields": fields,
		"sample_fields": {
			"pose": _array_spec(7, POSE_IDENTITY),
			"linear_velocity": _array_spec(3, VECTOR_ZERO),
			"angular_velocity": _array_spec(3, VECTOR_ZERO),
			"sleeping": {"type": "bool", "default": false},
			"simulation_epoch": {"type": "int", "default": 0},
			"tick": {"type": "int", "default": 0},
			"revision": {"type": "int", "default": 0},
		},
		"sample_write_rule": {"assigned": "simulator"},
		"sample_validator": valid_sample,
		"default_write_rule": "anyone",
		"commands": commands,
		"_transaction_validator": validate_transaction,
	}


static func initial_state(body: RigidBody3D) -> Dictionary:
	return {
		"pose": pack_transform(body.global_transform),
		"linear_velocity": pack_vector(body.linear_velocity),
		"angular_velocity": pack_vector(body.angular_velocity),
		"sleeping": body.sleeping,
		"simulation_epoch": 0,
		"tick": 0,
	}


static func snapshot(body: RigidBody3D, epoch: int, tick: int) -> Dictionary:
	# A Node may remain instance-valid for a frame after page refresh detached it from the
	# SceneTree. Reading global_transform in that interval is an engine error, not a usable pose.
	if body == null or not is_instance_valid(body) or not body.is_inside_tree() \
			or body.is_queued_for_deletion():
		return {}
	return {
		"pose": pack_transform(body.global_transform),
		"linear_velocity": pack_vector(body.linear_velocity),
		"angular_velocity": pack_vector(body.angular_velocity),
		"sleeping": body.sleeping,
		"simulation_epoch": epoch,
		"tick": tick,
	}


static func reduce_claim(state: Dictionary, args: Dictionary, context: Dictionary) -> Dictionary:
	var actor := str(context.get("actor_user_id", ""))
	if actor.is_empty() or not valid_snapshot(args):
		return {}
	return {"bindings": {"simulator": actor}, "state": {
		"pose": canonical_pose(args.pose),
		"linear_velocity": canonical_vector(args.linear_velocity),
		"angular_velocity": canonical_vector(args.angular_velocity),
		"sleeping": bool(args.get("sleeping", false)),
		"simulation_epoch": int(state.get("simulation_epoch", 0)) + 1,
		"tick": int(args.get("tick", 0)),
	}}


static func reduce_keyframe(state: Dictionary, args: Dictionary,
		_context: Dictionary) -> Dictionary:
	if not valid_snapshot(args) \
			or int(args.simulation_epoch) != int(state.get("simulation_epoch", 0)):
		return {}
	return {"state": {
		"pose": canonical_pose(args.pose),
		"linear_velocity": canonical_vector(args.linear_velocity),
		"angular_velocity": canonical_vector(args.angular_velocity),
		"sleeping": bool(args.get("sleeping", false)),
		"simulation_epoch": int(args.simulation_epoch),
		"tick": int(args.tick),
	}}


## Оборачивает и host-, и page-reducers. Это semantic validity, не performance policy.
static func validate_transaction(state: Dictionary, bindings: Dictionary, transaction,
		_context: Dictionary) -> Dictionary:
	if typeof(transaction) != TYPE_DICTIONARY:
		return {}
	var result: Dictionary = transaction
	var state_patch = result.get("state", {})
	var binding_patch = result.get("bindings", {})
	if typeof(state_patch) != TYPE_DICTIONARY or typeof(binding_patch) != TYPE_DICTIONARY:
		return {}
	for field in ["pose", "linear_velocity", "angular_velocity"]:
		if (state_patch as Dictionary).has(field):
			var valid := valid_pose(state_patch[field]) if field == "pose" \
					else valid_vector(state_patch[field])
			if not valid:
				return {}
	var previous_simulator := str(bindings.get("simulator", ""))
	var next_simulator := str((binding_patch as Dictionary).get("simulator", previous_simulator))
	if next_simulator != previous_simulator:
		if not (state_patch as Dictionary).has("simulation_epoch") \
				or int((state_patch as Dictionary).simulation_epoch) \
				!= int(state.get("simulation_epoch", 0)) + 1:
			return {}
		for required in ["pose", "linear_velocity", "angular_velocity", "tick"]:
			if not (state_patch as Dictionary).has(required):
				return {}
	return result


static func valid_snapshot(value: Dictionary) -> bool:
	return valid_pose(value.get("pose")) \
			and valid_vector(value.get("linear_velocity")) \
			and valid_vector(value.get("angular_velocity")) \
			and typeof(value.get("simulation_epoch")) == TYPE_INT \
			and typeof(value.get("tick")) == TYPE_INT


static func valid_sample(value: Dictionary) -> bool:
	return valid_snapshot(value) and typeof(value.get("revision")) == TYPE_INT \
			and typeof(value.get("sleeping")) == TYPE_BOOL


static func valid_pose(value) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 7:
		return false
	if not _finite_numbers(value):
		return false
	return Vector4(float(value[3]), float(value[4]), float(value[5]), float(value[6])).length() > 0.0


static func valid_vector(value) -> bool:
	return typeof(value) == TYPE_ARRAY and (value as Array).size() == 3 and _finite_numbers(value)


static func canonical_pose(value: Array) -> Array:
	var q := Quaternion(float(value[3]), float(value[4]), float(value[5]), float(value[6])).normalized()
	return [float(value[0]), float(value[1]), float(value[2]), q.x, q.y, q.z, q.w]


static func canonical_vector(value: Array) -> Array:
	return [float(value[0]), float(value[1]), float(value[2])]


static func pack_transform(value: Transform3D) -> Array:
	var q := value.basis.orthonormalized().get_rotation_quaternion()
	return [value.origin.x, value.origin.y, value.origin.z, q.x, q.y, q.z, q.w]


static func unpack_transform(value) -> Transform3D:
	if not valid_pose(value):
		return Transform3D.IDENTITY
	var q := Quaternion(float(value[3]), float(value[4]), float(value[5]), float(value[6])).normalized()
	return Transform3D(Basis(q), Vector3(float(value[0]), float(value[1]), float(value[2])))


static func pack_vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func unpack_vector(value) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2])) \
			if valid_vector(value) else Vector3.ZERO


static func _array_spec(items: int, default_value: Array) -> Dictionary:
	return {"type": "array", "default": default_value.duplicate(), "max_items": items,
		"items": {"type": "float", "default": 0.0}}


static func _finite_numbers(value: Array) -> bool:
	for item in value:
		if typeof(item) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(item)):
			return false
	return true
