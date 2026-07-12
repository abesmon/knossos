extends SceneTree

## Контракт чистого ReplicatedStateStore без RPC.
## Запуск: godot --headless --path . --script res://tests/test_replicated_state.gd

var _failed := false


func _initialize() -> void:
	_test_access_rules()
	_test_command_delta_and_snapshot()
	_test_validation_and_gap()
	quit(1 if _failed else 0)


func _schema() -> Dictionary:
	return {
		"version": 1,
		"fields": {
			"enabled": {"type": "bool", "default": false},
			"value": {"type": "float", "default": 0.0, "min": 0.0, "max": 100.0},
		},
		"default_write_rule": {"rank": {"op": "lte", "value": 10}},
		"commands": {
			"set": {"reducer": Callable(self, "_reduce_set")},
			"owner_set": {
				"write_rule": {"any_of": ["authority", "object_owner"]},
				"reducer": Callable(self, "_reduce_set"),
			},
		},
	}


func _reduce_set(_state: Dictionary, args: Dictionary, _context: Dictionary) -> Dictionary:
	if typeof(args.get("value")) not in [TYPE_FLOAT, TYPE_INT]:
		return {}
	return {"value": float(args["value"]), "enabled": true}


func _test_access_rules() -> void:
	var base := {"rank": 10, "user_id": "alice", "owner_user_id": "alice", "verified": true}
	_eq(ReplicatedStateStore.evaluate_rule({"rank": {"op": "lt", "value": 11}}, base), true, "rank lt")
	_eq(ReplicatedStateStore.evaluate_rule({"rank": {"op": "eq", "value": 10}}, base), true, "rank exact")
	_eq(ReplicatedStateStore.evaluate_rule({"rank": {"op": "gte", "value": 11}}, base), false, "rank gte")
	_eq(ReplicatedStateStore.evaluate_rule({"all_of": ["object_owner", "verified_identity"]}, base), true, "all_of")
	_eq(ReplicatedStateStore.evaluate_rule({"any_of": ["authority", {"rank": {"op": "lte", "value": 10}}]}, base), true, "any_of")
	_eq(ReplicatedStateStore.evaluate_rule("unknown", base), false, "unknown predicate deny")


func _test_command_delta_and_snapshot() -> void:
	var authority := ReplicatedStateStore.new()
	_eq(authority.register_schema("test", _schema()), true, "schema registered")
	_eq(authority.ensure_object("one", "test", {}, "alice"), true, "object registered")
	authority.begin_authority()
	var base := authority.snapshot()
	var result := authority.commit_command("one", "test", 1, "set", {"value": 42.0},
			{"rank": 10, "user_id": "bob", "is_authority": false})
	_eq(result.get("ok"), true, "allowed command committed")
	_eq(authority.revision_of("one", "test"), 1, "revision incremented")

	var follower := ReplicatedStateStore.new()
	follower.register_schema("test", _schema())
	_eq(follower.apply_snapshot(base), true, "base snapshot loaded")
	_eq(follower.apply_delta(result["delta"]), "ok", "delta applied")
	_eq(float(follower.state_of("one", "test")["value"]), 42.0, "state converged")
	_eq(follower.apply_delta(result["delta"]), "duplicate", "duplicate ignored")

	var late := ReplicatedStateStore.new()
	late.register_schema("test", _schema())
	_eq(late.apply_snapshot(authority.snapshot()), true, "late join snapshot loaded")
	_eq(float(late.state_of("one", "test")["value"]), 42.0, "late join state complete")


func _test_validation_and_gap() -> void:
	var authority := ReplicatedStateStore.new()
	authority.register_schema("test", _schema())
	authority.ensure_object("one", "test", {}, "alice")
	authority.begin_authority()
	var denied := authority.commit_command("one", "test", 1, "set", {"value": 1.0},
			{"rank": 11, "user_id": "bob", "is_authority": false})
	_eq(denied.get("error"), "access_denied", "rank denied")
	var owner := authority.commit_command("one", "test", 1, "owner_set", {"value": 2.0},
			{"rank": 999, "user_id": "alice", "is_authority": false})
	_eq(owner.get("ok"), true, "object owner allowed")
	var invalid := authority.commit_command("one", "test", 1, "set", {"value": 101.0},
			{"rank": 0, "user_id": "admin", "is_authority": true})
	_eq(invalid.get("error"), "invalid_patch", "field limit enforced")

	var fresh := ReplicatedStateStore.new()
	fresh.register_schema("test", _schema())
	fresh.ensure_object("one", "test")
	_eq(fresh.apply_delta(owner["delta"]), "gap", "new epoch requires snapshot")


func _eq(actual, expected, message: String) -> void:
	if actual != expected:
		_failed = true
		push_error("FAIL: %s (got %s, expected %s)" % [message, str(actual), str(expected)])
