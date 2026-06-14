extends Node

## Сетевой слой мультиплеера (autoload «NetworkManager»). Персистентный — переживает
## перестройку мира при навигации, поэтому держит стабильный путь /root/NetworkManager,
## нужный для RPC.
##
## Транспорт: p2p WebRTC mesh. Сигнальный сервер (WebSocket) нужен только для handshake —
## присваивает peer_id, группирует по комнатам (room = PageFetcher.seed_key(url)) и
## пересылает offer/answer/ICE. После соединения позиции и чат идут напрямую через RPC
## поверх mesh.
##
## Наружу: join_room/leave_room/send_state/send_chat + сигналы. Визуализацию капсул и
## отправку позиции локального игрока делает RemotePlayersView (живёт в world).

signal peer_joined(id: int, nick: String)
signal peer_left(id: int)
signal state_received(id: int, position: Vector3, look_yaw: float)
signal chat_received(id: int, text: String)
## online — есть ли активное подключение к сигнальному серверу.
signal connection_changed(online: bool)

const ICE_SERVERS := {
	"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]
}

var _ws: WebSocketPeer
var _was_open := false
var _my_id := 0
var _room := ""            # желаемая комната; "" — не в комнате
var _pending_join := false # ждём welcome, чтобы отправить join
# WebRTC-объекты держим без статической типизации: классы WebRTCMultiplayerPeer/
# WebRTCPeerConnection приходят из аддона webrtc-native и в офлайн-сборке без него
# отсутствуют — типизация сломала бы парсинг этого автолоада и весь запуск.
var _mesh = null           # WebRTCMultiplayerPeer
var _connections := {}     # peer_id -> WebRTCPeerConnection
var _nicks := {}           # peer_id -> String


func is_online() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## Доступен ли нативный WebRTC-аддон (для десктопа его надо положить в addons/webrtc).
static func webrtc_available() -> bool:
	return ClassDB.class_exists("WebRTCPeerConnection") \
		and ClassDB.class_exists("WebRTCMultiplayerPeer")


## Подключиться к сигнальному серверу (Settings.signaling_url). Сама комната задаётся
## отдельно через join_room — обычно main зовёт его сразу после connect.
func connect_to_server() -> void:
	if not webrtc_available():
		push_warning("WebRTC недоступен: положите аддон webrtc-native в addons/webrtc")
		return
	disconnect_from_server()
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(Settings.signaling_url)
	if err != OK:
		push_warning("Не удалось подключиться к %s (%d)" % [Settings.signaling_url, err])
		_ws = null


func disconnect_from_server() -> void:
	_teardown_mesh()
	_room = ""
	_pending_join = false
	_my_id = 0
	if _ws != null:
		_ws.close()
		_ws = null
	if _was_open:
		_was_open = false
		connection_changed.emit(false)


## Войти в комнату (room = seed_key страницы). Если уже в другой — мягко переключает:
## рвёт старые p2p-соединения и пересоздаёт mesh.
func join_room(room: String) -> void:
	_room = room
	if is_online() and _my_id != 0:
		_send_join()
	else:
		_pending_join = true


## Выйти из комнаты, но не разрывать сам сигнальный сокет (остаёмся онлайн).
func leave_room() -> void:
	_room = ""
	_pending_join = false
	_teardown_mesh()


## Широковещательно разослать свою позицию и поворот (вызывается ~15 Гц).
func send_state(position: Vector3, look_yaw: float) -> void:
	if not _can_rpc():
		return
	rpc("_recv_state", position, look_yaw)


## Разослать сообщение чата остальным (локальное эхо — на стороне вызывающего).
func send_chat(text: String) -> void:
	if not _can_rpc():
		return
	rpc("_recv_chat", text)


func nick_of(id: int) -> String:
	return _nicks.get(id, "Guest-%d" % id)


# --- Внутреннее ---

func _can_rpc() -> bool:
	return _mesh != null and multiplayer.multiplayer_peer == _mesh and _my_id != 0


