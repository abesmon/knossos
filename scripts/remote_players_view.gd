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

var _player: Node3D
var _capsules := {}   # peer_id -> RemotePlayer
var _faces := {}      # peer_id -> Texture2D (карточка могла прийти до создания капсулы)
var _send_accum := 0.0


## Подключает view к сети и к локальному игроку (позицию которого транслируем).
func setup(player: Node3D) -> void:
	_player = player
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.state_received.connect(_on_state_received)
	NetworkManager.identity_received.connect(_on_identity_received)
	NetworkManager.chat_received.connect(_on_chat_received)


func _exit_tree() -> void:
	# View пересоздаётся на каждой странице — отписываемся, чтобы не плодить коннекты.
	if NetworkManager.peer_joined.is_connected(_on_peer_joined):
		NetworkManager.peer_joined.disconnect(_on_peer_joined)
		NetworkManager.peer_left.disconnect(_on_peer_left)
		NetworkManager.state_received.disconnect(_on_state_received)
		NetworkManager.identity_received.disconnect(_on_identity_received)
		NetworkManager.chat_received.disconnect(_on_chat_received)


func _physics_process(delta: float) -> void:
	if _player == null or not NetworkManager.is_online():
		return
	_send_accum += delta
	if _send_accum >= 1.0 / SEND_HZ:
		_send_accum = 0.0
		NetworkManager.send_state(_player.global_position, _player.rotation.y, _player.look_pitch())


func _on_peer_joined(id: int, nick: String) -> void:
	# Ник запоминаем сразу; капсулу создаём на первом state (см. _on_state_received).
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_nick(nick)


func _on_state_received(id: int, position: Vector3, look_yaw: float, look_pitch: float) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap == null:
		cap = REMOTE_PLAYER.instantiate()
		cap.set_nick(NetworkManager.nick_of(id))
		if _faces.has(id):
			cap.set_face(_faces[id])   # карточка пришла раньше первого state
		add_child(cap)
		_capsules[id] = cap
	cap.set_state(position, look_yaw, look_pitch)


## Пришла карточка пира: запоминаем лицо и обновляем ник/лицо, если капсула уже есть.
func _on_identity_received(id: int, nick: String, face: Texture2D) -> void:
	if face != null:
		_faces[id] = face
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_nick(nick)
		if face != null:
			cap.set_face(face)


## Сообщение чата от пира — показываем бабл над его капсулой (если она уже есть).
func _on_chat_received(id: int, text: String) -> void:
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.set_chat(text)


func _on_peer_left(id: int) -> void:
	_faces.erase(id)
	var cap: RemotePlayer = _capsules.get(id)
	if cap != null:
		cap.queue_free()
		_capsules.erase(id)
