class_name Player
extends CharacterBody3D

## Эктор-игрок: вид от первого лица. WASD — движение, мышь — взгляд, Space — прыжок,
## Shift — бег, ЛКМ/E — взаимодействие с порталом под прицелом, Esc — отпустить мышь.
## Сам не выполняет навигацию: активирует объект под прицелом через interact_at,
## объект (Portal/RichPanel) сам сообщает переход наружу.

## Прицел навёлся на активный (кликабельный/портальный) объект или ушёл с него.
## main подписывается и подсвечивает курсор-прицел.
signal aim_target_changed(active: bool)

## Отладочный режим инспектора провенанса (F3) включён/выключен. main показывает/прячет оверлей.
signal debug_toggled(on: bool)
## Текст провенанса узла под прицелом в отладочном режиме (пустой — под прицелом ничего).
signal debug_probed(text: String)

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
var _scroll_pending := 0.0   # накопленные тики колеса, гасятся в _physics_process
var _debug_on := false       # инспектор провенанса под прицелом (F3)
var _debug_last := ""        # последний показанный текст (эмитим только при смене)

const SCROLL_REACH := 12.0   # дальность луча прокрутки текста, м (длиннее, чем луч взаимодействия:
								# читают абзац издали, а не вплотную, как жмут портал)
const PANEL_MASK := 2        # слой кликабельных панелей (RichPanel/ImagePanel — collision_layer 2)
const TRACKPAD_SCROLL_SCALE := 0.5  # перевод delta.y pan-жеста тачпада в «тики» прокрутки
const DEBUG_META := "vrweb_debug"   # ключ метаданных провенанса на узлах мира (см. WorldGenerator)
const DEBUG_MASK := 3        # слои стен/полов (1) и панелей (2) — инспектор бьёт по всему
const DEBUG_REACH := 50.0    # дальность луча инспектора, м (рассматриваем и далёкие объекты)

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


## Наклон взгляда камеры (питч, рад): >0 — вверх, <0 — вниз. Транслируется по сети,
## чтобы лицо аватара слегка наклонялось туда же, куда смотрит игрок.
func look_pitch() -> float:
	return _camera.rotation.x if _camera != null else 0.0


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
	elif event is InputEventMouseButton and event.pressed and _looking \
			and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		# Гасим в _physics_process: запрос к direct_space_state безопасен только там.
		_scroll_pending += -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
	elif event is InputEventPanGesture and _looking:
		# Тачпад на macOS шлёт прокрутку двумя пальцами не колесом, а pan-жестом (delta.y).
		_scroll_pending += event.delta.y * TRACKPAD_SCROLL_SCALE
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				capture_mouse(false)
			KEY_E:
				_try_interact()
			KEY_F3:
				_toggle_debug()
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
	if _debug_on:
		_debug_probe()

	if _scroll_pending != 0.0:
		_do_scroll(_scroll_pending)
		_scroll_pending = 0.0

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


## --- Отладочный инспектор провенанса (F3) ---

## Переключает режим инспектора: каждый кадр пробивает луч из камеры и сообщает наружу
## происхождение узла под прицелом. При выключении гасит оверлей пустым текстом.
func _toggle_debug() -> void:
	_debug_on = not _debug_on
	debug_toggled.emit(_debug_on)
	if not _debug_on:
		_debug_last = ""
		debug_probed.emit("")


## Бьёт луч из камеры по всем мировым слоям и эмитит провенанс узла под прицелом.
## Текст ищется на ближайшем предке коллайдера с метаданными DEBUG_META (стены/полы держат
## его на холдере комнаты, объекты — на своём корне). Эмитим только при смене текста.
func _debug_probe() -> void:
	if _camera == null:
		return
	var from: Vector3 = _camera.global_position
	var to: Vector3 = from - _camera.global_transform.basis.z * DEBUG_REACH
	var query := PhysicsRayQueryParameters3D.create(from, to, DEBUG_MASK)
	query.collide_with_areas = true
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	var text := _find_debug_meta(hit.get("collider", null))
	if text != _debug_last:
		_debug_last = text
		debug_probed.emit(text)


## Поднимается от коллайдера к предкам в поисках метаданных провенанса (DEBUG_META).
func _find_debug_meta(node) -> String:
	var n: Node = node
	while n != null:
		if n.has_meta(DEBUG_META):
			return str(n.get_meta(DEBUG_META))
		n = n.get_parent()
	return ""


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


## Колесо мыши прокручивает длинную панель, на которую смотрит игрок (RichPanel со скроллом).
## Свой луч длиннее луча взаимодействия (_ray): абзац читают издали, не вплотную. dir: +1 вниз.
func _do_scroll(dir: float) -> void:
	if _camera == null:
		return
	var from: Vector3 = _camera.global_position
	var to: Vector3 = from - _camera.global_transform.basis.z * SCROLL_REACH
	var query := PhysicsRayQueryParameters3D.create(from, to, PANEL_MASK)
	query.collide_with_areas = false
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	var col = hit.get("collider", null)
	if col != null and col.has_method("scroll_by"):
		col.scroll_by(dir)
