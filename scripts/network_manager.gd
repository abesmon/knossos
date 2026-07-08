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
## P2P data channel к пиру реально открылся/закрылся. peer_joined/peer_left — это состав
## комнаты по сигналингу; p2p_* — готовность RPC поверх WebRTC.
signal p2p_peer_connected(id: int)
signal p2p_peer_disconnected(id: int)
## Состояние пира: позиция, поворот корпуса (yaw) и словарь параметров аватара (LookPitch,
## Grounded, Velocity* и т.д. — см. AvatarParams). Параметры расширяемы без правки сигнатуры.
signal state_received(id: int, position: Vector3, look_yaw: float, params: Dictionary)
signal chat_received(id: int, text: String)
## Пир прислал свою «карточку»: user_id + ник + текстуру лица (приходит при установке p2p).
signal identity_received(id: int, nick: String, face: Texture2D, avatar_uri: String)
## Пир ушёл из комнаты (peer_leave сигналинга), но у нас есть его user_id — даём ему
## GHOST_GRACE_SECONDS на переподключение («призрак»). Эмитится ПЕРЕД peer_left: консьюмер
## (RemotePlayersView) успевает забрать капсулу в пул призраков, и она не «моргает».
signal peer_ghosted(user_id: String, peer_id: int, nick: String)
## Grace-период призрака истёк без возврата — теперь пир ушёл по-настоящему.
signal ghost_expired(user_id: String)
## Призрак вернулся: пир с тем же user_id прислал карточку под НОВЫМ peer_id. Эмитится ПЕРЕД
## identity_received — консьюмер перевешивает капсулу на новый id, а карточка следом применяет
## свежие ник/лицо/аватар (реальное обновление, если они менялись за время отсутствия).
signal peer_reclaimed(user_id: String, peer_id: int)
## Личность пира подтверждена криптографически: сертификат его домашнего сервера проверен
## и пир доказал владение ключом (challenge–response). address — федеративный nick@domain.
## См. docs/home-server.md; до этого сигнала пир — аноним с самозаявленным user_id.
signal identity_verified(id: int, address: String)
## Состояние видео-плеера от пира (см. VrwebVideoManager): player_id — id из тега
## <VRWebVideoPlayer>, action — "play"/"pause"/"seek"/"sync", position — позиция в секундах.
## Транспорт и heartbeat-таймкод идут одним сигналом; различаются по action.
signal video_state_received(id: int, player_id: String, action: String, position: float)
## online — есть ли активное подключение к сигнальному серверу.
signal connection_changed(online: bool)
## Сменилось агрегированное состояние связи (см. ConnStatus / connection_status()). Эмитится
## из _process при смене состояния — под индикатор-«светофор» в UI (низ экрана + вкладка «Сеть»).
signal net_status_changed(status: Dictionary)
## Пришёл голосовой кадр от пира: payload — закодированный VoiceCodec (см. VoiceManager).
## Воспроизведение — на капсуле пира (RemotePlayer/VoicePlayback), маршрутит RemotePlayersView.
signal voice_received(id: int, payload: PackedByteArray)
## Сигналинг отказал во входе в комнату (закрытое персональное пространство —
## «хозяина нет дома», см. docs/personal-spaces.md). Мы остаёмся онлайн, но вне комнаты.
signal room_denied(room: String, reason: String)
## Сменился авторитет комнаты (см. authority_id). new_authority — id нового авторитета
## (0, если мы вне комнаты), is_me — стали ли авторитетом мы. Эмитится при входе/выходе
## пиров, когда меняется результат min(id). Консьюмеры привилегированных действий слушают
## это, чтобы начать/прекратить их выполнять. Подробно — в docs/authority.md.
signal authority_changed(new_authority: int, is_me: bool)
## Изменилась таблица рангов (user_id -> rank): авторитет её правит и рассылает, остальные
## принимают только от авторитета. Консьюмеры (проверки действий, UI) перечитывают ранги.
## Подробно — в docs/ranks.md.
signal ranks_changed()
## Эфемерные изменения сцены (action/event-протокол, см. docs/ephemeral-changes.md). Авторитет —
## единственная точка коммита: валидирует действия и рассылает события. Сигналы несут плоский
## объект состояния { id, kind, parent, author, ts, ttl, props } — консьюмер (EphemeralView)
## материализует его по kind, не зная транспорта.
signal scene_object_added(id: String, object: Dictionary)
signal scene_object_updated(id: String, object: Dictionary)
signal scene_object_removed(id: String)
## Состояние перезагружено снимком (вход в комнату / смена авторитета) — консьюмер пересобирает всё.
signal scene_reset()
## Ответ авторитета на ОТСЛЕЖИВАЕМОЕ действие (request_scene_action_tracked): token — из
## возврата запроса, accepted — принял ли авторитет мутацию. Отказ протокола «тихий»
## (пустой список событий) — этот сигнал даёт инициатору явную обратную связь для UI
## (консоль пространства). Таймаут ожидания — забота вызывающего: авторитет мог уйти.
signal scene_action_acked(token: int, accepted: bool)

## Жёсткий лимит длины сообщения чата — режем и на отправке, и на приёме, чтобы нигде
## (лог, бабл) не отрисовывалось больше.
const MAX_CHAT_CHARS := 280

## Ранг по умолчанию для тех, кого нет в таблице. Чем МЕНЬШЕ ранг — тем больше прав (0 ≈ админ),
## поэтому дефолт берём заведомо «далеко от нуля» — практически без прав. См. docs/ranks.md.
const DEFAULT_RANK := 1 << 30

## Ранг, при котором (и меньше) пир считается «админом» эфемерного слоя — может править/удалять
## ЧУЖИЕ объекты (обход проверки владения). 0 ≈ админ/авторитет. Фундамент под систему прав.
const EPHEMERAL_ADMIN_RANK := 0

## Grace-период «призрака»: сколько секунд ушедший пир может вернуться (с новым peer_id, но
## тем же user_id), чтобы его капсула не «моргала» у остальных. Покрывает вынужденные
## переподключения (смена адреса сигналинга, обрыв WS/сети).
const GHOST_GRACE_SECONDS := 2.0

