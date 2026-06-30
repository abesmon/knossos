extends Node

## Headless end-to-end проверка эфемерного слоя по РЕАЛЬНОМУ WebRTC mesh: два процесса через
## сигнальный сервер устанавливают p2p и гоняют action/event/snapshot. Роли по has_authority():
##   • Авторитет: создаёт объект AOWN (владелец — он), наблюдает.
##   • Актёр (не-авторитет): шлёт add/update/remove своих объектов + пробует remove ЧУЖОГО AOWN.
## Проверяет через публичные сигналы NetworkManager (scene_object_added/updated/removed):
##   действие актёра доезжает до авторитета и возвращается событием; владение защищено; TTL
##   истекает авторитетом. Запуск: VRWEB_SANDBOX=<id> godot --headless tests/net_scene_test.tscn -- <nick>
## Разные песочницы → разные user_id (нужно для проверки владения). Выход 0 — роль прошла.

var _nick := "t"
var _got_p2p := false
var _added := {}     # id -> object (через scene_object_added)
var _updated := {}   # id -> object
var _removed := {}   # id -> true


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_nick = args[0] if args.size() > 0 else "t"
	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _nick
	Settings.online_enabled = true

	NetworkManager.p2p_peer_connected.connect(func(id):
		_got_p2p = true
		print("[%s] P2P %d" % [_nick, id]))
	NetworkManager.scene_object_added.connect(func(id, obj):
		_added[id] = obj
		print("[%s] ADDED %s author=%s props=%s" % [_nick, id, obj.get("author", ""), obj.get("props", {})]))
	NetworkManager.scene_object_updated.connect(func(id, obj):
		_updated[id] = obj
		print("[%s] UPDATED %s props=%s" % [_nick, id, obj.get("props", {})]))
	NetworkManager.scene_object_removed.connect(func(id):
		_removed[id] = true
		print("[%s] REMOVED %s" % [_nick, id]))

	NetworkManager.connect_to_server()
	NetworkManager.join_room("sceneroom")

	var waited := 0.0
	while not _got_p2p and waited < 8.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	# Даём картам идентичности (user_id) разойтись — иначе author не проставится и владение поедет.
	await get_tree().create_timer(2.0).timeout

	if NetworkManager.has_authority():
		await _run_authority()
	else:
		await _run_actor()


func _run_authority() -> void:
	print("[%s] ROLE=authority" % _nick)
	NetworkManager.request_scene_action({
		"op": "add", "id": "AOWN", "kind": "bubble", "parent": "",
		"ttl": 0.0, "props": {"label": "owned-by-authority"}})
	# Наблюдаем, пока актёр отыгрывает свой сценарий.
	await get_tree().create_timer(12.0).timeout
	var saw_bown := _added.has("BOWN")
	var aown_survived := not NetworkManager.scene_object("AOWN").is_empty() and not _removed.has("AOWN")
	var saw_rm_bttl := _removed.has("BTTL")
	var saw_rm_bown := _removed.has("BOWN")
	var ok := saw_bown and aown_survived and saw_rm_bttl and saw_rm_bown
	print("[%s] RESULT role=authority pass=%s | bown_action_arrived=%s aown_survived_ownership=%s bttl_expired=%s bown_removed=%s" % [
		_nick, ok, saw_bown, aown_survived, saw_rm_bttl, saw_rm_bown])
	get_tree().quit(0 if ok else 1)


func _run_actor() -> void:
	print("[%s] ROLE=actor" % _nick)
	await get_tree().create_timer(0.5).timeout            # дать AOWN от авторитета долететь
	NetworkManager.request_scene_action({
		"op": "add", "id": "BOWN", "kind": "bubble", "parent": "",
		"ttl": 0.0, "props": {"label": "v1", "position": [1, 1.6, 5]}})
	await get_tree().create_timer(1.0).timeout
	NetworkManager.request_scene_action({"op": "update", "id": "BOWN", "props": {"label": "v2"}})
	NetworkManager.request_scene_action({
		"op": "add", "id": "BTTL", "kind": "bubble", "parent": "", "ttl": 2.0, "props": {}})
	# Проба владения: пытаемся удалить ЧУЖОЙ объект авторитета — должно быть отклонено.
	NetworkManager.request_scene_action({"op": "remove", "id": "AOWN"})
	await get_tree().create_timer(4.0).timeout            # BTTL должен истечь у авторитета
	NetworkManager.request_scene_action({"op": "remove", "id": "BOWN"})  # своё — можно
	await get_tree().create_timer(3.0).timeout

	var saw_bown_echo := _added.has("BOWN")
	var saw_aown := _added.has("AOWN")
	var saw_upd := _updated.has("BOWN") and str(_updated["BOWN"].get("props", {}).get("label", "")) == "v2"
	var saw_rm_bttl := _removed.has("BTTL")
	var saw_rm_bown := _removed.has("BOWN")
	var aown_not_removed := not _removed.has("AOWN")
	var ok := saw_bown_echo and saw_aown and saw_upd and saw_rm_bttl and saw_rm_bown and aown_not_removed
	print("[%s] RESULT role=actor pass=%s | bown_echo=%s aown_from_auth=%s update_applied=%s bttl_expired=%s bown_removed=%s ownership_held=%s" % [
		_nick, ok, saw_bown_echo, saw_aown, saw_upd, saw_rm_bttl, saw_rm_bown, aown_not_removed])
	get_tree().quit(0 if ok else 1)
