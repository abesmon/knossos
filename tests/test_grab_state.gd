extends SceneTree

## Контракт нормативной машины hold-состояния grabbable (GrabStateSchema) на чистом
## ReplicatedStateStore, без сети/3D (docs/space/grabbable.md#машина-состояний).
## Запуск: godot --headless --path . --script res://tests/test_grab_state.gd

var _failed := false

const OID := "grab:ball"
const SID := GrabStateSchema.ID
const V := GrabStateSchema.VERSION


func _initialize() -> void:
	_test_grab_and_theft()
	_test_release_rules()
	_test_adjust_rules()
	_test_validation()
	_test_pose_helpers()
	quit(1 if _failed else 0)


func _store(theft: bool = true, adjustable: bool = false) -> ReplicatedStateStore:
	var store := ReplicatedStateStore.new()
	_eq(store.register_schema(SID, GrabStateSchema.definition(1 << 30)), true, "schema registered")
	_eq(store.ensure_object(OID, SID, {
		"rest": [1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 1.0],
		"theft": theft,
		"adjustable": adjustable,
	}), true, "object ensured")
	store.begin_authority()
	return store


func _ctx(user_id: String, is_authority := false) -> Dictionary:
	return {"peer_id": 1, "user_id": user_id, "rank": 1 << 30,
		"verified": false, "is_authority": is_authority, "authority_msec": 0}


func _grab(store: ReplicatedStateStore, user: String, hand := "right",
		grip: Variant = null) -> Dictionary:
	var g = grip if grip != null else GrabStateSchema.POSE_IDENTITY.duplicate()
	return store.commit_command(OID, SID, V, "grab", {"hand": hand, "grip": g}, _ctx(user))


func _test_grab_and_theft() -> void:
	var store := _store(true)
	var r := _grab(store, "alice")
	_eq(bool(r.get("ok")), true, "свободный предмет берётся")
	_eq(str(store.state_of(OID, SID)["holder_user_id"]), "alice", "holder = alice")
	_eq(str(store.state_of(OID, SID)["hand"]), "right", "hand = right")

	r = _grab(store, "")
	_eq(bool(r.get("ok")), false, "аноним (пустой user_id) держать не может")

	r = _grab(store, "bob", "left")
	_eq(bool(r.get("ok")), true, "theft=allow: перехват из чужой руки")
	_eq(str(store.state_of(OID, SID)["holder_user_id"]), "bob", "holder = bob после кражи")

	r = _grab(store, "bob", "right")
	_eq(bool(r.get("ok")), true, "держатель может перехватить сам у себя (смена руки)")
	_eq(str(store.state_of(OID, SID)["hand"]), "right", "рука сменилась")

	var protected := _store(false)
	_eq(bool(_grab(protected, "alice").get("ok")), true, "theft=deny: свободный всё равно берётся")
	_eq(bool(_grab(protected, "bob").get("ok")), false, "theft=deny: кража отклонена")
	_eq(str(protected.state_of(OID, SID)["holder_user_id"]), "alice", "holder не изменился")


func _test_release_rules() -> void:
	var store := _store()
	var rest := [5.0, 0.5, -2.0, 0.0, 0.0, 0.0, 1.0]
	var r := store.commit_command(OID, SID, V, "release", {"rest": rest}, _ctx("alice"))
	_eq(bool(r.get("ok")), false, "release свободного предмета отклонён")

	_grab(store, "alice")
	r = store.commit_command(OID, SID, V, "release", {"rest": rest}, _ctx("bob"))
	_eq(bool(r.get("ok")), false, "release не-держателем отклонён")

	r = store.commit_command(OID, SID, V, "release", {"rest": rest}, _ctx("alice"))
	_eq(bool(r.get("ok")), true, "release держателем принят")
	var state := store.state_of(OID, SID)
	_eq(str(state["holder_user_id"]), "", "предмет свободен")
	_eq(str(state["hand"]), "", "рука очищена")
	_eq(float((state["rest"] as Array)[0]), 5.0, "rest применён")

	_grab(store, "alice")
	r = store.commit_command(OID, SID, V, "release", {"rest": rest}, _ctx("moderator", true))
	_eq(bool(r.get("ok")), true, "авторитет может освободить принудительно (авто-release)")


