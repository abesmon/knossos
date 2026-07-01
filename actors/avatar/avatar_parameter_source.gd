class_name AvatarParameterSource
extends Node

## Продюсер параметров: вычисляет сигналы локального игрока из его CharacterBody3D и пишет
## в свою шину каждый физический кадр. Это единая точка расширения «какие сигналы излучает
## игрок» — добавить новый параметр значит дописать его расчёт здесь.
##
## snapshot() отдаёт словарь для отправки по сети (RemotePlayersView). Шину же может читать
## будущий локальный/зеркальный аватар — источник от потребителей отвязан.
##
## Вешается дочерним узлом на Player; тело берётся как родитель (или задаётся через body).

var params := AvatarParameters.new()

var _body: CharacterBody3D
var _prev_yaw := 0.0
var _has_prev_yaw := false


func _ready() -> void:
	if _body == null:
		_body = get_parent() as CharacterBody3D
	params.set_value(AvatarParams.IS_LOCAL, true)


## Явно задать тело-источник (если узел не прямой ребёнок игрока).
func set_body(body: CharacterBody3D) -> void:
	_body = body


func _physics_process(delta: float) -> void:
	# Громкость собственного голоса — для зеркала (LocalAvatar делит эту шину). Берём живой
	# уровень входа из VoiceManager, но только пока открыт клапан передачи (is_voicing: PTT-удержание
	# или VAD-речь без мьюта) — чтобы «рот» в зеркале двигался ровно тогда же, когда его видят
	# другие, и не дёргался на фоновом шуме/на мьюте.
	var voice := 0.0
	if VoiceManager.is_voicing():
		voice = clampf(VoiceManager.input_level() * AvatarParams.VOICE_RMS_GAIN, 0.0, 1.0)
	params.set_value(AvatarParams.VOICE, voice)

	if _body == null:
		return

	# Скорость в локальные оси тела: X — вбок, Y — вверх, Z — вперёд(−)/назад(+).
	var local_vel: Vector3 = _body.global_transform.basis.inverse() * _body.velocity
	params.set_value(AvatarParams.VELOCITY_X, local_vel.x)
	params.set_value(AvatarParams.VELOCITY_Y, local_vel.y)
	params.set_value(AvatarParams.VELOCITY_Z, local_vel.z)
	var mag: float = _body.velocity.length()
	params.set_value(AvatarParams.VELOCITY_MAGNITUDE, mag)
	params.set_value(AvatarParams.MOVING, mag > AvatarParams.MOVING_EPSILON)

	# Угловая скорость по Y — по дельте yaw за кадр.
	var yaw: float = _body.rotation.y
	if _has_prev_yaw and delta > 0.0:
		params.set_value(AvatarParams.ANGULAR_Y, angle_difference(_prev_yaw, yaw) / delta)
	_prev_yaw = yaw
	_has_prev_yaw = true

	params.set_value(AvatarParams.GROUNDED, _body.is_on_floor())

	# Наклон взгляда отдаёт сам контроллер (камера живёт на нём, не на теле).
	if _body.has_method("look_pitch"):
		params.set_value(AvatarParams.LOOK_PITCH, _body.look_pitch())


## Снимок текущих параметров для отправки по сети.
func snapshot() -> Dictionary:
	return params.snapshot()
