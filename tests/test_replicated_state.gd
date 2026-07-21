extends SceneTree

const PolicyEvaluatorImpl = preload("res://scripts/network/policy_evaluator.gd")

## Контракт чистого ReplicatedStateStore без RPC.
## Запуск: godot --headless --path . --script res://tests/test_replicated_state.gd

var _failed := false


func _initialize() -> void:
	_test_access_rules()
	_test_command_delta_and_snapshot()
	_test_atomic_binding_transaction()
	_test_snapshot_before_schema()
	_test_validation_and_gap()
	_test_size_budgets()
	_test_state_switch_consumer()
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
			"claim_presenter": {"reducer": Callable(self, "_reduce_claim_presenter")},
			"invalid_claim": {"reducer": Callable(self, "_reduce_invalid_claim")},
			"creator_set": {
				"write_rule": {"any_of": ["authority", {"assigned": "creator"}]},
				"reducer": Callable(self, "_reduce_set"),
			},
		},
	}


func _reduce_set(_state: Dictionary, args: Dictionary, _context: Dictionary) -> Dictionary:
	if typeof(args.get("value")) not in [TYPE_FLOAT, TYPE_INT]:
		return {}
	return {"state": {"value": float(args["value"]), "enabled": true}}


func _reduce_payload(_state: Dictionary, args: Dictionary, _context: Dictionary) -> Dictionary:
	return {"state": args.duplicate()}


func _reduce_claim_presenter(_state: Dictionary, _args: Dictionary,
		context: Dictionary) -> Dictionary:
	return {"state": {"enabled": true},
		"bindings": {"presenter": str(context.get("actor_user_id", ""))}}


func _reduce_invalid_claim(_state: Dictionary, _args: Dictionary,
		_context: Dictionary) -> Dictionary:
	return {"state": {"enabled": true}, "bindings": {"invalid-slot": "alice"}}


func _test_size_budgets() -> void:
	var store := ReplicatedStateStore.new()
	var schema := {
		"version": 1,
		"fields": {
			"p0": {"type": "string", "default": "", "max_bytes": 4096},
			"p1": {"type": "string", "default": "", "max_bytes": 4096},
			"p2": {"type": "string", "default": "", "max_bytes": 4096},
			"p3": {"type": "string", "default": "", "max_bytes": 4096},
			"p4": {"type": "string", "default": "", "max_bytes": 4096},
		},
		"default_write_rule": "authority",
		"commands": {"set": {"reducer": Callable(self, "_reduce_payload")}},
	}
	_eq(store.register_schema("large", schema), true, "large schema registered")
	var large_patch := {}
	for i in range(5): large_patch["p%d" % i] = "x".repeat(3500)
	_eq(store.ensure_object("oversized", "large", large_patch), false,
			"oversized initial object rejected")
	_eq(store.ensure_object("normal", "large"), true, "normal object accepted")
	store.begin_authority()
	var result := store.commit_command("normal", "large", 1, "set",
			large_patch, {"is_authority": true})
	_eq(result.get("error"), "too_large", "oversized resulting object rejected atomically")
	_eq(str(store.state_of("normal", "large")["p0"]), "", "oversized patch did not mutate state")


func _test_state_switch_consumer() -> void:
	var store := ReplicatedStateStore.new()
	var schema := {
		"version": 1,
		"fields": {"enabled": {"type": "bool", "default": false}},
		"default_write_rule": {"rank": {"op": "lte", "value": 100}},
		"commands": {"toggle": {"reducer": Callable(self, "_reduce_toggle")}},
	}
	_eq(store.register_schema("demo.light-switch", schema), true,
			"state switch schema registered")
	_eq(store.ensure_object("lamp", "demo.light-switch"), true, "state switch object registered")
	store.begin_authority()
	var context := {"rank": 100, "is_authority": false}
	var on := store.commit_command("lamp", "demo.light-switch", 1,
			"toggle", {}, context)
	_eq(on.get("ok"), true, "state switch toggled on")
	_eq(store.state_of("lamp", "demo.light-switch")["enabled"], true, "enabled=true")
	var off := store.commit_command("lamp", "demo.light-switch", 1,
			"toggle", {}, context)
	_eq(off.get("ok"), true, "state switch toggled off")
	_eq(store.state_of("lamp", "demo.light-switch")["enabled"], false, "enabled=false")
	_eq(int(off["delta"]["revision"]), 2, "second consumer uses generic revision")


