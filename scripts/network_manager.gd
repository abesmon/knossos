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
## Состояние пира: позиция, поворот корпуса (yaw) и словарь параметров аватара (LookPitch,
## Grounded, Velocity* и т.д. — см. AvatarParams). Параметры расширяемы без правки сигнатуры.
signal state_received(id: int, position: Vector3, look_yaw: float, params: Dictionary)
signal chat_received(id: int, text: String)
## Пир прислал свою «карточку»: ник + текстуру лица (приходит при установке p2p).
signal identity_received(id: int, nick: String, face: Texture2D, avatar_uri: String)
## Состояние видео-плеера от пира (см. VrwebVideoManager): player_id — id из тега
## <VRWebVideoPlayer>, action — "play"/"pause"/"seek"/"sync", position — позиция в секундах.
## Транспорт и heartbeat-таймкод идут одним сигналом; различаются по action.
signal video_state_received(id: int, player_id: String, action: String, position: float)
## online — есть ли активное подключение к сигнальному серверу.
signal connection_changed(online: bool)
## Пришёл голосовой кадр от пира: payload — закодированный VoiceCodec (см. VoiceManager).
## Воспроизведение — на капсуле пира (RemotePlayer/VoicePlayback), маршрутит RemotePlayersView.
signal voice_received(id: int, payload: PackedByteArray)
## Сменился авторитет комнаты (см. authority_id). new_authority — id нового авторитета
## (0, если мы вне комнаты), is_me — стали ли авторитетом мы. Эмитится при входе/выходе
## пиров, когда меняется результат min(id). Консьюмеры привилегированных действий слушают
## это, чтобы начать/прекратить их выполнять. Подробно — в docs/authority.md.
signal authority_changed(new_authority: int, is_me: bool)
## Изменилась таблица рангов (user_id -> rank): авторитет её правит и рассылает, остальные
## принимают только от авторитета. Консьюмеры (проверки действий, UI) перечитывают ранги.
## Подробно — в docs/ranks.md.
signal ranks_changed()

## Жёсткий лимит длины сообщения чата — режем и на отправке, и на приёме, чтобы нигде
## (лог, бабл) не отрисовывалось больше.
const MAX_CHAT_CHARS := 280

## Ранг по умолчанию для тех, кого нет в таблице. Чем МЕНЬШЕ ранг — тем больше прав (0 ≈ админ),
## поэтому дефолт берём заведомо «далеко от нуля» — практически без прав. См. docs/ranks.md.
const DEFAULT_RANK := 1 << 30

