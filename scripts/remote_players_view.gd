class_name RemotePlayersView
extends Node3D

## Визуализация других игроков комнаты и отправка позиции локального игрока.
## Живёт внутри world: при навигации (смене комнаты) world сносится вместе с капсулами —
## это корректно, уход со страницы = выход из комнаты. main пересоздаёт view в
## _rebuild_world и передаёт ссылку на локального игрока через setup().
##
## Капсулу пира создаём лениво — на первом пакете позиции (к этому моменту p2p уже
## установлен), удаляем по peer_left.

const REMOTE_PLAYER := preload("res://actors/remote_player/remote_player.tscn")
const SEND_HZ := 15.0
## Аватар, с которым капсула стартует (AvatarHost резолвит vrwebavatar://1 из VRWML). Если
## пир прислал тот же идентификатор — не пересобираем аватар зря.
const HOST_DEFAULT_URI := "vrwebavatar://1"

var _player: Node3D
var _capsules := {}        # peer_id -> RemotePlayer
var _faces := {}           # peer_id -> Texture2D (карточка могла прийти до создания капсулы)
var _avatar_uris := {}     # peer_id -> String (желаемый аватар из карточки)
var _avatar_applied := {}  # peer_id -> String (какой аватар уже смонтирован — чтобы не дёргать)
# Капсулы-«призраки»: пир ушёл, но NetworkManager даёт ему grace-период на переподключение
# (peer_ghosted). Капсулу не сносим — держим с иконкой «нет связи», а при возврате пира
# (peer_reclaimed, новый peer_id) отдаём ему обратно — без «моргания». user_id ->
# {cap, face, uri, applied}. См. docs/multiplayer.md.
var _ghost_caps := {}
var _send_accum := 0.0
var _resolver: AvatarResolver


## Подключает view к сети и к локальному игроку (позицию которого транслируем).
func setup(player: Node3D) -> void:
	_player = player
	_resolver = AvatarResolver.new()
	add_child(_resolver)
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.peer_ghosted.connect(_on_peer_ghosted)
	NetworkManager.ghost_expired.connect(_on_ghost_expired)
	NetworkManager.peer_reclaimed.connect(_on_peer_reclaimed)
	NetworkManager.p2p_peer_connected.connect(_on_p2p_connected)
	NetworkManager.p2p_peer_disconnected.connect(_on_p2p_disconnected)
	NetworkManager.state_received.connect(_on_state_received)
	NetworkManager.identity_received.connect(_on_identity_received)
	NetworkManager.identity_verified.connect(_on_identity_verified)
	NetworkManager.chat_received.connect(_on_chat_received)
	NetworkManager.voice_received.connect(_on_voice_received)


func _exit_tree() -> void:
	# View пересоздаётся на каждой странице — отписываемся, чтобы не плодить коннекты.
	if NetworkManager.peer_joined.is_connected(_on_peer_joined):
		NetworkManager.peer_joined.disconnect(_on_peer_joined)
		NetworkManager.peer_left.disconnect(_on_peer_left)
		NetworkManager.peer_ghosted.disconnect(_on_peer_ghosted)
		NetworkManager.ghost_expired.disconnect(_on_ghost_expired)
		NetworkManager.peer_reclaimed.disconnect(_on_peer_reclaimed)
		NetworkManager.p2p_peer_connected.disconnect(_on_p2p_connected)
		NetworkManager.p2p_peer_disconnected.disconnect(_on_p2p_disconnected)
		NetworkManager.state_received.disconnect(_on_state_received)
		NetworkManager.identity_received.disconnect(_on_identity_received)
		NetworkManager.identity_verified.disconnect(_on_identity_verified)
		NetworkManager.chat_received.disconnect(_on_chat_received)
		NetworkManager.voice_received.disconnect(_on_voice_received)


func _physics_process(delta: float) -> void:
	if _player == null or not NetworkManager.is_online():
		return
	_send_accum += delta
	if _send_accum >= 1.0 / SEND_HZ:
		_send_accum = 0.0
		NetworkManager.send_state(_player.global_position, _player.rotation.y, _player.avatar_snapshot())


