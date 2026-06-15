class_name LookPitchApplier
extends AvatarApplier

## Универсальный аппликатор: вращает заданный узел вокруг локальной X по сигналу LookPitch,
## умноженному на pitch_factor. Один скрипт на оба прежних сценария — «наклон лица» и «поворот
## головы»: вся разница в множителе (сила и знак). Сглаживает к цели в _process (состояние
## приходит ~15 Гц).

## Узел, который вращаем (квад лица, голова-узел…).
@export var target_path: NodePath
## Множитель к углу взгляда: 1.0 — один-в-один, 0.35 — слабее, отрицательный — в другую сторону
## (знак зависит от базовой ориентации узла).
@export var pitch_factor := 1.0
@export var lerp_rate := 12.0

var _target: Node3D
var _base_basis: Basis
var _target_pitch := 0.0
var _cur_pitch := 0.0


func _ready() -> void:
	_target = get_node(target_path)
	_base_basis = _target.transform.basis   # базовая ориентация узла


func _apply(pname: StringName, value: Variant) -> void:
	if pname == AvatarParams.LOOK_PITCH:
		_target_pitch = value


func _process(delta: float) -> void:
	var t := clampf(delta * lerp_rate, 0.0, 1.0)
	_cur_pitch = lerp_angle(_cur_pitch, _target_pitch * pitch_factor, t)
	_target.transform.basis = Basis(Vector3(1, 0, 0), _cur_pitch) * _base_basis
