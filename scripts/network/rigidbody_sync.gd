class_name RigidbodySync
extends Node

## Клиентская презентация binding-aware физического subject. У simulator остаётся обычный
## RigidBody3D; остальные клиенты держат frozen proxy и сглаживают входящие SAMPLE.

const DEFAULT_SAMPLE_HZ := 20.0
const DEFAULT_KEYFRAME_INTERVAL := 1.0
const DEFAULT_INTERPOLATION_DELAY := 0.10
const CLIENT_EXTRAPOLATION_WINDOW := 0.25

var body: RigidBody3D
var object_id := ""
var schema_id := ""
var version := RigidbodyStateSchema.VERSION
var sample_hz := DEFAULT_SAMPLE_HZ
var keyframe_interval := DEFAULT_KEYFRAME_INTERVAL
var interpolation_delay := DEFAULT_INTERPOLATION_DELAY
var auto_claim := true

var _original_freeze := false
var _local_simulator := false
var _role_initialized := false
var _epoch := 0
var _tick := 0
var _sample_accum := 0.0
var _keyframe_accum := 0.0
var _last_sleeping := false
var _samples: Array[Dictionary] = []
var _last_sample_tick := -1
var _optimistic := false
var _pending_handoff_request := -1
var _suspended := false
var _shutting_down := false


func setup(target: RigidBody3D, wire_object: String, wire_schema: String,
		options: Dictionary = {}) -> void:
	body = target
	object_id = wire_object
	schema_id = wire_schema
	sample_hz = float(options.get("sample_hz", DEFAULT_SAMPLE_HZ))
	keyframe_interval = float(options.get("keyframe_interval", DEFAULT_KEYFRAME_INTERVAL))
	interpolation_delay = maxf(0.0, float(options.get("interpolation_delay", DEFAULT_INTERPOLATION_DELAY)))
	auto_claim = bool(options.get("auto_claim", true))
	_original_freeze = target.freeze
	_last_sleeping = target.sleeping


func _ready() -> void:
	NetworkManager.replicated_state_received.connect(_on_state)
	NetworkManager.replicated_bindings_received.connect(_on_bindings)
	NetworkManager.replicated_sample_received.connect(_on_sample)
	NetworkManager.replicated_command_result.connect(_on_command_result)
	NetworkManager.authority_changed.connect(_on_authority_changed)
	NetworkManager.ghost_expired.connect(_on_ghost_expired)
	_apply_canonical(NetworkManager.replicated_state(object_id, schema_id), true)
	_refresh_role()
	if auto_claim:
		_maybe_claim.call_deferred()


func _exit_tree() -> void:
	shutdown()


func shutdown(restore_body := true) -> void:
	if _shutting_down:
		return
	_shutting_down = true
	if restore_body and body != null and is_instance_valid(body):
		body.freeze = _original_freeze


func _physics_process(delta: float) -> void:
	if not _body_in_live_tree():
		queue_free()
		return
	if _local_simulator:
		_publish(delta)
	else:
		_apply_proxy()


func claim() -> int:
	if not _body_in_live_tree():
		return -1
	var args := RigidbodyStateSchema.snapshot(body, _epoch, _tick)
	return _request_handoff("claim_simulation", args)


func handoff(command_name: String) -> int:
	if not _body_in_live_tree():
		return -1
	return _request_handoff(command_name, RigidbodyStateSchema.snapshot(body, _epoch, _tick))


func command(command_name: String, args: Dictionary = {}) -> int:
	if _shutting_down or not is_inside_tree() or is_queued_for_deletion():
		return -1
	return NetworkManager.request_replicated_command(object_id, schema_id, version,
			command_name, args)


func simulator() -> String:
	return str(NetworkManager.replicated_bindings(object_id, schema_id).get("simulator", ""))


func is_local_simulator() -> bool:
	return _local_simulator


func apply_impulse(impulse: Vector3) -> bool:
	if not _local_simulator or _suspended or not _body_in_live_tree():
		return false
	body.apply_central_impulse(impulse)
	body.sleeping = false
	return true


