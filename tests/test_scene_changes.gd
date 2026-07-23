extends SceneTree

## Юнит-тест чистой машины состояний эфемерного слоя (SceneChanges) — без сети и 3D.
## Проверяет контракт: коммит действий, владение, каскад, порядок событий (epoch/seq),
## ресинк снимком, вложенность/цикл. Запуск:
##   godot --headless --path . --script res://tests/test_scene_changes.gd
## Выход 0 — все проверки прошли, иначе 1.

var _failed := false

const ALICE := "alice"
const BOB := "bob"


func _initialize() -> void:
	_test_add_and_creator_binding()
	_test_update_creator_only()
	_test_remove_cascade()
	_test_reparent_and_cycle()
	_test_nest_into_others_denied()
	_test_admin_override()
	_test_event_ordering_and_resync()
	_test_ttl_expire()
	_test_snapshot_roundtrip()
	_test_props_size_limit()
	_test_reserved_ids()
	_test_instance_config()
	quit(1 if _failed else 0)


# --- config-state: отдельная ACL, allowlist/schema, snapshot и снятие override ---
func _test_instance_config() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	var set_exclusive := {"op": SceneChanges.OP_UPDATE_CONFIG, "set": {"mode": "exclusive"}}
	_eq(sc.authority_commit(set_exclusive, ALICE, true, 100.0, false).size(), 0,
		"object-admin без config-права не меняет mode")
	var events := sc.authority_commit(set_exclusive, ALICE, false, 100.0, true)
	_eq(events.size(), 1, "config-право меняет mode")
	_eq(str(sc.config_attrs().get("mode", "")), "exclusive", "override хранится отдельно")
	_eq(str(sc.config().get("by", "")), ALICE, "инициатор сохранён для диагностики")
	_eq(sc.authority_commit(set_exclusive, ALICE, false, 101.0, true).size(), 0,
		"config no-op не расходует seq")
	_eq(sc.authority_commit({"op": SceneChanges.OP_UPDATE_CONFIG, "set": {"persist": "x"}},
		ALICE, false, 101.0, true).size(), 0, "неизвестный root key отклонён")
	_eq(sc.authority_commit({"op": SceneChanges.OP_UPDATE_CONFIG, "set": {"mode": "broken"}},
		ALICE, false, 101.0, true).size(), 0, "неверный mode отклонён")

	var follower := SceneChanges.new()
	follower.load_snapshot(sc.snapshot())
	_eq(str(follower.config_attrs().get("mode", "")), "exclusive", "snapshot переносит config")
	var clear_events := sc.authority_commit(
		{"op": SceneChanges.OP_UPDATE_CONFIG, "set": {"mode": null}}, BOB, false, 102.0, true)
	_eq(follower.apply_event(clear_events[0]), SceneChanges.Apply.APPLIED, "follower применил clear")
	_eq(follower.config_attrs().has("mode"), false, "null возвращает base mode")

	var poisoned := sc.snapshot()
	poisoned["config"] = {"attrs": {"mode": "invalid"}, "by": "mallory"}
	follower.load_snapshot(poisoned)
	_eq(follower.config_attrs().is_empty(), true, "невалидный snapshot config fail-closed")


# --- reserved_ids: id узлов базы страницы занять нельзя (анти-коллизия дедупа персистенции,
# см. docs/page-persistence.md) ---
func _test_reserved_ids() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.reserved_ids = {"n0-2": true, "lamp": true}
	_eq(sc.authority_commit(_add("n0-2", "vrweb-node", "", {"tag": "Node3D", "attrs": {}}),
		ALICE, false, 100.0).size(), 0, "add с id узла базы отклонён")
	_eq(sc.authority_commit(_add("lamp", "bubble", "", {}), ALICE, false, 100.0).size(), 0,
		"резерв не зависит от kind")
	_eq(sc.authority_commit(_add("u1.1", "vrweb-node", "page:n0-2", {"tag": "Node3D", "attrs": {}}),
		ALICE, false, 100.0).size(), 1, "свободный id проходит (в т.ч. с якорем на зарезервированный узел)")


# --- add + creator binding ---
func _test_add_and_creator_binding() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	var ev := sc.authority_commit(_add("a1", "bubble", "", {"url": "x"}), ALICE, false, 100.0)
	_eq(ev.size(), 1, "add → одно событие")
	_eq(str(ev[0]["op"]), "add", "op=add")
	_eq(int(ev[0]["seq"]), 1, "seq=1")
	var obj := sc.get_object("a1")
	_eq(str((obj.get("bindings", {}) as Dictionary).get("creator", "")), ALICE,
			"creator binding проставлен авторитетом")
	_eq(float(obj.get("ts", 0)), 100.0, "ts проставлен")
	# Чужой не может занять существующий id (анти-хайджек).
	_eq(sc.authority_commit(_add("a1", "bubble", "", {}), BOB, false, 101.0).size(), 0, "повтор id отклонён")