func _test_adjust_rules() -> void:
	var moved := [0.0, 0.0, -1.5, 0.0, 0.0, 0.0, 1.0]

	var fixed := _store(true, false)
	_grab(fixed, "alice")
	var r := fixed.commit_command(OID, SID, V, "adjust", {"grip": moved}, _ctx("alice"))
	_eq(bool(r.get("ok")), false, "fixed: подстройка хвата отклонена (хват задан автором)")

	var adj := _store(true, true)
	r = adj.commit_command(OID, SID, V, "adjust", {"grip": moved}, _ctx("alice"))
	_eq(bool(r.get("ok")), false, "adjustable: подстройка свободного предмета отклонена")

	_grab(adj, "alice")
	r = adj.commit_command(OID, SID, V, "adjust", {"grip": moved}, _ctx("bob"))
	_eq(bool(r.get("ok")), false, "adjustable: подстройка не-держателем отклонена")

	r = adj.commit_command(OID, SID, V, "adjust", {"grip": moved}, _ctx("moderator", true))
	_eq(bool(r.get("ok")), false, "adjustable: даже авторитет не подстраивает чужой хват")

	r = adj.commit_command(OID, SID, V, "adjust", {"grip": moved}, _ctx("alice"))
	_eq(bool(r.get("ok")), true, "adjustable: держатель подстраивает хват")
	_eq(float((adj.state_of(OID, SID)["grip"] as Array)[2]), -1.5, "grip обновлён")
	_eq(str(adj.state_of(OID, SID)["holder_user_id"]), "alice", "держатель не изменился")

	r = adj.commit_command(OID, SID, V, "adjust", {"grip": [0.0, 0.0, 0.0]}, _ctx("alice"))
	_eq(bool(r.get("ok")), false, "adjustable: кривая поза хвата отклонена")


func _test_validation() -> void:
	var store := _store()
	var bad_grip := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]  # 6 элементов
	_eq(bool(_grab(store, "alice", "right", bad_grip).get("ok")), false, "grip не из 7 чисел отклонён")
	var degenerate := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]  # нулевой кватернион
	_eq(bool(_grab(store, "alice", "right", degenerate).get("ok")), false, "вырожденный кватернион отклонён")
	_eq(bool(_grab(store, "alice", "").get("ok")), false, "пустая рука отклонена")

	var long_hand := "h".repeat(64)
	_eq(bool(_grab(store, "alice", long_hand).get("ok")), false, "слишком длинное имя руки отклонено")

	# Открытый enum: неизвестное, но валидное имя руки принимается (рендер уйдёт в fallback-якорь).
	_eq(bool(_grab(store, "alice", "mouth").get("ok")), true, "неизвестная рука — принята (открытый enum)")

	_grab(store, "alice")
	var r := store.commit_command(OID, SID, V, "release",
			{"rest": [0.0, 0.0, 1e9, 0.0, 0.0, 0.0, 1.0]}, _ctx("alice"))
	_eq(bool(r.get("ok")), false, "rest за пределами MAX_POSE_ABS отклонён")


func _test_pose_helpers() -> void:
	var t := Transform3D(Basis(Vector3.UP, 1.25), Vector3(1, 2, 3))
	var packed := GrabStateSchema.pack_transform(t)
	_eq(packed.size(), 7, "pack даёт 7 компонент")
	var back := GrabStateSchema.unpack_transform(packed)
	_eq(back.origin.is_equal_approx(t.origin), true, "roundtrip: origin")
	_eq(back.basis.get_rotation_quaternion().is_equal_approx(
			t.basis.get_rotation_quaternion()), true, "roundtrip: rotation")
	_eq(GrabStateSchema.unpack_transform([]).is_equal_approx(Transform3D.IDENTITY), true,
			"кривая поза распаковывается в identity")
	# Ненормированный кватернион канонизируется при коммите.
	var store := _store()
	_grab(store, "alice", "right", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0])
	var grip: Array = store.state_of(OID, SID)["grip"]
	_eq(absf(float(grip[6]) - 1.0) < 0.0001, true, "кватернион grip нормирован в состоянии")


func _eq(actual, expected, what: String) -> void:
	if actual == expected:
		print("  OK  ", what)
	else:
		_failed = true
		printerr("FAIL  %s (ожидалось %s, получено %s)" % [what, str(expected), str(actual)])
