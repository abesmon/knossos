class_name Player
extends CharacterBody3D

## Эктор-игрок: вид от первого лица. WASD — движение, мышь — взгляд, Space — прыжок,
## Shift — бег, ЛКМ/E — взаимодействие с порталом под прицелом, Esc — отпустить мышь.
## Сам не выполняет навигацию: активирует объект под прицелом через interact_at,
## объект (Portal/RichPanel) сам сообщает переход наружу.

## Прицел навёлся на активный (кликабельный/портальный) объект или ушёл с него.
## main подписывается и подсвечивает курсор-прицел.
signal aim_target_changed(active: bool)

@export var walk_speed := 5.0
@export var run_speed := 9.0
@export var fly_speed := 10.0
@export var jump_velocity := 5.0
@export var mouse_sensitivity := 0.0025
@export var fall_limit := -20.0      # ниже — респаун (только без полёта)
@export var double_tap_time := 0.3   # окно двойного нажатия пробела для полёта

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _spawn := Vector3(0, 1, 0)
var _looking := false
var _flying := false
var _last_space_time := -1.0
var _aim_active := false

@onready var _camera: Camera3D = $Camera3D
@onready var _ray: RayCast3D = $Camera3D/RayCast3D


func _ready() -> void:
	capture_mouse(true)


## Телепортирует игрока и запоминает точку как новый респаун. Если задан look_at —
## разворачивает игрока лицом к этой точке по горизонтали и выравнивает взгляд по уровню
## (используется при спавне «у первого объекта страницы»).
func teleport_to(point: Vector3, face_target: Variant = null) -> void:
	_spawn = point
	global_position = point
	velocity = Vector3.ZERO
	if face_target != null:
		_face_point(face_target)


## Разворот корпуса по горизонтали к точке (камера смотрит вдоль локального -Z) + сброс
## наклона камеры в уровень.
func _face_point(target: Vector3) -> void:
	var dir: Vector3 = target - global_position
	dir.y = 0.0
	if dir.length() < 0.001:
		return
	rotation.y = atan2(-dir.x, -dir.z)
	if _camera != null:
		_camera.rotation.x = 0.0


func capture_mouse(on: bool) -> void:
	_looking = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _looking:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera.rotate_x(-event.relative.y * mouse_sensitivity)
		_camera.rotation.x = clamp(_camera.rotation.x, -1.4, 1.4)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _looking:
			_try_interact()
		else:
			capture_mouse(true)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				capture_mouse(false)
			KEY_E:
				_try_interact()
			KEY_SPACE:
				if _looking:
					_handle_space_tap()


## Двойное нажатие пробела включает/выключает полёт.
func _handle_space_tap() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_space_time < double_tap_time:
		_flying = not _flying
		velocity = Vector3.ZERO
	_last_space_time = now


func _physics_process(delta: float) -> void:
	if _flying:
		_fly()
	else:
		_walk(delta)
	move_and_slide()
	_update_aim()

	# Респаун при падении в пустоту — только в обычном режиме.
	if not _flying and global_position.y < fall_limit:
		teleport_to(_spawn)


## Следит, наведён ли прицел на активный объект, и сообщает наружу только при смене
## состояния (чтобы main не дёргал UI каждый кадр).
func _update_aim() -> void:
	var active := _aim_active_at_ray()
	if active != _aim_active:
		_aim_active = active
		aim_target_changed.emit(active)


func _aim_active_at_ray() -> bool:
	if _ray == null or not _ray.is_colliding():
		return false
	var col := _ray.get_collider()
	if col == null or not col.has_method("is_active_at"):
		return false
	return col.is_active_at(_ray.get_collision_point())


func _walk(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if _looking and Input.is_physical_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := _move_axes()
	var speed := run_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	var dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if dir != Vector3.ZERO:
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)


func _fly() -> void:
	# Полёт: гравитации нет, WASD — по направлению взгляда, Space — вверх, Ctrl — вниз.
	var input_dir := _move_axes()
	var move := Vector3.ZERO
	if _looking:
		var cam_basis := _camera.global_transform.basis
		move = -cam_basis.z * (-input_dir.y) + cam_basis.x * input_dir.x
		if Input.is_physical_key_pressed(KEY_SPACE):
			move.y += 1.0
		if Input.is_physical_key_pressed(KEY_CTRL):
			move.y -= 1.0
	var speed := run_speed * 1.8 if Input.is_physical_key_pressed(KEY_SHIFT) else fly_speed
	velocity = move.normalized() * speed if move != Vector3.ZERO else Vector3.ZERO


## WASD как вектор (x: лево/право, y: вперёд(-)/назад(+)). Пусто, если курсор отпущен.
func _move_axes() -> Vector2:
	var d := Vector2.ZERO
	if not _looking:
		return d
	if Input.is_physical_key_pressed(KEY_W):
		d.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		d.y += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		d.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		d.x += 1.0
	return d


func _try_interact() -> void:
	if _ray == null or not _ray.is_colliding():
		return
	var col := _ray.get_collider()
	# Единый интерфейс: и Portal, и RichPanel реализуют interact_at(точка_прицела).
	if col != null and col.has_method("interact_at"):
		col.interact_at(_ray.get_collision_point())