func _on_peer_joined(id: int, nick: String) -> void:
	# Ник запоминаем сразу; капсулу создаём на первом state (см. _on_state_received).
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_nick(nick)


func _on_state_received(id: int, pos: Vector3, look_yaw: float, params: Dictionary) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap == null:
		cap = REMOTE_PLAYER.instantiate()
		cap.set_nick(NetworkManager.nick_of(id))
		# Личность могла подтвердиться до первого state (или до пересоздания view) — адрес
		# держит NetworkManager, поэтому просто спрашиваем его.
		cap.set_verified_address(NetworkManager.verified_address_of(id))
		if _faces.has(id):
			cap.set_face(_faces[id])   # карточка пришла раньше первого state
		add_child(cap)
		_capsules[id] = cap
		_avatar_applied[id] = HOST_DEFAULT_URI   # капсула стартует с дефолтного аватара
		# Аватар из карточки мог прийти раньше первого state — монтируем его теперь.
		if _avatar_uris.has(id):
			_apply_avatar(id, _avatar_uris[id])
	cap.set_state(pos, look_yaw, params)


## Пришла карточка пира: ник, лицо и идентификатор аватара. Лицо/uri запоминаем (могли прийти
## до капсулы), применяем к капсуле, если она уже есть.
func _on_identity_received(id: int, nick: String, face: Texture2D, avatar_uri: String) -> void:
	if face != null:
		_faces[id] = face
	_avatar_uris[id] = avatar_uri
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_nick(nick)
		if face != null:
			cap.set_face(face)
		_apply_avatar(id, avatar_uri)


## Личность пира подтверждена криптографически (обе подписи сошлись) — показываем nick@domain
## с галочкой во второй строке неймплейта. Капсула могла ещё не родиться (создаётся на первом
## state) — тогда адрес подхватится при создании из NetworkManager.verified_address_of.
func _on_identity_verified(id: int, address: String) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_verified_address(address)


## Резолвит идентификатор аватара и монтирует его в капсулу. Асинхронно для внешних URL,
## поэтому в колбэке перепроверяем: капсула жива и желаемый аватар не сменился. Дубли одного
## аватара (уже смонтирован) пропускаем — чтобы не пересобирать тело зря.
func _apply_avatar(id: int, uri: String) -> void:
	if uri.strip_edges() == "":
		return
	# Вердикт легитимности считаем даже если сцена уже смонтирована (манифест мог измениться /
	# капсула пересоздалась): он не завязан на дедуп монтажа аватара.
	_apply_verdict(id, uri)
	if _avatar_applied.get(id) == uri:
		return
	_resolver.resolve(uri, func(scene: PackedScene) -> void:
		if scene == null:
			return
		var cap: RemotePlayer = _capsules.get(id)
		if cap == null or _avatar_uris.get(id) != uri:
			return
		cap.set_avatar(scene)
		_avatar_applied[id] = uri
	)


## Резолвит манифест прав аватара и проставляет капсуле вердикт легитимности (жёлтый «⚠» у
## ника). Личность пира пока невозможно верифицировать (нет слоя идентичности), поэтому
## evaluate зовётся с identity_verified=false — всё кроме allow:["*"] даёт UNCONFIRMED.
## См. docs/avatars.md → «Защита владения аватаром».
func _apply_verdict(id: int, uri: String) -> void:
	_resolver.resolve_manifest(uri, func(m: AvatarManifest) -> void:
		var cap: RemotePlayer = _capsules.get(id)
		if cap == null or _avatar_uris.get(id) != uri:
			return
		var verdict := (AvatarManifest.Verdict.UNCONFIRMED if m == null
			else m.evaluate("", false))
		cap.set_avatar_legitimacy(verdict)
	)


## Сообщение чата от пира — показываем бабл над его капсулой (если она уже есть).
func _on_chat_received(id: int, text: String) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_chat(text)