func _reduce_toggle(state: Dictionary, _args: Dictionary, _context: Dictionary) -> Dictionary:
	return {"state": {"enabled": not bool(state.get("enabled", false))}}


func _test_access_rules() -> void:
	var base := {"rank": 10, "actor_user_id": "alice",
			"bindings": {"creator": "alice"}, "verified": true}
	_eq(PolicyEvaluatorImpl.evaluate({"rank": {"op": "lt", "value": 11}}, base), true, "rank lt")
	_eq(PolicyEvaluatorImpl.evaluate({"rank": {"op": "eq", "value": 10}}, base), true, "rank exact")
	_eq(PolicyEvaluatorImpl.evaluate({"rank": {"op": "gte", "value": 11}}, base), false, "rank gte")
	_eq(PolicyEvaluatorImpl.evaluate({"all_of": [{"assigned": "creator"}, "verified_identity"]}, base), true, "all_of")
	_eq(PolicyEvaluatorImpl.evaluate({"any_of": ["authority", {"rank": {"op": "lte", "value": 10}}]}, base), true, "any_of")
	_eq(PolicyEvaluatorImpl.evaluate({"vacant": "holder"}, base), true, "vacant")
	_eq(PolicyEvaluatorImpl.evaluate("unknown", base), false, "unknown predicate deny")
	_eq(PolicyEvaluatorImpl.evaluate({"not": "unknown"}, base), false,
			"unknown predicate remains deny under not")
	_eq(PolicyEvaluatorImpl.evaluate({"rank": {"op": "lte", "value": "10"}}, base), false,
			"malformed rank fails closed")


func _test_command_delta_and_snapshot() -> void:
	var authority := ReplicatedStateStore.new()
	_eq(authority.register_schema("test", _schema()), true, "schema registered")
	_eq(authority.ensure_object("one", "test", {}, {"creator": "alice"}), true, "object registered")
	authority.begin_authority()
	var base := authority.snapshot()
	var result := authority.commit_command("one", "test", 1, "set", {"value": 42.0},
			{"rank": 10, "actor_user_id": "bob", "is_authority": false})
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


func _test_atomic_binding_transaction() -> void:
	var authority := ReplicatedStateStore.new()
	authority.register_schema("binding-test", _schema())
	authority.ensure_object("stage", "binding-test")
	authority.begin_authority()
	var binding_events := []
	authority.bindings_changed.connect(func(_object, _schema, current, changed, revision):
		binding_events.append({"current": current, "changed": changed, "revision": revision}))
	var result := authority.commit_command("stage", "binding-test", 1, "claim_presenter", {},
			{"rank": 0, "actor_user_id": "alice", "is_authority": true})
	_eq(result.get("ok"), true, "state and custom binding committed")
	_eq(authority.bindings_of("stage", "binding-test").get("presenter"), "alice",
			"custom binding stored")
	_eq(authority.state_of("stage", "binding-test").get("enabled"), true,
			"state committed in same revision")
	_eq(result["delta"]["binding_changes"].get("presenter"), "alice",
			"binding replicated in delta")
	_eq(binding_events.size(), 1, "binding event emitted")
	_eq(binding_events[0].revision, 1, "binding and state share revision")

	var before_state := authority.state_of("stage", "binding-test")
	var before_bindings := authority.bindings_of("stage", "binding-test")
	var invalid := authority.commit_command("stage", "binding-test", 1, "invalid_claim", {},
			{"rank": 0, "actor_user_id": "alice", "is_authority": true})
	_eq(invalid.get("error"), "invalid_patch", "invalid slot rejects entire transaction")
	_eq(authority.state_of("stage", "binding-test"), before_state,
			"invalid binding does not partially mutate state")
	_eq(authority.bindings_of("stage", "binding-test"), before_bindings,
			"invalid binding does not partially mutate bindings")

	var follower := ReplicatedStateStore.new()
	follower.register_schema("binding-test", _schema())
	var initial := ReplicatedStateStore.new()
	initial.register_schema("binding-test", _schema())
	initial.ensure_object("stage", "binding-test")
	initial.begin_authority()
	_eq(follower.apply_snapshot(initial.snapshot()), true, "binding follower loaded base")
	_eq(follower.apply_delta(result.delta), "ok", "binding transaction delta applied")
	_eq(follower.bindings_of("stage", "binding-test").get("presenter"), "alice",
			"custom binding converged")