const ICE_SERVERS := {
	"iceServers": [
		{
			"urls": ["stun:stun.l.google.com:19302"]
		},
		{
			"urls": "stun:stun.relay.metered.ca:80",
		},
		{
			"urls": "turn:global.relay.metered.ca:80",
			"username": "609dc0c20c8274554e649868",
			"credential": "B/2s+iW8VmDd+9AL",
		},
		{
			"urls": "turn:global.relay.metered.ca:80?transport=tcp",
			"username": "609dc0c20c8274554e649868",
			"credential": "B/2s+iW8VmDd+9AL",
		},
		{
			"urls": "turn:global.relay.metered.ca:443",
			"username": "609dc0c20c8274554e649868",
			"credential": "B/2s+iW8VmDd+9AL",
		},
		{
			"urls": "turns:global.relay.metered.ca:443?transport=tcp",
			"username": "609dc0c20c8274554e649868",
			"credential": "B/2s+iW8VmDd+9AL",
		}
	]
	
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
var _authority := 0        # последний вычисленный авторитет (для детекта смены) — см. authority_id
var _ranks := {}           # user_id (String) -> rank (int); владелец — авторитет, см. docs/ranks.md
var _user_ids := {}        # peer_id (int) -> user_id (String); из карточки идентичности


func _ready() -> void:
	# Как только p2p-канал к пиру открылся — шлём ему свою карточку (ник + лицо).
	multiplayer.peer_connected.connect(_on_mp_peer_connected)


func is_online() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## Доступен ли нативный WebRTC-аддон (для десктопа его надо положить в addons/webrtc).
func webrtc_available() -> bool:
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
	var url := _ws_url(Settings.signaling_url)
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_warning("Не удалось подключиться к %s (%d)" % [url, err])
		_ws = null


## Нормализует адрес сигналинга под WebSocketPeer: https→wss, http→ws, ws/wss — как есть.
static func _ws_url(url: String) -> String:
	url = url.strip_edges()
	if url.begins_with("https://"):
		return "wss://" + url.substr(8)
	if url.begins_with("http://"):
		return "ws://" + url.substr(7)
	return url


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


## Широковещательно разослать свою позицию, поворот (yaw) и словарь параметров аватара.
## Вызывается ~15 Гц. params — снимок AvatarParameterSource (см. AvatarParams).
func send_state(position: Vector3, look_yaw: float, params: Dictionary) -> void:
	if not _can_rpc():
		return
	rpc("_recv_state", position, look_yaw, params)


## Разослать свою карточку (user_id + ник + лицо + аватар) всем — например, после смены в настройках.
func broadcast_identity() -> void:
	if _can_rpc():
		rpc("_recv_identity", Settings.user_id, Settings.nick, Settings.face_png(), Settings.avatar_uri)


func _on_mp_peer_connected(id: int) -> void:
	# Отдаём новому пиру свою карточку: user_id, ник, лицо (PNG-байты) и идентификатор аватара.
	if _can_rpc():
		rpc_id(id, "_recv_identity", Settings.user_id, Settings.nick, Settings.face_png(), Settings.avatar_uri)
	# Если мы авторитет — новичку сразу полную таблицу рангов (чтобы он знал ранги всех, см. docs/ranks.md).
	if has_authority() and _can_rpc():
		rpc_id(id, "_recv_ranks", _ranks)


## Разослать сообщение чата остальным (локальное эхо — на стороне вызывающего).
func send_chat(text: String) -> void:
	if not _can_rpc():
		return
	rpc("_recv_chat", text.left(MAX_CHAT_CHARS))


## Разослать транспортное событие видео (play/pause/seek) — надёжно (reliable), чтобы не
## потерялось. player_id привязывает к плееру с тем же id у всех (страница одна = id одни).
func send_video_event(player_id: String, action: String, position: float) -> void:
	if _can_rpc():
		rpc("_recv_video_event", player_id, action, position)


## Разослать heartbeat видео (~1.5 Гц от таймкипера): позиция + состояние play/pause.
## Ненадёжно, но упорядоченно — отставшие/зашедшие подтянутся следующим пакетом. Несёт
## playing, чтобы поздно зашедший синхронизировал и позицию, И состояние воспроизведения
## (а не только при следующем явном play/pause).
func send_video_sync(player_id: String, position: float, playing: bool) -> void:
	if _can_rpc():
		rpc("_recv_video_sync", player_id, position, playing)


## Разослать голосовой кадр (закодированный VoiceCodec). Ненадёжно и по отдельному каналу 1,
## чтобы голос не блокировал и не блокировался состоянием/чатом (канал 0), а ретрансмиты не
## ломали реалтайм. Вызывает VoiceManager ~25 раз/с во время речи.
func send_voice(payload: PackedByteArray) -> void:
	if _can_rpc():
		rpc("_recv_voice", payload)


## Авторитет комнаты — пир с НАИМЕНЬШИМ id среди нас и подключённых p2p-пиров. Так как
## сигнальный сервер выдаёт id монотонным счётчиком, наименьший id = тот, кто раньше всех
## подключился: «авторитет первому». Это ЧИСТАЯ ФУНКЦИЯ от состава комнаты — каждый пир
## считает её локально и приходит к тому же ответу без переговоров и голосований. Новичок
## всегда получает больший id, поэтому НЕ может перехватить авторитет: роль «липнет» к
## старожилу и сдвигается только при его уходе (peer_leave убирает id → все пересчитывают
## min → авторитетом становится следующий по старшинству). Возвращает 0, если мы вне комнаты.
## Полностью — в docs/authority.md.
func authority_id() -> int:
	if _my_id == 0 or _mesh == null:
		return 0
	var best := _my_id
	for pid in _connections.keys():
		if pid != 0 and pid < best:
			best = pid
	return best


## Авторитет ли мы. has_authority() == true ровно у одного пира в связной компоненте меша.
func has_authority() -> bool:
	return _my_id != 0 and authority_id() == _my_id


## Проверка на стороне ПОЛУЧАТЕЛЯ привилегированного RPC: пришло ли действие от авторитета.
## Доверие не «на слово» — получатель сам вычисляет, кто авторитет, и сверяет с отправителем
## (его id привязан мешом/сервером, подделать прикладным слоем нельзя). Запоздавшие пакеты от
## БЫВШЕГО авторитета во время передачи роли отбрасываются: к их приходу authority_id() уже
## указывает на нового. Вызывать только внутри тела @rpc-метода.
func sender_is_authority() -> bool:
	var s := multiplayer.get_remote_sender_id()
	return s != 0 and s == authority_id()


## user_id текущего авторитета (стабильный id, а не peer_id) — для UI-отметки. "", если мы
## вне комнаты или карточка авторитета ещё не пришла.
func authority_user_id() -> String:
	var a := authority_id()
	if a == 0:
		return ""
	if a == _my_id:
		return Settings.user_id
	return _user_ids.get(a, "")


## Таймкипер видео — первый частный случай авторитета (правило выбора идентично). Оставлен
## отдельным именем ради читаемости вызовов в VrwebVideoManager; делегирует в has_authority.
func is_timekeeper() -> bool:
	return has_authority()


## Пересчитать авторитет и, если сменился, оповестить. Зовётся после любого изменения состава
## (вход/выход пира, подъём/снос меша).
func _refresh_authority() -> void:
	var a := authority_id()
	if a != _authority:
		_authority = a
		var is_me := a != 0 and a == _my_id
		authority_changed.emit(a, is_me)
		if is_me:
			# Стали авторитетом — фиксируем свой ранг 0 ЯВНО в таблице (см. docs/ranks.md):
			# так он унаследуется пирами и переживёт наш перезаход, даже когда авторитетом
			# станет кто-то другой. И сразу рассылаем таблицу (мы — её новый владелец).
			_claim_authority_rank()
		elif a != 0 and _can_rpc():
			# Авторитет сменился на другого пира — подтягиваем у него таблицу (pull). Закрывает
			# гонку: его push мог прийти по мешу раньше, чем мы обработали peer_leave старого
			# авторитета (peer_leave идёт через сигналинг) и потому отвергли бы его. См. docs/ranks.md.
			rpc_id(a, "_request_ranks")


# --- Ранги (таблица user_id -> rank; владелец — авторитет). См. docs/ranks.md. ---

## Ранг по user_id. Нет в таблице → DEFAULT_RANK (практически без прав).
func rank_of_user(user_id: String) -> int:
	return int(_ranks.get(user_id, DEFAULT_RANK))


## Ранг пира по его эфемерному peer_id. Авторитет всегда считается рангом 0 — даже до того,
## как обновление таблицы разойдётся (каждый вычисляет авторитета сам, см. authority_id).
func rank_of_peer(peer_id: int) -> int:
	if peer_id != 0 and peer_id == authority_id():
		return 0
	var uid: String = _user_ids.get(peer_id, "")
	return DEFAULT_RANK if uid == "" else rank_of_user(uid)


## Наш собственный текущий ранг.
func my_rank() -> int:
	if has_authority():
		return 0
	return rank_of_user(Settings.user_id)


## user_id пира (из его карточки) — "", если ещё не пришла.
func user_id_of(peer_id: int) -> String:
	return _user_ids.get(peer_id, "")


## Назначить ранг пользователю по его user_id. Только авторитет; у остальных — no-op с
## предупреждением (их обновление всё равно отклонят получатели). Рассылает всю таблицу.
func set_rank(user_id: String, rank: int) -> void:
	if not has_authority():
		push_warning("set_rank: только авторитет может менять ранги")
		return
	if user_id == "":
		return
	_ranks[user_id] = rank
	ranks_changed.emit()
	_broadcast_ranks()


## Убрать запись о ранге (пользователь вернётся к DEFAULT_RANK). Только авторитет.
func clear_rank(user_id: String) -> void:
	if not has_authority():
		push_warning("clear_rank: только авторитет может менять ранги")
		return
	if _ranks.erase(user_id):
		ranks_changed.emit()
		_broadcast_ranks()


## Снимок всей таблицы (копия) — для UI/отладки.
func ranks_snapshot() -> Dictionary:
	return _ranks.duplicate()


func _claim_authority_rank() -> void:
	if Settings.user_id != "" and int(_ranks.get(Settings.user_id, -1)) != 0:
		_ranks[Settings.user_id] = 0
		ranks_changed.emit()
	_broadcast_ranks()


func _broadcast_ranks() -> void:
	if _can_rpc():
		rpc("_recv_ranks", _ranks)


func nick_of(id: int) -> String:
	return _nicks.get(id, "Guest-%d" % id)


## Сколько пиров в комнате (по установленным p2p-соединениям). VoiceManager не захватывает
## микрофон, пока некому слать.
func peer_count() -> int:
	return _connections.size()


## Список peer_id онлайн-пиров (без нас). Для UI вроде раздела «Пользователи».
func peer_ids() -> Array:
	return _connections.keys()


## Мы в инстансе (комнате): меш поднят и у нас есть id. Раздел «Пользователи» доступен только так.
func in_room() -> bool:
	return _mesh != null and _my_id != 0


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
	# create_mesh заводит 3 базовых канала (reliable / unreliable / unreliable_ordered, индексы
	# 0–2). Голос идёт по отдельному @rpc-каналу 1 (см. _recv_voice) — он маппится на 4-й
	# WebRTC-канал (индекс 3), поэтому добавляем дополнительный unreliable_ordered-канал, иначе
	# put_packet падает с «max channels: 3». Все пиры создают меш одинаково — каналы совпадают.
	_mesh.create_mesh(_my_id, [MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED])
	multiplayer.multiplayer_peer = _mesh
	# Подняли меш — пока одни, авторитет наш (min == _my_id). Зафиксируем и оповестим.
	_refresh_authority()


func _teardown_mesh() -> void:
	for id in _connections.keys():
		emit_signal("peer_left", id)
	_connections.clear()
	_nicks.clear()
	# Таблица рангов и привязки — состояние комнаты. Уходя, сбрасываем: при перезаходе
	# авторитет пришлёт актуальную таблицу заново (а наш ранг хранится в ЕГО копии). См. docs/ranks.md.
	_user_ids.clear()
	_ranks.clear()
	if _mesh != null:
		if multiplayer.multiplayer_peer == _mesh:
			multiplayer.multiplayer_peer = null
		_mesh = null
	# Меша больше нет — авторитета тоже. Оповестим (a == 0), если он был.
	_refresh_authority()


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
	_refresh_authority()
	# Антиглар: offer инициирует пир с меньшим id.
	if _my_id < id:
		conn.create_offer()


func _drop_peer(id: int) -> void:
	if not _connections.has(id):
		return
	_connections.erase(id)
	_nicks.erase(id)
	# Снимаем только привязку peer_id->user_id. Сам ранг в _ranks НЕ трогаем — он привязан к
	# user_id и должен пережить уход пира (вернётся при перезаходе). См. docs/ranks.md.
	_user_ids.erase(id)
	# mesh мог сам убрать пира при закрытии канала — снимаем только если ещё есть.
	if _mesh != null and _mesh.has_peer(id):
		_mesh.remove_peer(id)
	peer_left.emit(id)
	_refresh_authority()


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
func _recv_state(position: Vector3, look_yaw: float, params: Dictionary) -> void:
	state_received.emit(multiplayer.get_remote_sender_id(), position, look_yaw, params)


@rpc("any_peer", "reliable", "call_remote")
func _recv_chat(text: String) -> void:
	# Режем и на приёме — пир мог быть с модифицированным клиентом.
	chat_received.emit(multiplayer.get_remote_sender_id(), text.left(MAX_CHAT_CHARS))


@rpc("any_peer", "reliable", "call_remote")
func _recv_identity(user_id: String, nick: String, face_png: PackedByteArray, avatar_uri: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	_nicks[id] = nick if nick != "" else "Guest-%d" % id
	# Привязка peer_id -> user_id нужна, чтобы по эфемерному id пира найти его ранг в таблице.
	# user_id самозаявлен и не проверяется подписью — см. оговорку в docs/ranks.md.
	if user_id != "":
		_user_ids[id] = user_id
		ranks_changed.emit()  # ранг пира теперь резолвится — слушатели могут перечитать
	identity_received.emit(id, _nicks[id], _decode_face(face_png), avatar_uri)


## Полная таблица рангов от авторитета. ДОВЕРИЕ: принимаем только если отправитель — авторитет
## по нашему собственному расчёту (sender_is_authority). Иначе игнорируем — подсунуть чужую
## таблицу нельзя. Таблица замещается целиком (авторитет — единственный источник истины).
@rpc("any_peer", "reliable", "call_remote")
func _recv_ranks(table: Dictionary) -> void:
	if not sender_is_authority():
		return
	_ranks = table.duplicate()
	ranks_changed.emit()


## Пир просит у нас таблицу рангов (pull при смене авторитета). Отвечаем, только если мы и
## правда авторитет — иначе наш ответ всё равно отвергнут получателем (sender_is_authority).
@rpc("any_peer", "reliable", "call_remote")
func _request_ranks() -> void:
	if has_authority() and _can_rpc():
		rpc_id(multiplayer.get_remote_sender_id(), "_recv_ranks", _ranks)


@rpc("any_peer", "reliable", "call_remote")
func _recv_video_event(player_id: String, action: String, position: float) -> void:
	video_state_received.emit(multiplayer.get_remote_sender_id(), player_id, action, position)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _recv_video_sync(player_id: String, position: float, playing: bool) -> void:
	var action := "sync_play" if playing else "sync_pause"
	video_state_received.emit(multiplayer.get_remote_sender_id(), player_id, action, position)


## Голосовой кадр от пира. Канал 1 — отдельный от состояния/чата (см. send_voice).
@rpc("any_peer", "unreliable_ordered", "call_remote", 1)
func _recv_voice(payload: PackedByteArray) -> void:
	voice_received.emit(multiplayer.get_remote_sender_id(), payload)


## PNG-байты -> текстура (или null, если пусто/битое).
func _decode_face(png: PackedByteArray) -> Texture2D:
	if png.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(png) != OK:
		return null
	return ImageTexture.create_from_image(img)