## Голосовой кадр от пира — отдаём его капсуле (она поднимет воспроизведение). До первого
## state капсулы ещё нет: кадр роняем — это доли секунды в начале, на слух незаметно.
func _on_voice_received(id: int, payload: PackedByteArray) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.push_voice(payload)


## Пир ушёл, но NetworkManager ждёт его обратно (grace-период): капсулу НЕ сносим — переносим
## в пул призраков под его user_id, с иконкой «нет связи». Эмитится ПЕРЕД peer_left, поэтому
## к приходу peer_left капсулы в _capsules уже нет и она не будет освобождена.
func _on_peer_ghosted(user_id: String, peer_id: int, _nick: String) -> void:
	var cap: RemotePlayer = _capsules.get(peer_id)
	if cap == null:
		return
	# Один user_id мог «уйти» дважды (два клиента с общим user://) — старого призрака сносим.
	_on_ghost_expired(user_id)
	_capsules.erase(peer_id)
	_ghost_caps[user_id] = {
		"cap": cap,
		"face": _faces.get(peer_id),
		"uri": _avatar_uris.get(peer_id, ""),
		"applied": _avatar_applied.get(peer_id, ""),
	}
	cap.set_connection_lost(true)


## Grace-период истёк (или мы сами ушли из комнаты) — призрак уходит по-настоящему.
func _on_ghost_expired(user_id: String) -> void:
	var g: Dictionary = _ghost_caps.get(user_id, {})
	if g.is_empty():
		return
	_ghost_caps.erase(user_id)
	(g["cap"] as RemotePlayer).queue_free()


## Пир вернулся под новым peer_id — отдаём ему его капсулу-призрака. Эмитится ПЕРЕД
## identity_received, так что карточка следом применит свежие ник/лицо/аватар (если менялись).
## _avatar_applied переносим — тот же аватар не перемонтируется (нет «моргания» модели).
func _on_peer_reclaimed(user_id: String, peer_id: int) -> void:
	var g: Dictionary = _ghost_caps.get(user_id, {})
	if g.is_empty():
		return
	_ghost_caps.erase(user_id)
	var cap: RemotePlayer = g["cap"]
	# Гонка: state нового пира мог прийти раньше карточки — капсула под новый id уже создана.
	# Тогда призрак лишний: оставляем свежую капсулу, призрака сносим.
	if _capsules.has(peer_id):
		cap.queue_free()
		return
	_capsules[peer_id] = cap
	if g["face"] != null:
		_faces[peer_id] = g["face"]
	if g["uri"] != "":
		_avatar_uris[peer_id] = g["uri"]
	if g["applied"] != "":
		_avatar_applied[peer_id] = g["applied"]
	cap.set_connection_lost(false)
	# Верификация привязана к эфемерному peer_id — новый пир докажет личность заново
	# (identity_verified придёт следом), до тех пор адреса нет.
	cap.set_verified_address(NetworkManager.verified_address_of(peer_id))


## p2p-канал к пиру оборвался/поднялся, пока он ещё в комнате по сигналингу (обрыв ICE) —
## показываем/снимаем иконку «нет связи» на его капсуле.
func _on_p2p_connected(id: int) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_connection_lost(false)


func _on_p2p_disconnected(id: int) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_connection_lost(true)


## Капсула держателя grabbable-предмета по user_id (для attachment-модели GrabManager):
## живой пир — по привязке peer→user_id, призрак grace-периода — по своему user_id (предмет
## остаётся в руке замершей капсулы, пока авторитет не освободит его авто-release).
func capsule_for_user(user_id: String) -> Node3D:
	if user_id == "":
		return null
	for peer_id in _capsules:
		if NetworkManager.user_id_of(peer_id) == user_id:
			return _capsules[peer_id]
	var g: Dictionary = _ghost_caps.get(user_id, {})
	return g.get("cap") as Node3D if not g.is_empty() else null


func _on_peer_left(id: int) -> void:
	_faces.erase(id)
	_avatar_uris.erase(id)
	_avatar_applied.erase(id)
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.queue_free()
		_capsules.erase(id)