# --- update только владельцем ---
func _test_update_creator_only() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.authority_commit(_add("a1", "bubble", "", {"label": "hi"}), ALICE, false, 100.0)
	# Боб не владелец — отказ.
	_eq(sc.authority_commit(_upd("a1", {"label": "hax"}), BOB, false, 101.0).size(), 0, "чужой update отклонён")
	_eq(str(sc.get_object("a1")["props"]["label"]), "hi", "props не тронуты")
	# Алиса — владелец — патч мёржится, null удаляет ключ.
	var ev := sc.authority_commit(_upd("a1", {"label": "bye", "extra": 1}), ALICE, false, 102.0)
	_eq(ev.size(), 1, "свой update применён")
	_eq(str(ev[0]["op"]), "update", "op=update")
	_eq(str(sc.get_object("a1")["props"]["label"]), "bye", "label обновлён")
	sc.authority_commit(_upd("a1", {"extra": null}), ALICE, false, 103.0)
	_eq(sc.get_object("a1")["props"].has("extra"), false, "null-патч удалил ключ")


# --- remove с каскадом потомков ---
func _test_remove_cascade() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.authority_commit(_add("p", "g", "", {}), ALICE, false, 100.0)
	sc.authority_commit(_add("c1", "g", "p", {}), ALICE, false, 100.0)
	sc.authority_commit(_add("c2", "g", "c1", {}), ALICE, false, 100.0)
	var ev := sc.authority_commit(_rm("p"), ALICE, false, 101.0)
	_eq(ev.size(), 3, "каскад: 3 события удаления (p,c1,c2)")
	# Листья удаляются раньше родителя.
	_eq(str(ev[0]["id"]), "c2", "сначала самый глубокий потомок")
	_eq(str(ev[2]["id"]), "p", "родитель — последним")
	_eq(sc.has_object("c1"), false, "потомок снят")
	_eq(sc.has_object("p"), false, "узел снят")


# --- reparent + защита от цикла ---
func _test_reparent_and_cycle() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.authority_commit(_add("p", "g", "", {}), ALICE, false, 100.0)
	sc.authority_commit(_add("c", "g", "p", {}), ALICE, false, 100.0)
	# Перемонтировать c в корень — ок.
	var ev := sc.authority_commit(_reparent_action("c", ""), ALICE, false, 101.0)
	_eq(ev.size(), 1, "reparent применён")
	_eq(str(sc.get_object("c")["parent"]), "", "родитель = корень")
	# Сделать p ребёнком c, а потом c ребёнком p — цикл, отказ.
	sc.authority_commit(_reparent_action("c", "p"), ALICE, false, 102.0)
	_eq(sc.authority_commit(_reparent_action("p", "c"), ALICE, false, 103.0).size(), 0, "цикл отклонён")


# --- нельзя вкладывать в ЧУЖОЙ объект ---
func _test_nest_into_others_denied() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.authority_commit(_add("a", "g", "", {}), ALICE, false, 100.0)
	# Боб пытается добавить ребёнка в объект Алисы — отказ.
	_eq(sc.authority_commit(_add("b", "g", "a", {}), BOB, false, 101.0).size(), 0, "вложение в чужое отклонено")
	# В корень — можно.
	_eq(sc.authority_commit(_add("b", "g", "", {}), BOB, false, 102.0).size(), 1, "в корень — ок")


# --- админ обходит проверку владения ---
func _test_admin_override() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.authority_commit(_add("a", "g", "", {}), ALICE, false, 100.0)
	# Боб-админ может править/удалять чужое.
	_eq(sc.authority_commit(_upd("a", {"x": 1}), BOB, true, 101.0).size(), 1, "админ правит чужое")
	_eq(sc.authority_commit(_rm("a"), BOB, true, 102.0).size(), 1, "админ удаляет чужое")