## Временно выключает и dynamic-, и proxy-презентацию, когда позу выводит другой домен
## (например, VRWebGrabbable держит предмет в якоре руки). Binding simulator сохраняется.
func set_suspended(value: bool) -> void:
	if _suspended == value:
		return
	_suspended = value
	_samples.clear()
	_last_sample_tick = -1
	if not _body_in_live_tree():
		return
	if _suspended:
		body.freeze = true
	else:
		_refresh_role(true)
		_apply_canonical(NetworkManager.replicated_state(object_id, schema_id), true)


func _publish(delta: float) -> void:
	if _suspended or not _body_in_live_tree():
		return
	_sample_accum += delta
	_keyframe_accum += delta
	if body.sleeping != _last_sleeping:
		_last_sleeping = body.sleeping
		_keyframe_accum = 0.0
		NetworkManager.request_replicated_command(object_id, schema_id, version,
				"commit_keyframe", RigidbodyStateSchema.snapshot(body, _epoch, _tick))
	if body.sleeping:
		return
	var interval := 0.0 if sample_hz <= 0.0 else 1.0 / sample_hz
	if interval <= 0.0 or _sample_accum >= interval:
		_sample_accum = 0.0
		_tick += 1
		var sample := RigidbodyStateSchema.snapshot(body, _epoch, _tick)
		sample["revision"] = maxi(0, NetworkManager.replicated_revision(object_id, schema_id))
		NetworkManager.send_replicated_sample(object_id, schema_id, version, sample)
	if keyframe_interval > 0.0 and _keyframe_accum >= keyframe_interval:
		_keyframe_accum = 0.0
		NetworkManager.request_replicated_command(object_id, schema_id, version,
				"commit_keyframe", RigidbodyStateSchema.snapshot(body, _epoch, _tick))


func _apply_proxy() -> void:
	if _suspended or not _body_in_live_tree() or _samples.is_empty():
		return
	var render_ms := Time.get_ticks_msec() - int(interpolation_delay * 1000.0)
	var before: Dictionary = _samples[0]
	var after: Dictionary = _samples[-1]
	for index in range(_samples.size() - 1):
		if int(_samples[index + 1].received_ms) >= render_ms:
			before = _samples[index]
			after = _samples[index + 1]
			break
	var transform: Transform3D
	if before == after:
		transform = RigidbodyStateSchema.unpack_transform(before.pose)
		if render_ms > int(before.received_ms):
			var dt := minf(CLIENT_EXTRAPOLATION_WINDOW,
					(render_ms - int(before.received_ms)) / 1000.0)
			transform.origin += RigidbodyStateSchema.unpack_vector(before.linear_velocity) * dt
	else:
		var span := maxi(1, int(after.received_ms) - int(before.received_ms))
		var weight := clampf(float(render_ms - int(before.received_ms)) / float(span), 0.0, 1.0)
		transform = _interpolate_transform(RigidbodyStateSchema.unpack_transform(before.pose),
				RigidbodyStateSchema.unpack_transform(after.pose), weight)
	body.global_transform = transform
	body.linear_velocity = RigidbodyStateSchema.unpack_vector(after.linear_velocity)
	body.angular_velocity = RigidbodyStateSchema.unpack_vector(after.angular_velocity)


func _on_state(received_object: String, received_schema: String, state: Dictionary,
		changed: Dictionary, _revision: int) -> void:
	if received_object != object_id or received_schema != schema_id:
		return
	if not _body_in_live_tree():
		return
	var epoch_changed := changed.has("simulation_epoch") \
			and int(state.get("simulation_epoch", 0)) != _epoch
	_apply_canonical(state, epoch_changed)


func _on_bindings(received_object: String, received_schema: String, _bindings: Dictionary,
		_changed: Dictionary, _revision: int) -> void:
	if received_object == object_id and received_schema == schema_id:
		if _body_in_live_tree():
			_refresh_role()


func _on_sample(_sender: int, received_object: String, received_schema: String,
		sample: Dictionary) -> void:
	if received_object != object_id or received_schema != schema_id or _local_simulator:
		return
	if int(sample.get("simulation_epoch", -1)) != _epoch:
		return
	if int(sample.get("revision", -1)) \
			< NetworkManager.replicated_revision(object_id, schema_id):
		return
	var sample_tick := int(sample.get("tick", -1))
	if sample_tick <= _last_sample_tick:
		return
	_last_sample_tick = sample_tick
	var entry := sample.duplicate(true)
	entry["received_ms"] = Time.get_ticks_msec()
	_samples.append(entry)
	while _samples.size() > 8:
		_samples.pop_front()