## Реальный порядок late join: сетевой snapshot приходит раньше, чем страница загрузилась и
## её consumer зарегистрировал схему. Канон нельзя терять только из-за порядка lifecycle.
func _test_snapshot_before_schema() -> void:
	var authority := ReplicatedStateStore.new()
	authority.register_schema("late.tool", _schema())
	authority.ensure_object("held-pencil", "late.tool")
	authority.begin_authority()
	authority.commit_command("held-pencil", "late.tool", 1, "set", {"value": 7.0},
			{"rank": 0, "actor_user_id": "holder", "is_authority": true})

	var late := ReplicatedStateStore.new()
	var received := []
	late.state_changed.connect(func(object_id, schema_id, state, _changed, revision):
		received.append({"object": object_id, "schema": schema_id,
				"state": state, "revision": revision}))
	_eq(late.apply_snapshot(authority.snapshot()), true,
			"snapshot accepted before consumer schema exists")
	_eq(late.revision_of("held-pencil", "late.tool"), -1,
			"unknown schema remains hidden before registration")
	_eq(late.register_schema("late.tool", _schema()), true, "late consumer schema registered")
	_eq(late.ensure_object("held-pencil", "late.tool"), true, "late consumer object registered")
	_eq(late.revision_of("held-pencil", "late.tool"), 1,
			"deferred snapshot record materialized with canonical revision")
	_eq(float(late.state_of("held-pencil", "late.tool")["value"]), 7.0,
			"deferred snapshot preserves canonical state")
	_eq(received.size(), 1, "materialized state emitted once to consumer")


func _test_validation_and_gap() -> void:
	var authority := ReplicatedStateStore.new()
	authority.register_schema("test", _schema())
	authority.ensure_object("one", "test", {}, {"creator": "alice"})
	authority.begin_authority()
	var denied := authority.commit_command("one", "test", 1, "set", {"value": 1.0},
			{"rank": 11, "actor_user_id": "bob", "is_authority": false})
	_eq(denied.get("error"), "access_denied", "rank denied")
	var owner := authority.commit_command("one", "test", 1, "creator_set", {"value": 2.0},
			{"rank": 999, "actor_user_id": "alice", "is_authority": false})
	_eq(owner.get("ok"), true, "creator binding allowed")
	var invalid := authority.commit_command("one", "test", 1, "set", {"value": 101.0},
			{"rank": 0, "actor_user_id": "admin", "is_authority": true})
	_eq(invalid.get("error"), "invalid_patch", "field limit enforced")

	var fresh := ReplicatedStateStore.new()
	fresh.register_schema("test", _schema())
	fresh.ensure_object("one", "test")
	_eq(fresh.apply_delta(owner["delta"]), "gap", "new epoch requires snapshot")


func _eq(actual, expected, message: String) -> void:
	if actual != expected:
		_failed = true
		push_error("FAIL: %s (got %s, expected %s)" % [message, str(actual), str(expected)])