## Агрегированное состояние связи для UI-«светофора» (см. connection_status()).
##   DISABLED   — офлайн-режим, подключение не требуется (серый);
##   CONNECTING — соединяемся с сигналингом (синий);
##   ONLINE     — всё хорошо (зелёный);
##   DEGRADED   — онлайн, но есть проблемы (потеряна p2p-связь с частью пиров) (оранжевый);
##   ERROR      — должны быть онлайн, но фактически отключены / нет WebRTC (красный).
enum ConnStatus { DISABLED, CONNECTING, ONLINE, DEGRADED, ERROR }

const _STATUS_COLORS := {
	ConnStatus.DISABLED: Color(0.55, 0.55, 0.58),
	ConnStatus.CONNECTING: Color(0.30, 0.55, 1.0),
	ConnStatus.ONLINE: Color(0.30, 0.82, 0.42),
	ConnStatus.DEGRADED: Color(0.98, 0.62, 0.12),
	ConnStatus.ERROR: Color(0.90, 0.26, 0.26),
}

## ICE/TURN-серверы берём из приватного конфига сборки (BuildConfig), а не зашиваем сюда —
## адреса и учётка TURN не должны жить в коде/репозитории. См. config/build_config.gd.

var _ws: WebSocketPeer
var _was_open := false
# Эффективный адрес сигналинга (до нормализации в ws/wss), с которым открыт/открывается
# текущий сокет. Сравнивается с Settings.effective_signaling_url(): анонс домашнего сервера
# мог прийти/смениться после подключения — тогда connect_to_server честно переподключается.
var _target_url := ""
var _my_id := 0
var _room := ""            # желаемая комната; "" — не в комнате
var _pending_join := false # ждём welcome, чтобы отправить join
# WebRTC-объекты держим без статической типизации: классы WebRTCMultiplayerPeer/
# WebRTCPeerConnection приходят из аддона webrtc-native и в офлайн-сборке без него
# отсутствуют — типизация сломала бы парсинг этого автолоада и весь запуск.
var _mesh = null           # WebRTCMultiplayerPeer
var _connections := {}     # peer_id -> WebRTCPeerConnection
var _connected_peers := {} # peer_id -> true, когда WebRTCMultiplayerPeer сообщил peer_connected
var _nicks := {}           # peer_id -> String
# Порядковые номера ВХОДА В КОМНАТУ (join seq от сигналинга): наш и по пирам. Старшинство
# авторитета считается по ним, а не по peer_id — id выдаётся при ПОДКЛЮЧЕНИИ к серверу, и
# давно запущенный клиент имел бы меньший id (и авторитет) в любой комнате, куда бы ни зашёл
# позже остальных. 0 = seq неизвестен (старый сервер) — fallback на сравнение id.
var _my_seq := 0           # наш seq в текущей комнате
var _peer_seqs := {}       # peer_id -> join seq
var _authority := 0        # последний вычисленный авторитет (для детекта смены) — см. authority_id
var _ranks := {}           # user_id (String) -> rank (int); владелец — авторитет, см. docs/ranks.md
var _user_ids := {}        # peer_id (int) -> user_id (String); из карточки идентичности
# Сертификаты идентичности (см. docs/home-server.md). Проверка двухшаговая: подпись сервера
# на сертификате, затем challenge–response на владение ключом. Всё — состояние комнаты.
var _peer_certs := {}      # peer_id -> {json, address, public_key} — сертификат, прошедший шаг 1
var _challenges := {}      # peer_id -> nonce (32 байта), одноразовый, ждём proof
var _verified := {}        # peer_id -> address (nick@domain) — прошёл ОБА шага
# «Призраки»: недавно ушедшие пиры, которых ждём обратно (см. peer_ghosted/GHOST_GRACE_SECONDS).
# user_id -> {nick: String, until_ms: int}. Только состояние комнаты — чистится в _teardown_mesh.
var _ghosts := {}
# Пиры, у которых p2p-канал БЫЛ открыт и закрылся, пока они всё ещё в комнате по сигналингу
# (обрыв ICE). Для индикации «соединение потеряно» vs «P2P подключается». peer_id -> true.
var _p2p_lost := {}
# Последняя причина обрыва/отказа связи (код закрытия WS, ошибка подключения, отказ комнаты) —
# показывается в развёрнутом статусе на вкладке «Сеть». "" — ошибок нет.
var _last_error := ""
# Кэш состояния для net_status_changed: эмитим сигнал только при СМЕНЕ состояния.
var _last_status_state := -1
var _status_accum := 0.0
var _rng := Crypto.new()   # генератор nonce для челленджей
var _scene := SceneChanges.new()  # машина состояний эфемерного слоя (чистая, см. scene_changes.gd)
# Зарезервированные id (узлы vrweb-слоя ТЕКУЩЕЙ страницы): add с таким id отклоняется —
# анти-коллизия дедупликации персистенции (см. docs/page-persistence.md). Ставит main
# после индексации страницы; переживает пересоздание _scene при смене комнаты.
var _scene_reserved := {}
var _obj_seq := 0          # счётчик для генерации id наших объектов (new_object_id)
var _action_token := 0     # счётчик токенов отслеживаемых действий (request_scene_action_tracked)
var _scene_resync := false # ждём снимок состояния (был GAP / смена авторитета) — не спамим запросом
var _expire_accum := 0.0   # аккумулятор throttle-сканирования TTL в _process

## Диагностика авторитета/сети (см. разбор бага «второй зашедший перехватывает авторитет»).
## Печатает подробный лог [NET] в stdout: присвоение peer_id, состав меша, вычисление
## авторитета, приём снимков и сбросы сцены. Выключить, когда разберёмся.
const NET_DEBUG := true

## Стабильный на весь процесс тег инстанса для лога — чтобы различать несколько клиентов,
## запущенных с одного компа (в общий stdout). _my_id для этого не годится: он 0 до welcome
## и меняется при переподключении. Приоритет: --sandbox=<id> (человекочитаемо, так и
## запускают мультиинстанс, см. Sandbox), иначе PID процесса.
static var _session_tag := ""


func _session() -> String:
	if _session_tag == "":
		var sid := Sandbox.id()
		_session_tag = sid if sid != "" else "pid%d" % OS.get_process_id()
	return _session_tag


## Лог диагностики сети. Префикс: [NET <инстанс> id=<peer_id> t=<ms>].
func _nlog(msg: String) -> void:
	if NET_DEBUG:
		Log.info("net", "%s id=%d t=%d %s" % [_session(), _my_id, Time.get_ticks_msec(), msg])