# --- follower: порядок событий, дубликат, пропуск→GAP ---
func _test_event_ordering_and_resync() -> void:
	var auth := SceneChanges.new()
	auth.begin_authority()
	# Снимок ДО событий: эпоха установлена, seq=0 — им новичок выравнивается на старт потока
	# (в проде это push снимка авторитетом при p2p-connect). Бесснимочный follower эпоху не угадает.
	var base := auth.snapshot()
	var e1: Dictionary = auth.authority_commit(_add("a", "bubble", "", {}), ALICE, false, 100.0)[0]
	var e2: Dictionary = auth.authority_commit(_add("b", "bubble", "", {}), ALICE, false, 100.0)[0]
	var e3: Dictionary = auth.authority_commit(_add("c", "bubble", "", {}), ALICE, false, 100.0)[0]
	# Бесснимочный follower (epoch 0) видит более новую эпоху → GAP: обязан сперва ресинкнуться.
	var fresh := SceneChanges.new()
	_eq(fresh.apply_event(e1), SceneChanges.Apply.GAP, "новая эпоха без снимка → GAP")
	# Выровненный снимком follower применяет поток по порядку.
	var f := SceneChanges.new()
	f.load_snapshot(base)
	_eq(f.apply_event(e1), SceneChanges.Apply.APPLIED, "e1 применён")
	_eq(f.apply_event(e1), SceneChanges.Apply.IGNORED, "дубликат e1 проигнорирован")
	# Пропускаем e2 → e3 даёт GAP (нужен снимок).
	_eq(f.apply_event(e3), SceneChanges.Apply.GAP, "пропуск → GAP")
	_eq(f.has_object("c"), false, "событие из дыры не применено")
	# Доезжает e2, затем e3 — оба применяются.
	_eq(f.apply_event(e2), SceneChanges.Apply.APPLIED, "e2 доехал")
	_eq(f.apply_event(e3), SceneChanges.Apply.APPLIED, "e3 после e2")
	_eq(f.has_object("c"), true, "c появился")


# --- TTL истекает каскадом ---
func _test_ttl_expire() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	sc.authority_commit(_add_ttl("a", 30.0, ""), ALICE, false, 100.0)
	sc.authority_commit(_add_ttl("c", 30.0, "a"), ALICE, false, 100.0)
	sc.authority_commit(_add_ttl("perm", 0.0, ""), ALICE, false, 100.0)
	_eq(sc.expire(120.0).size(), 0, "до TTL ничего не истекает")
	var ev := sc.expire(131.0)
	_eq(ev.size(), 2, "истёк a с потомком c")
	_eq(sc.has_object("perm"), true, "ttl=0 не истекает")


# --- снимок: round-trip + продолжение эпохи у нового авторитета ---
func _test_snapshot_roundtrip() -> void:
	var auth := SceneChanges.new()
	auth.begin_authority()
	auth.authority_commit(_add("a", "bubble", "", {"k": "v"}), ALICE, false, 100.0)
	var snap := auth.snapshot()
	var f := SceneChanges.new()
	f.load_snapshot(snap)
	_eq(f.has_object("a"), true, "снимок перенёс объект")
	_eq(int(f.epoch()), int(auth.epoch()), "эпоха перенесена")
	# Новый авторитет (бывший follower) поднимает эпоху строго выше виденной.
	f.begin_authority()
	var ev := f.authority_commit(_add("b", "bubble", "", {}), BOB, false, 200.0)
	_gt(int(ev[0]["epoch"]), int(auth.epoch()), "новая эпоха выше старой")


# --- лимит размера props ---
func _test_props_size_limit() -> void:
	var sc := SceneChanges.new()
	sc.begin_authority()
	var big := ""
	for i in range(10000):
		big += "x"
	_eq(sc.authority_commit(_add("a", "bubble", "", {"blob": big}), ALICE, false, 100.0).size(), 0, "огромные props отклонены")


# --- хелперы построения действий ---
func _add(id: String, kind: String, parent: String, props: Dictionary) -> Dictionary:
	return {"op": "add", "id": id, "kind": kind, "parent": parent, "props": props, "ttl": 0.0}

func _add_ttl(id: String, ttl: float, parent: String) -> Dictionary:
	return {"op": "add", "id": id, "kind": "g", "parent": parent, "props": {}, "ttl": ttl}

func _upd(id: String, patch: Dictionary) -> Dictionary:
	return {"op": "update", "id": id, "props": patch}

func _rm(id: String) -> Dictionary:
	return {"op": "remove", "id": id}

func _reparent_action(id: String, parent: String) -> Dictionary:
	return {"op": "reparent", "id": id, "parent": parent}


# --- ассерты ---
func _eq(actual, expected, msg: String) -> void:
	if actual != expected:
		_failed = true
		push_error("FAIL: %s (got %s, expected %s)" % [msg, str(actual), str(expected)])

func _gt(actual: int, threshold: int, msg: String) -> void:
	if not (actual > threshold):
		_failed = true
		push_error("FAIL: %s (got %d, expected > %d)" % [msg, actual, threshold])
