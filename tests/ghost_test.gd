extends Node

## Headless-тест защиты от «морганий» (см. docs/multiplayer.md → «Переподключения…»).
## Два процесса и два сценария в одном: роль передаётся user-аргументом.
##
## stayer  — сидит в комнате ~20 c и логирует события (GHOSTED/RECLAIMED/EXPIRED/PEER_LEFT).
##           Выход 0, если: за время «сохранения настроек» флаппера не было PEER_LEFT,
##           после его реального ухода пришёл peer_ghosted, а после перезапуска — peer_reclaimed.
## flapper — заходит, через 3 c имитирует «Сохранить» в настройках (join_room той же комнаты +
##           broadcast_identity — как main._on_settings_changed), через 6 c выходит.
##           В логе должен быть ровно ОДИН «send join» (join_room идемпотентен).
## flapper2 — перезапуск флаппера в grace-окне (та же песочница = тот же user_id).
##
## Запуск (см. сценарий в docs): сигналинг на :8090, затем
##   VRWEB_SANDBOX=A godot --headless tests/ghost_test.tscn -- stayer
##   VRWEB_SANDBOX=B godot --headless tests/ghost_test.tscn -- flapper
##   (через ~4 c после выхода флаппера) VRWEB_SANDBOX=B ... -- flapper2

var _role := "stayer"
var _saw_left_early := false
var _got_ghosted := false
var _got_reclaimed := false
var _got_expired := false
var _flapper_quit_at := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if args.size() > 0 else "stayer"

	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _role
	Settings.online_enabled = true

	NetworkManager.peer_joined.connect(func(id, nick): _log("PEER_JOINED %d %s" % [id, nick]))
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.p2p_peer_connected.connect(func(id): _log("P2P_CONNECTED %d" % id))
	NetworkManager.identity_received.connect(func(id, nick, _f, _a): _log("IDENTITY %d %s uid=%s" % [id, nick, NetworkManager.user_id_of(id)]))
	NetworkManager.peer_ghosted.connect(func(uid, pid, nick):
		_got_ghosted = true
		_log("GHOSTED uid=%s peer=%d nick=%s" % [uid, pid, nick]))
	NetworkManager.ghost_expired.connect(func(uid):
		_got_expired = true
		_log("GHOST_EXPIRED uid=%s" % uid))
	NetworkManager.peer_reclaimed.connect(func(uid, pid):
		_got_reclaimed = true
		_log("RECLAIMED uid=%s -> peer=%d" % [uid, pid]))

	NetworkManager.connect_to_server()
	NetworkManager.join_room("ghostroom")

	match _role:
		"stayer":
			await _run_stayer()
		"flapper":
			await _run_flapper()
		"flapper2":
			await _run_flapper2()


## Реальный уход пира с известным uid должен идти ПОСЛЕ peer_ghosted; уход в первые 5 c
## (фаза «сохранения настроек» флаппера) — регрессия идемпотентности join_room.
func _on_peer_left(id: int) -> void:
	_log("PEER_LEFT %d" % id)
	if Time.get_ticks_msec() < 5000:
		_saw_left_early = true


func _run_stayer() -> void:
	await get_tree().create_timer(20.0).timeout
	var ok := not _saw_left_early and _got_ghosted and _got_reclaimed and not _got_expired
	_log("RESULT early_left=%s ghosted=%s reclaimed=%s expired=%s -> %s" % [
		_saw_left_early, _got_ghosted, _got_reclaimed, _got_expired, "OK" if ok else "FAIL"])
	get_tree().quit(0 if ok else 1)


func _run_flapper() -> void:
	await get_tree().create_timer(3.0).timeout
	_log("SIMULATE SETTINGS SAVE (join_room same + broadcast_identity)")
	NetworkManager.connect_to_server()
	NetworkManager.join_room("ghostroom")
	NetworkManager.broadcast_identity()
	await get_tree().create_timer(3.0).timeout
	_log("QUIT (реальный уход -> stayer должен увидеть GHOSTED)")
	get_tree().quit(0)


func _run_flapper2() -> void:
	# Перезаход в grace-окне: stayer должен увидеть RECLAIMED по нашему user_id.
	await get_tree().create_timer(6.0).timeout
	_log("DONE")
	get_tree().quit(0)


func _log(msg: String) -> void:
	print("[%s t=%d] %s" % [_role, Time.get_ticks_msec(), msg])