func _ready() -> void:
	# Как только p2p-канал к пиру открылся — шлём ему свою карточку (ник + лицо).
	multiplayer.peer_connected.connect(_on_mp_peer_connected)
	multiplayer.peer_disconnected.connect(_on_mp_peer_disconnected)
	# Сертификат появился/обновился (логин, продление) — предъявляем его уже подключённым пирам.
	HomeServer.certificate_changed.connect(broadcast_certificate)


func is_online() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## Агрегированное состояние связи для UI. Возвращает словарь:
##   state  — ConnStatus (см. enum);
##   color  — Color для «светофора»;
##   label  — короткая подпись (одна строка);
##   detail — развёрнутый текст (адрес сигналинга, число пиров, последняя ошибка) для настроек.
func connection_status() -> Dictionary:
	if not Settings.online_enabled:
		return _status_dict(ConnStatus.DISABLED, "Офлайн", "Онлайн-режим выключен")
	if not webrtc_available():
		return _status_dict(ConnStatus.ERROR, "Нет WebRTC",
			"Аддон webrtc-native не установлен (addons/webrtc) — онлайн невозможен")
	var ws_state := _ws.get_ready_state() if _ws != null else -1
	if ws_state == WebSocketPeer.STATE_OPEN:
		var base := "Сигналинг: %s" % Settings.effective_signaling_url()
		if in_room():
			base += "\nВ комнате: %d, p2p-связей: %d" % [peer_ids().size(), peer_count()]
		else:
			base += "\nВне комнаты"
		if _p2p_lost.size() > 0:
			return _status_dict(ConnStatus.DEGRADED, "Проблемы со связью",
				base + "\nПотеряна p2p-связь с %d пиром(ами)" % _p2p_lost.size())
		return _status_dict(ConnStatus.ONLINE, "Онлайн", base)
	if ws_state == WebSocketPeer.STATE_CONNECTING:
		return _status_dict(ConnStatus.CONNECTING, "Соединение…",
			"Подключаемся к %s" % Settings.effective_signaling_url())
	# online_enabled == true, но сокета нет / он закрывается — должны быть онлайн, но отключены.
	var detail := "Должны быть онлайн, но соединение разорвано"
	if _last_error != "":
		detail += "\n" + _last_error
	return _status_dict(ConnStatus.ERROR, "Отключено", detail)


func _status_dict(state: int, label: String, detail: String) -> Dictionary:
	return {"state": state, "color": _STATUS_COLORS.get(state, Color.GRAY),
		"label": label, "detail": detail}


## Перевычисляет агрегированный статус (~5 Гц из _process) и эмитит net_status_changed при СМЕНЕ
## состояния — чтобы UI-индикатор ловил и «беззвучные» переходы (CONNECTING, обрыв) без событий.
func _poll_net_status(delta: float) -> void:
	_status_accum += delta
	if _status_accum < 0.2:
		return
	_status_accum = 0.0
	var st := connection_status()
	if int(st["state"]) != _last_status_state:
		_last_status_state = int(st["state"])
		net_status_changed.emit(st)


## Доступен ли нативный WebRTC-аддон (для десктопа его надо положить в addons/webrtc).
func webrtc_available() -> bool:
	return ClassDB.class_exists("WebRTCPeerConnection") \
		and ClassDB.class_exists("WebRTCMultiplayerPeer")


## Подключиться к сигнальному серверу (Settings.effective_signaling_url — пользовательский
## адрес, анонс домашнего сервера или дефолт сборки). Сама комната задаётся отдельно через
## join_room — обычно main зовёт его сразу после connect.
##
## ИДЕМПОТЕНТЕН: если сокет уже открыт ИЛИ ещё подключается К ТОМУ ЖЕ адресу — не рвём его
## ради нового. Иначе повторный вызов в окне рукопожатия (is_online() ещё false, т.к. состояние
## не OPEN, а CONNECTING) открыл бы новый сокет — сервер выдал бы НОВЫЙ, больший peer_id.
## Авторитет считается по МИНИМАЛЬНОМУ id (кто раньше подключился), поэтому «прожжённый» id
## ломает старшинство: свежезашедший может оказаться с меньшим id, стать авторитетом и снести
## своим пустым снимком чужое состояние. См. docs/authority.md. join_room, выставив
## _pending_join, отправит вход сам, как только придёт welcome по уже идущему соединению.
##
## Если же эффективный адрес СМЕНИЛСЯ (пользователь переопределил, домашний сервер анонсировал
## другой сигналинг) — старое соединение вело бы не туда: рвём и подключаемся заново. Вызывающий
## (main._join_current_room) сразу после нас зовёт join_room — вход в комнату восстановится.
func connect_to_server() -> void:
	if not webrtc_available():
		Log.warn("net", "WebRTC недоступен: положите аддон webrtc-native в addons/webrtc")
		return
	var target := Settings.effective_signaling_url()
	if _ws != null:
		var state := _ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CONNECTING:
			if target == _target_url:
				return
			_nlog("сигналинг сменился: %s -> %s, переподключаемся" % [_target_url, target])
	disconnect_from_server()
	_ws = WebSocketPeer.new()
	_target_url = target
	var url := _ws_url(target)
	_nlog("connect_to_server -> %s" % url)
	var err := _ws.connect_to_url(url)
	if err != OK:
		Log.warn("net", "Не удалось подключиться к %s (%d)" % [url, err])
		_last_error = "Не удалось начать подключение к %s (ошибка %d)" % [url, err]
		_ws = null
		return
	_last_error = ""


## Нормализует адрес сигналинга под WebSocketPeer: https→wss, http→ws, ws/wss — как есть.
static func _ws_url(url: String) -> String:
	url = url.strip_edges()
	if url.begins_with("https://"):
		return "wss://" + url.substr(8)
	if url.begins_with("http://"):
		return "ws://" + url.substr(7)
	return url


