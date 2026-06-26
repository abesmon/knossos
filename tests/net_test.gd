extends Node

## Headless-тест сетевого слоя: два процесса соединяются через сигнальный сервер,
## устанавливают WebRTC mesh и обмениваются позицией (state) и чатом по RPC.
## Запуск: godot --headless tests/net_test.tscn -- <nick>
## Выход 0, если получены и чат, и состояние от другого пира; иначе 1.

var _got_chat := false
var _got_state := false
var _got_face := false
var _got_p2p := false
var _nick := "t"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_nick = args[0] if args.size() > 0 else "t"

	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _nick
	Settings.online_enabled = true

	NetworkManager.peer_joined.connect(func(id, nick): print("[%s] PEER_JOINED %d %s" % [_nick, id, nick]))
	NetworkManager.peer_left.connect(func(id): print("[%s] PEER_LEFT %d" % [_nick, id]))
	NetworkManager.p2p_peer_connected.connect(func(id):
		_got_p2p = true
		print("[%s] P2P_CONNECTED %d" % [_nick, id])
	)
	NetworkManager.p2p_peer_disconnected.connect(func(id): print("[%s] P2P_DISCONNECTED %d" % [_nick, id]))
	NetworkManager.connection_changed.connect(func(o): print("[%s] CONN online=%s" % [_nick, o]))
	NetworkManager.chat_received.connect(_on_chat)
	NetworkManager.state_received.connect(_on_state)
	NetworkManager.identity_received.connect(_on_identity)

	NetworkManager.connect_to_server()
	NetworkManager.join_room("testroom")

	var waited := 0.0
	while not _got_p2p and waited < 8.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1

	await get_tree().create_timer(0.5).timeout

	# Шлём позицию ~5 секунд, чтобы дать handshake завершиться.
	for i in range(50):
		if i % 10 == 0:
			NetworkManager.send_chat("hello from %s" % _nick)
		NetworkManager.send_state(Vector3(i, 0, 0), 0.0, {"LookPitch": 0.3})
		await get_tree().create_timer(0.1).timeout

	await get_tree().create_timer(1.0).timeout
	print("[%s] RESULT chat=%s state=%s face=%s" % [_nick, _got_chat, _got_state, _got_face])
	get_tree().quit(0 if (_got_chat and _got_state and _got_face) else 1)


func _on_identity(id: int, nick: String, face: Texture2D, avatar_uri: String) -> void:
	_got_face = face != null
	print("[%s] IDENTITY from %d: nick=%s face=%s avatar=%s %s" % [
		_nick, id, nick, face != null, avatar_uri,
		("%dx%d" % [face.get_width(), face.get_height()]) if face != null else "",
	])


func _on_chat(id: int, text: String) -> void:
	_got_chat = true
	print("[%s] CHAT from %d: %s" % [_nick, id, text])


func _on_state(id: int, pos: Vector3, _yaw: float, params: Dictionary) -> void:
	if not _got_state:
		print("[%s] STATE from %d: %s params=%s" % [_nick, id, pos, params])
		_got_state = true
