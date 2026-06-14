class_name RemotePlayer
extends Node3D

## Капсула другого игрока в комнате. Чисто визуальный актор: позицию/поворот ей задаёт
## RemotePlayersView из сетевых сообщений. Состояние приходит ~15 Гц, поэтому к цели
## интерполируем, чтобы не было рывков.

@onready var _label: Label3D = $Label

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _has_target := false
var _nick := "Guest"

const LERP_RATE := 12.0


func _ready() -> void:
	# Ник могли задать до входа в дерево (когда @onready _label ещё null) — применяем тут.
	_label.text = _nick


## Ник можно задавать до add_child: значение запоминается и проставится в _ready.
func set_nick(nick: String) -> void:
	_nick = nick
	if _label != null:
		_label.text = nick


func set_state(pos: Vector3, yaw: float) -> void:
	_target_pos = pos
	_target_yaw = yaw
	if not _has_target:
		# Первый пакет — встаём сразу на место, без проезда из начала координат.
		global_position = pos
		rotation.y = yaw
		_has_target = true


func _physics_process(delta: float) -> void:
	if not _has_target:
		return
	var t := clampf(delta * LERP_RATE, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)