func disconnect_from_server() -> void:
	if _ws != null or _mesh != null:
		_nlog("disconnect_from_server (был online=%s, my_id=%d)" % [str(is_online()), _my_id])
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
##
## ИДЕМПОТЕНТЕН: повторный вход в ТУ ЖЕ комнату при живом меше — no-op. Иначе каждое
## сохранение настроек (main._sync_online зовёт нас безусловно) пересылало бы join: сервер
## на повторный join сначала делает leave (все видят peer_leave — капсула «моргает») и выдаёт
## НОВЫЙ seq — старшинство авторитета сгорает на ровном месте. Смена ника/лица/аватара идёт
## отдельной карточкой (broadcast_identity), переподключение ей не нужно.
func join_room(room: String) -> void:
	if room == _room and room != "" and not _pending_join \
			and is_online() and _my_id != 0 and _mesh != null:
		return
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


## Разослать наш сертификат идентичности всем в комнате (после логина/обновления).
## Без сертификата — no-op: для пиров мы остаёмся анонимом.
func broadcast_certificate() -> void:
	var payload: Array = HomeServer.certificate_payload()
	if _can_rpc() and not payload.is_empty():
		rpc("_recv_certificate", payload[0], payload[1])


func _on_mp_peer_connected(id: int) -> void:
	_connected_peers[id] = true
	_p2p_lost.erase(id)
	_nlog("p2p CONNECT peer=%d; connected=%s; my_id=%d" % [id, str(_connected_peers.keys()), _my_id])
	p2p_peer_connected.emit(id)
	_refresh_authority()
	# Отдаём новому пиру свою карточку: user_id, ник, лицо (PNG-байты) и идентификатор аватара.
	if _can_rpc():
		rpc_id(id, "_recv_identity", Settings.user_id, Settings.nick, Settings.face_png(), Settings.avatar_uri)
		# И сертификат идентичности, если он у нас есть, — пир проверит и пришлёт челлендж.
		var payload: Array = HomeServer.certificate_payload()
		if not payload.is_empty():
			rpc_id(id, "_recv_certificate", payload[0], payload[1])
	# Если мы авторитет — новичку сразу полную таблицу рангов (чтобы он знал ранги всех, см. docs/ranks.md)
	# и снимок эфемерной сцены (чтобы он сразу увидел живые объекты, см. docs/ephemeral-changes.md).
	if has_authority() and _can_rpc():
		_nlog("я АВТОРИТЕТ -> push snapshot новичку peer=%d (objects=%d)" % [id, _scene.objects().size()])
		rpc_id(id, "_recv_ranks", _ranks)
		rpc_id(id, "_recv_scene_snapshot", _scene.snapshot())


func _on_mp_peer_disconnected(id: int) -> void:
	if _connected_peers.erase(id):
		# Канал был открыт и закрылся, а пир ещё в комнате по сигналингу — это обрыв ICE,
		# а не уход. Помечаем для индикации «соединение потеряно» (неймплейт/«Пользователи»).
		if _connections.has(id):
			_p2p_lost[id] = true
		_nlog("p2p DISCONNECT peer=%d; connected=%s" % [id, str(_connected_peers.keys())])
		p2p_peer_disconnected.emit(id)
		_refresh_authority()


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


## Авторитет комнаты — пир, РАНЬШЕ ВСЕХ ВОШЕДШИЙ В КОМНАТУ: наименьший join seq (сигналинг
## штампует монотонным счётчиком каждый вход) среди нас и подключённых p2p-пиров. Именно
## порядок входа в комнату, а НЕ peer_id: id выдаётся при подключении к серверу, и давно
## запущенный клиент имел бы меньший id — и перехватывал бы авторитет в любой комнате, куда
## бы ни зашёл позже остальных (а его пустой снимок затирал бы состояние). Это ЧИСТАЯ
## ФУНКЦИЯ от состава комнаты — каждый пир считает её локально и приходит к тому же ответу.
## Новичок всегда получает больший seq, поэтому НЕ может перехватить авторитет: роль
## «липнет» к старожилу и сдвигается только при его уходе. Ушёл из комнаты — потерял
## старшинство (свежий seq при возврате). Fallback: если сервер не прислал seq (старый
## сигналинг), сравниваем по id, как раньше. Возвращает 0, если мы вне комнаты.
## Полностью — в docs/authority.md.
func authority_id() -> int:
	if _my_id == 0 or _mesh == null:
		return 0
	# seq-режим только когда seq известен у ВСЕХ (у нас и каждого p2p-пира) — иначе пиры
	# могли бы разойтись в ответе. Смешанного состава при едином сервере не бывает.
	var seq_mode := _my_seq > 0
	for pid in _connected_peers.keys():
		if int(_peer_seqs.get(pid, 0)) <= 0:
			seq_mode = false
	var best := _my_id
	if seq_mode:
		var best_seq := _my_seq
		for pid in _connected_peers.keys():
			var seq := int(_peer_seqs.get(pid, 0))
			if seq < best_seq:
				best_seq = seq
				best = pid
	else:
		for pid in _connected_peers.keys():
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


## Пересчитать авторитет и, если сменился, оповестить. Зовётся после любого изменения p2p-состава
## (открытие/закрытие p2p-канала, подъём/снос меша).
func _refresh_authority() -> void:
	var a := authority_id()
	if a != _authority:
		_nlog("AUTHORITY %d -> %d (my_id=%d my_seq=%d, connected=%s, seqs=%s, я_авторитет=%s)" % [
			_authority, a, _my_id, _my_seq, str(_connected_peers.keys()), str(_peer_seqs),
			str(a != 0 and a == _my_id)])
		_authority = a
		var is_me := a != 0 and a == _my_id
		authority_changed.emit(a, is_me)
		if is_me:
			# Стали авторитетом — фиксируем свой ранг 0 ЯВНО в таблице (см. docs/ranks.md):
			# так он унаследуется пирами и переживёт наш перезаход, даже когда авторитетом
			# станет кто-то другой. И сразу рассылаем таблицу (мы — её новый владелец).
			_claim_authority_rank()
			# Эфемерный слой: поднимаем эпоху строго выше виденного, чтобы наши события были
			# заведомо новее экс-авторитетских (см. docs/ephemeral-changes.md). Состояние — тёплая копия.
			_scene.begin_authority()
		elif a != 0 and _can_rpc():
			# Авторитет сменился на другого пира — подтягиваем у него таблицу рангов и снимок
			# эфемерной сцены (pull). Закрывает гонку: его push мог прийти по мешу раньше, чем мы
			# обработали peer_leave старого авторитета (он идёт через сигналинг) и потому отвергли
			# бы его. См. docs/ranks.md и docs/ephemeral-changes.md.
			_nlog("НЕ я авторитет (a=%d) -> pull ranks+snapshot" % a)
			rpc_id(a, "_request_ranks")
			_scene_resync = true
			rpc_id(a, "_request_scene_snapshot")


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


