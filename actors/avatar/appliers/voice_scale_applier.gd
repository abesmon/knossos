class_name VoiceScaleApplier
extends AvatarApplier

## Аппликатор «рта»: масштабирует выбранный узел по громкости голоса (VOICE 0..1) — простая
## имитация разговора без скелета и визем. В тишине узел можно либо схлопнуть до min_scale,
## либо целиком спрятать (hide_when_silent). По умолчанию двигаем только Y — этого хватает,
## чтобы «рот» открывался/закрывался. Кастомного кода аватару не нужно: кладём узел на модель,
## вешаем этот аппликатор и в инспекторе указываем target_path. См. docs/avatars.md.

## Узел, который масштабируем (например, Face/MouthObject у бандл-аватаров).
@export var target_path: NodePath
## Какие оси гонит голос (1 — драйвим, 0 — оставляем базовый масштаб узла). По умолчанию Y.
@export var scale_mask := Vector3(0, 1, 0)
## Масштаб затронутых осей в тишине (VOICE=0) и на максимуме (VOICE=1).
@export var min_scale := 0.15
@export var max_scale := 1.6
## Прятать узел целиком, пока голос ниже порога (полная тишина) — чтобы «рот» не маячил.
@export var hide_when_silent := true
@export var silent_threshold := 0.05
## Скорость сглаживания к цели: голос приходит рывками, рот должен «отрабатывать» плавно.
@export var lerp_rate := 18.0

var _target: Node3D
var _base_scale := Vector3.ONE
var _target_voice := 0.0
var _cur_voice := 0.0


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target != null:
		_base_scale = _target.scale


func _apply(pname: StringName, value: Variant) -> void:
	if pname == AvatarParams.VOICE:
		_target_voice = clampf(float(value), 0.0, 1.0)


func _process(delta: float) -> void:
	if _target == null:
		return
	var t := clampf(delta * lerp_rate, 0.0, 1.0)
	_cur_voice = lerpf(_cur_voice, _target_voice, t)
	if hide_when_silent:
		_target.visible = _cur_voice > silent_threshold
	var s := lerpf(min_scale, max_scale, _cur_voice)
	var sc := _base_scale
	if scale_mask.x > 0.0:
		sc.x = s
	if scale_mask.y > 0.0:
		sc.y = s
	if scale_mask.z > 0.0:
		sc.z = s
	_target.scale = sc
