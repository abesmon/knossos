extends Node

## Headless-тест сетевого слоя: два процесса соединяются через сигнальный сервер,
## устанавливают WebRTC mesh и обмениваются позицией (state) и чатом по RPC.
## Запуск: godot --headless tests/net_test.tscn -- <nick>
## Выход 0, если получены и чат, и состояние от другого пира; иначе 1.

var _got_chat := false
var _got_state := false
var _nick := "t"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_nick = args[0] if args.size() > 0 else "t"

	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _nick
	Settings.online_enabled = true

	NetworkManager.peer_joined.connect(func(id, nick): print("[%s] PEER_JOINED %d %s" % [_nick, id, nick]))
	NetworkManager.peer_left.connect(func(id): print("[%s] PEER_LEFT %d" % [_nick, id]))
	NetworkManager.connection_changed.connect(func(o): print("[%s] CONN online=%s" % [_nick, o]))
	NetworkManager.chat_received.connect(_on_chat)
	NetworkManager.state_received.connect(_on_state)

	NetworkManager.connect_to_server()
	NetworkManager.join_room("testroom")

	await get_tree().create_timer(3.0).timeout
	NetworkManager.send_chat("hello from %s" % _nick)

	# Шлём позицию ~5 секунд, чтобы дать handshake завершиться.
	for i in range(50):
		NetworkManager.send_state(Vector3(i, 0, 0), 0.0)
		await get_tree().create_timer(0.1).timeout

	await get_tree().create_timer(1.0).timeout
	print("[%s] RESULT chat=%s state=%s" % [_nick, _got_chat, _got_state])
	get_tree().quit(0 if (_got_chat and _got_state) else 1)


func _on_chat(id: int, text: String) -> void:
	_got_chat = true
	print("[%s] CHAT from %d: %s" % [_nick, id, text])


func _on_state(id: int, pos: Vector3, _yaw: float) -> void:
	if not _got_state:
		print("[%s] STATE from %d: %s" % [_nick, id, pos])
		_got_state = true
