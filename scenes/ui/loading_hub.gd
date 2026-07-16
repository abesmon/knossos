class_name LoadingHub
extends Node3D

## Нейтральное 3D-пространство между страницами. Собственная камера делает хаб пригодным
## для обычного viewport сейчас и оставляет явную точку замены на XR-origin/camera в будущем.

@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _status: Label3D = $ContentAnchor/Status

var _status_base := "Загрузка"
var _dots_time := 0.0
var _return_camera: Camera3D
var _yaw := 0.0
var _pitch := 0.0

const MOUSE_SENSITIVITY := 0.0025


func _ready() -> void:
	# Player сохраняется между мирами вместе с LocalAvatar для зеркал. Камера хаба, как и
	# камера первого лица, не должна снимать слой собственного тела.
	_camera.cull_mask &= ~(1 << (LocalAvatar.AVATAR_LAYER - 1))
	_status.text = _status_base
	if visible:
		_activate_camera()
	else:
		# Невидимая Camera3D всё равно участвует в автоматическом выборе current-камеры,
		# а отдельного enabled у Camera3D в текущей версии Godot нет. Убираем её из дерева.
		_camera.current = false
		_camera_rig.remove_child(_camera)


func _exit_tree() -> void:
	# Камера могла остаться отсоединённой после close(); тогда родитель её уже не освободит.
	if is_instance_valid(_camera) and _camera.get_parent() == null:
		_camera.free()


func _process(delta: float) -> void:
	if not visible:
		return
	_dots_time += delta
	_status.text = _status_base + ".".repeat(1 + int(_dots_time * 2.0) % 3)


func _unhandled_input(event: InputEvent) -> void:
	# Desktop-look для перехода, начатого из захваченного режима мира. В XR ориентацию
	# CameraRig позже будет задавать tracking, не меняя ContentAnchor и сферу окружения.
	if not visible or not (event is InputEventMouseMotion):
		return
	# На первой загрузке курсор ещё свободен — там осмотр работает перетаскиванием ЛКМ.
	# При переходе из мира мышь уже захвачена и отдельный drag не нужен.
	var dragging := bool(event.button_mask & MOUSE_BUTTON_MASK_LEFT)
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not dragging:
		return
	_yaw -= event.relative.x * MOUSE_SENSITIVITY
	_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.45, 1.45)
	_camera_rig.rotation.y = _yaw
	_camera.rotation.x = _pitch
	get_viewport().set_input_as_handled()


func open(status: String = "Загрузка") -> void:
	_status_base = status.strip_edges().rstrip(".")
	if _status_base.is_empty():
		_status_base = "Загрузка"
	_dots_time = 0.0
	if not visible:
		visible = true
	# Камера мира могла стать current уже после появления хаба (например, Player создаётся
	# в _ready родительской сцены). Поэтому каждый open подтверждает камеру хаба, даже если
	# сам хаб всё это время оставался видимым.
	_activate_camera()
	if is_node_ready():
		_status.text = _status_base + "."


func set_status(status: String) -> void:
	open(status)


func close() -> void:
	visible = false
	_camera.current = false
	if is_instance_valid(_return_camera):
		_return_camera.current = true
	_return_camera = null
	if _camera.get_parent() == _camera_rig:
		_camera_rig.remove_child(_camera)


func _activate_camera() -> void:
	if not is_node_ready():
		return
	var active := get_viewport().get_camera_3d()
	if active != _camera:
		_return_camera = active
	if _camera.get_parent() == null:
		_camera_rig.add_child(_camera)
	_camera.current = true