## Криптографически подтверждённый федеративный адрес пира (nick@domain) — "" пока обе
## подписи (сервера и владения ключом) не сошлись. См. docs/home-server.md.
func verified_address_of(peer_id: int) -> String:
	return _verified.get(peer_id, "")


## Назначить ранг пользователю по его user_id. Только авторитет; у остальных — no-op с
## предупреждением (их обновление всё равно отклонят получатели). Рассылает всю таблицу.
func set_rank(user_id: String, rank: int) -> void:
	if not has_authority():
		Log.warn("net", "set_rank: только авторитет может менять ранги")
		return
	if user_id == "":
		return
	_ranks[user_id] = rank
	ranks_changed.emit()
	_broadcast_ranks()


## Убрать запись о ранге (пользователь вернётся к DEFAULT_RANK). Только авторитет.
func clear_rank(user_id: String) -> void:
	if not has_authority():
		Log.warn("net", "clear_rank: только авторитет может менять ранги")
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


# --- Эфемерные изменения сцены (action/event-протокол; машина состояний — SceneChanges). ---
# Контракт: инициатор шлёт ДЕЙСТВИЕ (намерение) авторитету; авторитет — единственная точка
# коммита: валидирует против своего состояния и прав, рассылает СОБЫТИЯ с порядковым (epoch,seq).
# NetworkManager — чистый транспорт поверх SceneChanges, не знает kind/3D. См. docs/ephemeral-changes.md.

## Запросить изменение сцены. action — плоское намерение { op, id, kind?, parent?, props?, ttl? }
## (см. SceneChanges.OP_*). Описывает ТОЛЬКО нужную мутацию, состояние не заявляет. Если мы
## авторитет — коммитим и рассылаем сразу; иначе шлём действие авторитету, он решает.
func request_scene_action(action: Dictionary) -> void:
	if typeof(action) != TYPE_DICTIONARY:
		return
	if has_authority():
		_authority_handle_action(action, Settings.user_id, my_rank() <= EPHEMERAL_ADMIN_RANK)
	elif _can_rpc():
		var a := authority_id()
		if a != 0:
			rpc_id(a, "_recv_scene_action", action)


## То же, что request_scene_action, но С ОБРАТНОЙ СВЯЗЬЮ: возвращает token, по которому
## придёт scene_action_acked(token, accepted). Если авторитет мы — исход известен сразу
## (сигнал эмитится отложенно, чтобы вызывающий успел подключиться после вызова); если
## авторитета нет (офлайн/вне комнаты) — немедленный отказ. Удалённому авторитету токен
## уезжает внутри действия и возвращается ack-ответом (_recv_scene_ack); машина состояний
## токен игнорирует (читает только поля протокола). Таймаут — забота вызывающего.
func request_scene_action_tracked(action: Dictionary) -> int:
	_action_token += 1
	var token := _action_token
	if typeof(action) != TYPE_DICTIONARY:
		call_deferred("emit_signal", "scene_action_acked", token, false)
	elif has_authority():
		var accepted := _authority_handle_action(action, Settings.user_id, my_rank() <= EPHEMERAL_ADMIN_RANK)
		call_deferred("emit_signal", "scene_action_acked", token, accepted)
	elif _can_rpc() and authority_id() != 0:
		var a := action.duplicate(true)
		a["token"] = token
		rpc_id(authority_id(), "_recv_scene_action", a)
	else:
		call_deferred("emit_signal", "scene_action_acked", token, false)
	return token


## Задать зарезервированные адреса эфемерного слоя (id узлов страницы): валидация add
## отклонит попытку занять id, уже существующий в базе. Объект с id из базы может быть
## только её же запечённой копией — это и делает дедуп персистенции точным.
func set_scene_reserved_ids(ids: Dictionary) -> void:
	_scene_reserved = ids.duplicate()
	_scene.reserved_ids = _scene_reserved


## Сгенерировать id для нового объекта (для op=add). Префикс из нашего user_id + счётчик —
## адрес, по которому МЫ потом сможем править/удалять свой объект. Уникальность гарантирует
## префикс (владение проверяется по author, а не по префиксу). Чистый адрес, без доверия.
func new_object_id() -> String:
	_obj_seq += 1
	var uid := Settings.user_id
	var prefix := uid.substr(0, 8) if uid.length() >= 8 else ("p%d" % _my_id)
	return "%s.%d" % [prefix, _obj_seq]


## Снимок эфемерной сцены (id -> object). Для вьюхи/отладки/будущей выгрузки на сервер.
func scene_objects() -> Dictionary:
	return _scene.objects()


## Один объект эфемерной сцены по id ({} если нет).
func scene_object(id: String) -> Dictionary:
	return _scene.get_object(id)


## Авторитет: применить действие и разослать получившиеся события. sender_user_id/sender_is_admin —
## кто и с какими правами (авторитет доверяет себе как источнику расчёта). Возвращает,
## принял ли коммит мутацию (пустой список событий = отказ) — для ack инициатору.
func _authority_handle_action(action: Dictionary, sender_user_id: String, sender_is_admin: bool) -> bool:
	var events := _scene.authority_commit(action, sender_user_id, sender_is_admin, Time.get_unix_time_from_system())
	_commit_scene_events(events)
	return not events.is_empty()


## Авторитет: для каждого события — применить локально (эмитнуть сигнал) и разослать остальным.
## Состояние на авторитете уже мутировано authority_commit/expire, поэтому здесь не apply_event,
## а только эмит + рассылка.
func _commit_scene_events(events: Array) -> void:
	for e in events:
		_emit_scene_event(e)
		if _can_rpc():
			rpc("_recv_scene_event", e)


## Эмит прикладного сигнала по событию (читая текущее состояние объекта). Общий для авторитета
## (после commit) и followers (после apply_event).
func _emit_scene_event(event: Dictionary) -> void:
	var id := str(event.get("id", ""))
	match str(event.get("op", "")):
		SceneChanges.OP_ADD:
			scene_object_added.emit(id, _scene.get_object(id))
		SceneChanges.OP_UPDATE, SceneChanges.OP_REPARENT:
			scene_object_updated.emit(id, _scene.get_object(id))
		SceneChanges.OP_REMOVE:
			scene_object_removed.emit(id)