func _on_authority_changed(_authority: int, _is_me: bool) -> void:
	if not _body_in_live_tree():
		return
	_refresh_role()
	if auto_claim:
		_maybe_claim.call_deferred()


func _on_ghost_expired(user_id: String) -> void:
	# Presence recovery deliberately waits for the room's reconnect grace period. The
	# authority then performs the same atomic simulator+epoch+keyframe transaction as an
	# authored handoff; no second ownership mechanism is introduced for physics.
	if _body_in_live_tree() and auto_claim and simulator() == user_id \
			and (NetworkManager.has_authority() or NetworkManager.authority_id() == 0):
		_recover_from_keyframe.call_deferred()


func _on_command_result(request_id: int, accepted: bool, _code: String, _revision: int) -> void:
	if not _body_in_live_tree():
		return
	if request_id != _pending_handoff_request:
		return
	_pending_handoff_request = -1
	if accepted:
		return # canonical binding/delta завершит optimistic phase
	_optimistic = false
	_refresh_role()
	_apply_canonical(NetworkManager.replicated_state(object_id, schema_id), true)


func _apply_canonical(state: Dictionary, force_pose: bool) -> void:
	if state.is_empty() or not _body_in_live_tree():
		return
	_epoch = int(state.get("simulation_epoch", _epoch))
	_tick = maxi(_tick, int(state.get("tick", 0)))
	if force_pose or not _local_simulator:
		body.global_transform = RigidbodyStateSchema.unpack_transform(state.get("pose"))
		body.linear_velocity = RigidbodyStateSchema.unpack_vector(state.get("linear_velocity"))
		body.angular_velocity = RigidbodyStateSchema.unpack_vector(state.get("angular_velocity"))
		body.sleeping = bool(state.get("sleeping", false))
	if force_pose:
		_samples.clear()
		_last_sample_tick = -1


func _refresh_role(force := false) -> void:
	if not _body_in_live_tree():
		return
	var canonical_local := not Settings.user_id.is_empty() and simulator() == Settings.user_id
	if canonical_local:
		_optimistic = false
	var now_local := canonical_local or _optimistic
	if not force and _role_initialized and now_local == _local_simulator:
		return
	_role_initialized = true
	_local_simulator = now_local
	_samples.clear()
	_last_sample_tick = -1
	if _local_simulator:
		body.freeze = true if _suspended else _original_freeze
		_last_sleeping = body.sleeping
	else:
		body.freeze = true
		_apply_canonical(NetworkManager.replicated_state(object_id, schema_id), true)


func _maybe_claim() -> void:
	if _body_in_live_tree() and simulator().is_empty() \
			and (NetworkManager.has_authority() or NetworkManager.authority_id() == 0):
		claim()


func _request_handoff(command_name: String, args: Dictionary) -> int:
	if not _body_in_live_tree() or _pending_handoff_request >= 0:
		return -1
	var request_id := command(command_name, args)
	if request_id < 0:
		return request_id
	if simulator() != Settings.user_id:
		_pending_handoff_request = request_id
		_optimistic = true
		_refresh_role()
	return request_id


func _recover_from_keyframe() -> void:
	if not _body_in_live_tree():
		return
	var state := NetworkManager.replicated_state(object_id, schema_id)
	if state.is_empty():
		return
	_request_handoff("claim_simulation", {
		"pose": state.get("pose"),
		"linear_velocity": state.get("linear_velocity"),
		"angular_velocity": state.get("angular_velocity"),
		"sleeping": bool(state.get("sleeping", false)),
		"simulation_epoch": int(state.get("simulation_epoch", 0)),
		"tick": int(state.get("tick", 0)),
	})


func _body_in_live_tree() -> bool:
	return not _shutting_down and is_inside_tree() and not is_queued_for_deletion() \
			and body != null and is_instance_valid(body) and body.is_inside_tree() \
			and not body.is_queued_for_deletion()


static func _interpolate_transform(a: Transform3D, b: Transform3D, weight: float) -> Transform3D:
	var qa := a.basis.get_rotation_quaternion()
	var qb := b.basis.get_rotation_quaternion()
	return Transform3D(Basis(qa.slerp(qb, weight)), a.origin.lerp(b.origin, weight))