func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			connection_changed.emit(true)
		while _ws.get_available_packet_count() > 0:
			_on_ws_message(_ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		# Сокет закрылся (сервер недоступен/упал) — сбрасываемся в офлайн.
		disconnect_from_server()


func _on_ws_message(raw: String) -> void:
	var msg = JSON.parse_string(raw)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match msg.get("type", ""):
		"welcome":
			_my_id = int(msg.get("id", 0))
			if _pending_join and _room != "":
				_send_join()
		"peers":
			# Список тех, кто уже в комнате: создаём соединения (мы — инициатор к меньшим id).
			for p in msg.get("peers", []):
				_register_peer(int(p.get("id", 0)), str(p.get("nick", "")))
		"peer_join":
			_register_peer(int(msg.get("id", 0)), str(msg.get("nick", "")))
		"peer_leave":
			_drop_peer(int(msg.get("id", 0)))
		"offer":
			_on_remote_offer(int(msg.get("from", 0)), str(msg.get("data", "")))
		"answer":
			_set_remote_desc(int(msg.get("from", 0)), "answer", str(msg.get("data", "")))
		"candidate":
			_on_remote_candidate(int(msg.get("from", 0)), msg.get("data", {}))


func _send_join() -> void:
	_setup_mesh()
	_ws_send({"type": "join", "room": _room, "nick": Settings.nick})
	_pending_join = false


func _ws_send(msg: Dictionary) -> void:
	if is_online():
		_ws.send_text(JSON.stringify(msg))


# --- Mesh ---

func _setup_mesh() -> void:
	_teardown_mesh()
	_mesh = ClassDB.instantiate("WebRTCMultiplayerPeer")
	_mesh.create_mesh(_my_id)
	multiplayer.multiplayer_peer = _mesh


func _teardown_mesh() -> void:
	for id in _connections.keys():
		emit_signal("peer_left", id)
	_connections.clear()
	_nicks.clear()
	if _mesh != null:
		if multiplayer.multiplayer_peer == _mesh:
			multiplayer.multiplayer_peer = null
		_mesh = null


## Заводит p2p-соединение к пиру и, если мы — сторона с меньшим id, шлёт offer.
func _register_peer(id: int, nick: String) -> void:
	if id == 0 or id == _my_id or _connections.has(id) or _mesh == null:
		return
	_nicks[id] = nick if nick != "" else "Guest-%d" % id
	var conn = ClassDB.instantiate("WebRTCPeerConnection")
	conn.initialize(ICE_SERVERS)
	conn.session_description_created.connect(_on_session_created.bind(id))
	conn.ice_candidate_created.connect(_on_ice_created.bind(id))
	_connections[id] = conn
	_mesh.add_peer(conn, id)
	peer_joined.emit(id, _nicks[id])
	# Антиглар: offer инициирует пир с меньшим id.
	if _my_id < id:
		conn.create_offer()


func _drop_peer(id: int) -> void:
	if not _connections.has(id):
		return
	_connections.erase(id)
	_nicks.erase(id)
	# mesh мог сам убрать пира при закрытии канала — снимаем только если ещё есть.
	if _mesh != null and _mesh.has_peer(id):
		_mesh.remove_peer(id)
	peer_left.emit(id)


func _on_session_created(type: String, sdp: String, id: int) -> void:
	var conn = _connections.get(id)
	if conn == null:
		return
	conn.set_local_description(type, sdp)
	# type == "offer" у инициатора, "answer" — у отвечающего.
	_ws_send({"type": type, "to": id, "data": sdp})


func _on_ice_created(media: String, index: int, cand_name: String, id: int) -> void:
	_ws_send({
		"type": "candidate", "to": id,
		"data": {"media": media, "index": index, "name": cand_name},
	})


## Пришёл offer: если соединения ещё нет — заводим (мы отвечающая сторона) и ставим SDP.
func _on_remote_offer(id: int, sdp: String) -> void:
	if not _connections.has(id):
		_register_peer(id, _nicks.get(id, ""))
	_set_remote_desc(id, "offer", sdp)


func _set_remote_desc(id: int, type: String, sdp: String) -> void:
	var conn = _connections.get(id)
	if conn != null:
		conn.set_remote_description(type, sdp)


func _on_remote_candidate(id: int, data) -> void:
	var conn = _connections.get(id)
	if conn == null or typeof(data) != TYPE_DICTIONARY:
		return
	conn.add_ice_candidate(str(data.get("media", "")), int(data.get("index", 0)), str(data.get("name", "")))


# --- RPC (поверх mesh) ---

@rpc("any_peer", "unreliable_ordered", "call_remote")
func _recv_state(position: Vector3, look_yaw: float) -> void:
	state_received.emit(multiplayer.get_remote_sender_id(), position, look_yaw)


@rpc("any_peer", "reliable", "call_remote")
func _recv_chat(text: String) -> void:
	chat_received.emit(multiplayer.get_remote_sender_id(), text)