## Действие от пира — обрабатывает только авторитет (он адресат rpc_id). Если роль уже сменилась —
## дроп (заказчик может повторить). sender_user_id/админство берём из ПРИВЯЗКИ авторитета
## (peer_id->user_id, ранг) — заказчик их не задаёт. См. docs/ephemeral-changes.md.
@rpc("any_peer", "reliable", "call_remote")
func _recv_scene_action(action: Dictionary) -> void:
	if not has_authority():
		return
	var sender := multiplayer.get_remote_sender_id()
	# token — транспортная метка отслеживаемого действия (не поле протокола): вынимаем и
	# после коммита возвращаем инициатору ack. События уезжают ТЕМ ЖЕ reliable-каналом
	# раньше ack — к приходу ответа инициатор уже применил результат.
	var token := int(action.get("token", 0))
	action.erase("token")
	var accepted := _authority_handle_action(action, _user_ids.get(sender, ""), rank_of_peer(sender) <= EPHEMERAL_ADMIN_RANK)
	if token > 0 and _can_rpc():
		rpc_id(sender, "_recv_scene_ack", token, accepted)


## Ответ авторитета на наше отслеживаемое действие. ДОВЕРИЕ: только от авторитета —
## чужой «ack» не может подделать исход (см. sender_is_authority).
@rpc("any_peer", "reliable", "call_remote")
func _recv_scene_ack(token: int, accepted: bool) -> void:
	if sender_is_authority():
		scene_action_acked.emit(token, accepted)


## Событие от авторитета. ДОВЕРИЕ: только если отправитель — авторитет по нашему расчёту
## (sender_is_authority). Применяем по порядку (epoch,seq); при пропуске/новой эпохе — ресинк снимком.
@rpc("any_peer", "reliable", "call_remote")
func _recv_scene_event(event: Dictionary) -> void:
	if not sender_is_authority():
		return
	match _scene.apply_event(event):
		SceneChanges.Apply.APPLIED:
			_emit_scene_event(event)
		SceneChanges.Apply.GAP:
			# Пропустили событие / увидели новую эпоху — состояние неконсистентно, тянем снимок.
			if not _scene_resync and _can_rpc():
				var a := authority_id()
				if a != 0:
					_scene_resync = true
					rpc_id(a, "_request_scene_snapshot")


## Снимок состояния от авторитета (push новичку / ответ на pull). ДОВЕРИЕ: только от авторитета.
## Замещает состояние целиком, консьюмер пересобирает (scene_reset).
@rpc("any_peer", "reliable", "call_remote")
func _recv_scene_snapshot(snap: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not sender_is_authority():
		_nlog("snapshot ОТВЕРГНУТ от peer=%d (наш authority=%d)" % [sender, authority_id()])
		return
	var incoming: int = (snap.get("objects", {}) as Dictionary).size()
	_nlog("snapshot ПРИНЯТ от peer=%d: было objects=%d -> станет %d (scene_reset)" % [
		sender, _scene.objects().size(), incoming])
	_scene.load_snapshot(snap)
	_scene_resync = false
	scene_reset.emit()


## Пир просит снимок (вход / ресинк / смена авторитета). Отвечаем только если мы и правда
## авторитет — иначе ответ всё равно отвергнут получателем (sender_is_authority).
@rpc("any_peer", "reliable", "call_remote")
func _request_scene_snapshot() -> void:
	if has_authority() and _can_rpc():
		rpc_id(multiplayer.get_remote_sender_id(), "_recv_scene_snapshot", _scene.snapshot())


func nick_of(id: int) -> String:
	return _nicks.get(id, "Guest-%d" % id)


## Сколько пиров в комнате с реально открытым p2p-каналом. VoiceManager не захватывает
## микрофон, пока некому слать по RPC.
func peer_count() -> int:
	return _connected_peers.size()


## Список peer_id онлайн-пиров (без нас). Для UI вроде раздела «Пользователи».
func peer_ids() -> Array:
	return _connections.keys()


## Открыт ли p2p/RPC-канал к пиру. Если false, пир известен только через сигналинг.
func peer_p2p_connected(id: int) -> bool:
	return _connected_peers.has(id)


## Был ли p2p-канал к пиру открыт и оборвался, пока пир ещё в комнате (потеря ICE).
## Отличает «соединение потеряно» от «P2P ещё подключается».
func peer_p2p_lost(id: int) -> bool:
	return _p2p_lost.has(id)


## Снимок «призраков» (user_id -> {nick, until_ms}) — недавно ушедшие, которых ждём обратно.
## Для UI вроде раздела «Пользователи».
func ghosts_snapshot() -> Dictionary:
	return _ghosts.duplicate(true)


## Мы в инстансе (комнате): меш поднят и у нас есть id. Раздел «Пользователи» доступен только так.
func in_room() -> bool:
	return _mesh != null and _my_id != 0


# --- Внутреннее ---

func _can_rpc() -> bool:
	return _mesh != null and multiplayer.multiplayer_peer == _mesh and _my_id != 0


func _process(_delta: float) -> void:
	_poll_net_status(_delta)
	if _ws == null:
		return
	_ws.poll()
	# Нативный WebRTCPeerConnection требует регулярного poll(), иначе события SDP/ICE и
	# переход data-channel в connected могут зависнуть на стороне аддона.
	for conn in _connections.values():
		conn.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			_last_error = ""
			connection_changed.emit(true)
		while _ws.get_available_packet_count() > 0:
			_on_ws_message(_ws.get_packet().get_string_from_utf8())
	elif state == WebSocketPeer.STATE_CLOSED:
		# Сокет закрылся (сервер недоступен/упал/idle-timeout прокси) — сбрасываемся в офлайн.
		var code := _ws.get_close_code()
		var reason := _ws.get_close_reason()
		_nlog("WS CLOSED code=%d reason=%s -> офлайн (был online=%s)" % [
			code, reason, str(_was_open)])
		_last_error = "Сигналинг закрыл соединение (код %d%s)" % [
			code, ": " + reason if reason != "" else ""]
		disconnect_from_server()
		return
	# Истечение TTL эфемерных объектов — обязанность авторитета (единый владелец состояния и
	# источник времени). Throttle ~4 Гц, чтобы не сканировать состояние каждый кадр. См.
	# docs/ephemeral-changes.md.
	_expire_accum += _delta
	if _expire_accum >= 0.25:
		_expire_accum = 0.0
		if has_authority():
			_commit_scene_events(_scene.expire(Time.get_unix_time_from_system()))
		_expire_ghosts()


## Истечение grace-периода призраков (~4 Гц из _process). Кто не вернулся — ушёл по-настоящему.
func _expire_ghosts() -> void:
	if _ghosts.is_empty():
		return
	var now := Time.get_ticks_msec()
	for uid in _ghosts.keys():
		if now >= int(_ghosts[uid].get("until_ms", 0)):
			_ghosts.erase(uid)
			_nlog("призрак user_id=%s не вернулся — истёк" % uid)
			ghost_expired.emit(uid)


func _on_ws_message(raw: String) -> void:
	var msg = JSON.parse_string(raw)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match msg.get("type", ""):
		"welcome":
			var new_id := int(msg.get("id", 0))
			if _my_id != 0 and _my_id != new_id:
				_nlog("WELCOME повторно: my_id %d -> %d (ПЕРЕПОДКЛЮЧЕНИЕ — старшинство авторитета сбилось!)" % [_my_id, new_id])
			_my_id = new_id
			_nlog("welcome: my_id=%d (pending_join=%s room=%s)" % [_my_id, str(_pending_join), _room])
			if _pending_join and _room != "":
				_send_join()
		"peers":
			# Ответ на наш join: наш seq входа в комнату + список тех, кто уже в комнате
			# (создаём соединения; антиглар-инициатор — по меньшему id, это не старшинство).
			_my_seq = int(msg.get("seq", 0))
			_nlog("peers: my_seq=%d, в комнате %d пиров" % [_my_seq, (msg.get("peers", []) as Array).size()])
			for p in msg.get("peers", []):
				_register_peer(int(p.get("id", 0)), str(p.get("nick", "")), int(p.get("seq", 0)))
		"peer_join":
			_register_peer(int(msg.get("id", 0)), str(msg.get("nick", "")), int(msg.get("seq", 0)))
		"peer_leave":
			_drop_peer(int(msg.get("id", 0)))
		"join_denied":
			# Комната закрыта политикой пространства («хозяина нет дома»). Мы онлайн, но вне
			# комнаты: сносим ожидающий меш, чтобы не считать себя её авторитетом.
			_nlog("join DENIED room=%s reason=%s" % [str(msg.get("room", "")), str(msg.get("reason", ""))])
			if str(msg.get("room", "")) == _room:
				_room = ""
				_teardown_mesh()
			var deny_reason := str(msg.get("reason", ""))
			_last_error = "Комната закрыта%s" % (": " + deny_reason if deny_reason != "" else "")
			room_denied.emit(str(msg.get("room", "")), deny_reason)
		"offer":
			_on_remote_offer(int(msg.get("from", 0)), str(msg.get("data", "")))
		"answer":
			_set_remote_desc(int(msg.get("from", 0)), "answer", str(msg.get("data", "")))
		"candidate":
			_on_remote_candidate(int(msg.get("from", 0)), msg.get("data", {}))


func _send_join() -> void:
	_nlog("send join room=%s (my_id=%d)" % [_room, _my_id])
	_setup_mesh()
	var join := {"type": "join", "room": _room, "nick": Settings.nick}
	# Токен аккаунта — только своему домашнему серверу (монолит сигналинг+хостинг): по нему
	# сервер привязывает WS-сессию к адресу — так владелец входит в закрытое пространство,
	# а presence-gate видит «хозяин дома». См. docs/personal-spaces.md.
	var token: String = HomeServer.signaling_token()
	if token != "":
		join["access_token"] = token
	_ws_send(join)
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
		if _connected_peers.has(id):
			p2p_peer_disconnected.emit(id)
		emit_signal("peer_left", id)
	_connections.clear()
	_connected_peers.clear()
	_nicks.clear()
	# Старшинство — состояние комнаты: вне комнаты его нет, при перезаходе сервер выдаст новый seq.
	_peer_seqs.clear()
	_my_seq = 0
	# Таблица рангов и привязки — состояние комнаты. Уходя, сбрасываем: при перезаходе
	# авторитет пришлёт актуальную таблицу заново (а наш ранг хранится в ЕГО копии). См. docs/ranks.md.
	_user_ids.clear()
	_ranks.clear()
	_peer_certs.clear()
	_challenges.clear()
	_verified.clear()
	# Призраки — тоже состояние комнаты: уходим МЫ — ждать больше некого. Оповещаем, чтобы
	# консьюмеры (капсулы-призраки, «Пользователи») убрались и при выходе в офлайн без
	# пересоздания world.
	_p2p_lost.clear()
	for uid in _ghosts.keys():
		ghost_expired.emit(uid)
	_ghosts.clear()
	# Эфемерная сцена — тоже состояние комнаты: уходя, сбрасываем (при перезаходе авторитет
	# пришлёт снимок). Свежая машина обнуляет epoch/seq/объекты. См. docs/ephemeral-changes.md.
	_scene = SceneChanges.new()
	_scene.reserved_ids = _scene_reserved
	_scene_resync = false
	scene_reset.emit()
	if _mesh != null:
		if multiplayer.multiplayer_peer == _mesh:
			multiplayer.multiplayer_peer = null
		_mesh = null
	# Меша больше нет — авторитета тоже. Оповестим (a == 0), если он был.
	_refresh_authority()


## Заводит p2p-соединение к пиру и, если мы — сторона с меньшим id, шлёт offer.
## seq — порядковый номер входа пира в комнату (для старшинства авторитета); 0 = неизвестен
## (повторная регистрация по offer — сохраняем уже известный).
func _register_peer(id: int, nick: String, seq: int = 0) -> void:
	if id == 0 or id == _my_id or _connections.has(id) or _mesh == null:
		return
	if seq > 0:
		_peer_seqs[id] = seq
	_nicks[id] = nick if nick != "" else "Guest-%d" % id
	var conn = ClassDB.instantiate("WebRTCPeerConnection")
	conn.initialize(BuildConfig.ice_servers)
	conn.session_description_created.connect(_on_session_created.bind(id))
	conn.ice_candidate_created.connect(_on_ice_created.bind(id))
	_connections[id] = conn
	_mesh.add_peer(conn, id)
	peer_joined.emit(id, _nicks[id])
	_refresh_authority()
	# Антиглар: offer инициирует пир с меньшим id.
	_nlog("register peer=%d (my_id=%d) — offer шлём мы: %s" % [id, _my_id, str(_my_id < id)])
	if _my_id < id:
		conn.create_offer()


func _drop_peer(id: int) -> void:
	if not _connections.has(id):
		return
	# Пир с известным user_id уходит в «призраки»: GHOST_GRACE_SECONDS ждём его возврата
	# (вынужденное переподключение), капсулу за это время не сносим. Сигнал — ДО peer_left,
	# чтобы RemotePlayersView успел забрать капсулу в пул. user_id самозаявлен — усыновление
	# капсулы разделяет уровень доверия ранг-системы (см. docs/ranks.md).
	var ghost_uid: String = _user_ids.get(id, "")
	if ghost_uid != "":
		_ghosts[ghost_uid] = {
			"nick": nick_of(id),
			"until_ms": Time.get_ticks_msec() + int(GHOST_GRACE_SECONDS * 1000.0),
		}
		_nlog("peer=%d ушёл -> призрак user_id=%s на %.0f c" % [id, ghost_uid, GHOST_GRACE_SECONDS])
		peer_ghosted.emit(ghost_uid, id, nick_of(id))
	_connections.erase(id)
	_p2p_lost.erase(id)
	if _connected_peers.erase(id):
		p2p_peer_disconnected.emit(id)
	_nicks.erase(id)
	_peer_seqs.erase(id)
	# Снимаем только привязку peer_id->user_id. Сам ранг в _ranks НЕ трогаем — он привязан к
	# user_id и должен пережить уход пира (вернётся при перезаходе). См. docs/ranks.md.
	_user_ids.erase(id)
	# Верификация привязана к эфемерному peer_id — при перезаходе пир докажет личность заново.
	_peer_certs.erase(id)
	_challenges.erase(id)
	_verified.erase(id)
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


# --- Сертификаты идентичности (двухшаговая проверка, см. docs/home-server.md) ---

## Пир предъявил сертификат. Шаг 1 — подпись его домашнего сервера над канонической строкой
## (ключи домена тянет HomeServer, поэтому await). Прошло — шлём челлендж на владение ключом.
@rpc("any_peer", "reliable", "call_remote")
func _recv_certificate(cert_json: String, signature_b64: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if _verified.has(id) and _peer_certs.get(id, {}).get("json", "") == cert_json:
		return  # ровно этот сертификат уже подтверждён — не гоняем челленджи повторно
	var res: Dictionary = await HomeServer.verify_peer_certificate(cert_json, signature_b64)
	# За время await пир мог уйти, а мы — покинуть комнату.
	if not _connections.has(id) or not _can_rpc():
		return
	if not res.get("ok", false):
		Log.warn("net", "Сертификат пира %d отклонён: %s" % [id, res.get("error", "")])
		return
	_verified.erase(id)
	_peer_certs[id] = {"json": cert_json, "address": res.address, "public_key": res.public_key}
	var nonce: PackedByteArray = _rng.generate_random_bytes(32)
	_challenges[id] = nonce
	rpc_id(id, "_recv_identity_challenge", nonce)


## Челлендж от пира: доказываем владение приватным ключом — подписываем nonce, привязанный к
## паре (мы, проверяющий), см. _proof_payload. Без ключа/сертификата молчим (мы аноним).
@rpc("any_peer", "reliable", "call_remote")
func _recv_identity_challenge(nonce: PackedByteArray) -> void:
	if nonce.size() != 32 or not HomeServer.has_certificate():
		return
	var verifier := multiplayer.get_remote_sender_id()
	var proof: PackedByteArray = HomeServer.sign_challenge(_proof_payload(_my_id, verifier, nonce))
	if not proof.is_empty() and _can_rpc():
		rpc_id(verifier, "_recv_identity_proof", proof)


## Ответ на наш челлендж (шаг 2): подпись сходится с ключом из проверенного сертификата →
## предъявитель действительно владелец адреса. nonce одноразовый — стирается при первом ответе,
## повтор (replay) не пройдёт.
@rpc("any_peer", "reliable", "call_remote")
func _recv_identity_proof(proof: PackedByteArray) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not _challenges.has(id) or proof.size() > 4096:
		return
	var nonce: PackedByteArray = _challenges[id]
	_challenges.erase(id)
	var cert: Dictionary = _peer_certs.get(id, {})
	if cert.is_empty():
		return
	if HomeServer.verify_signature(cert.public_key, _proof_payload(id, _my_id, nonce), proof):
		_verified[id] = cert.address
		identity_verified.emit(id, cert.address)


## Байты, которые подписывает доказывающий: домен-разделитель + peer_id обеих сторон + nonce.
## Привязка к паре пиров закрывает relay-атаку: подпись, выданная одному проверяющему, не
## годится для другого (см. «Проверка в комнате» в docs/home-server.md). Обе стороны собирают
## payload независимо: prover — (свой id, id спросившего), verifier — (id пира, свой id).
static func _proof_payload(prover_id: int, verifier_id: int, nonce: PackedByteArray) -> PackedByteArray:
	return ("vrweb-identity-proof.v1:%d:%d:" % [prover_id, verifier_id]).to_utf8_buffer() + nonce


@rpc("any_peer", "reliable", "call_remote")
func _recv_identity(user_id: String, nick: String, face_png: PackedByteArray, avatar_uri: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	_nicks[id] = nick if nick != "" else "Guest-%d" % id
	# Привязка peer_id -> user_id нужна, чтобы по эфемерному id пира найти его ранг в таблице.
	# user_id самозаявлен и не проверяется подписью — см. оговорку в docs/ranks.md.
	if user_id != "":
		_user_ids[id] = user_id
		# Вернулся «призрак» (тот же user_id под новым peer_id) — отдаём капсулу новому id.
		# Сигнал ДО identity_received: карточка следом применит свежие ник/лицо/аватар.
		if _ghosts.erase(user_id):
			_nlog("призрак user_id=%s вернулся как peer=%d" % [user_id, id])
			peer_reclaimed.emit(user_id, id)
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
