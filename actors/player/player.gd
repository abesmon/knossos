class_name Player
extends CharacterBody3D

## Эктор-игрок: вид от первого лица. WASD — движение, мышь — взгляд, Space — прыжок,
## Shift — бег, ЛКМ/E — взаимодействие с порталом под прицелом, Esc — отпустить мышь.
## Сам не выполняет навигацию: активирует объект под прицелом через interact_at,
## объект (Portal/RichPanel) сам сообщает переход наружу.

## Прицел навёлся на активный (кликабельный/портальный) объект или ушёл с него.
## main подписывается и подсвечивает курсор-прицел. hint — «куда ведёт» объект под прицелом
## (для строки статуса, как превью ссылки в углу браузера); пустой — вести некуда / прицел ушёл.
signal aim_target_changed(active: bool, hint: String)

## Захват мыши (браузинг мира) включён/выключен. main по нему разрешает/запрещает
## фокусировку UI-элементов: пока ходим по миру, клавиатура их не достаёт.
signal mouse_capture_changed(captured: bool)

## Enter в браузинге мира — просьба открыть строку чата. main освобождает мышь и
## ставит фокус в поле ввода (отправка по Enter вернёт нас в браузинг).
signal chat_requested

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
var _aim_hint := ""          # последний показанный «куда ведёт» (эмитим только при смене)
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
# Продюсер параметров аватара: вычисляет сигналы игрока (скорость, grounded, наклон взгляда)
# и кормит ими шину. Снимок шлётся по сети чужим аватарам (см. RemotePlayersView).
@onready var _avatar_source: AvatarParameterSource = $AvatarParameterSource

var _local_avatar: LocalAvatar


func _ready() -> void:
	capture_mouse(true)
	_setup_local_avatar()


## Видимое тело игрока — чтобы видеть себя в зеркалах (как в VRChat). Тело висит на слое
## LocalAvatar.AVATAR_LAYER, который камера первого лица исключает (иначе своё тело
## загораживало бы обзор), а камеры зеркал — рендерят. Аватар делит шину параметров с
## продюсером, поэтому анимируется вживую.
func _setup_local_avatar() -> void:
	if _camera != null:
		_camera.cull_mask &= ~(1 << (LocalAvatar.AVATAR_LAYER - 1))
	_local_avatar = LocalAvatar.new()
	_local_avatar.name = "LocalAvatar"
	_local_avatar.setup(_avatar_source)
	add_child(_local_avatar)


## Телепортирует игрока и запоминает точку как новый респаун. Если задан look_at —
## разворачивает игрока лицом к этой точке по горизонтали и выравнивает взгляд по уровню
## (используется при спавне «у первого объекта страницы»).
func teleport_to(point: Vector3, face_target: Variant = null) -> void:
	_spawn = point
	global_position = point
	velocity = Vector3.ZERO
	if face_target != null:
		_face_point(face_target)


## Снимок позы для истории навигации: позиция тела, поворот по горизонтали (yaw) и
## наклон камеры (pitch). Возвращается как Dictionary, см. restore_pose.
func get_pose() -> Dictionary:
	return {
		"position": global_position,
		"yaw": rotation.y,
		"pitch": look_pitch(),
	}


## Восстанавливает позу из снимка get_pose (переход назад/вперёд по истории): ставит
## игрока ровно туда, где он стоял, вместо дефолтного спавна страницы.
func restore_pose(pose: Dictionary) -> void:
	var point: Vector3 = pose.get("position", global_position)
	_spawn = point
	global_position = point
	velocity = Vector3.ZERO
	rotation.y = pose.get("yaw", rotation.y)
	if _camera != null:
		_camera.rotation.x = pose.get("pitch", _camera.rotation.x)


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


## Снимок параметров аватара локального игрока для отправки по сети (см. AvatarParams).
func avatar_snapshot() -> Dictionary:
	return _avatar_source.snapshot()


func capture_mouse(on: bool) -> void:
	_looking = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	if on:
		# Уходим в браузинг мира: снимаем фокус с любого активного UI-элемента, чтобы
		# Space/Enter не «дожали» кнопку или поле ввода, на котором остался фокус.
		var vp := get_viewport()
		if vp != null:
			vp.gui_release_focus()
	mouse_capture_changed.emit(on)


## Окно/приложение потеряло фокус: Alt-Tab, переключение на другое приложение или открытие
## внешнего приложения по external-ссылке (mailto:/tel:/…). Сам MOUSE_MODE_CAPTURED при этом
## «залипает» — курсор ОС физически свободен, но движения мыши всё ещё крутят камеру. Снимаем
## захват, чтобы потеря фокуса гасила и захват движения; вернуться в браузинг — клик по окну.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _looking:
		capture_mouse(false)


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
			KEY_ENTER, KEY_KP_ENTER:
				if _looking:
					chat_requested.emit()


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
	_dispatch_hover()
	var col := _aim_collider()
	# is_active_at — есть ли подсветка курсора; aim_hint_at — «куда ведёт» (для строки статуса).
	var active: bool = col != null and col.has_method("is_active_at") \
			and col.is_active_at(_ray.get_collision_point())
	var hint: String = ""
	if active and col.has_method("aim_hint_at"):
		hint = col.aim_hint_at(_ray.get_collision_point())
	if active != _aim_active or hint != _aim_hint:
		_aim_active = active
		_aim_hint = hint
		aim_target_changed.emit(active, hint)


## Непрерывно кормит точкой прицела объект под лучом, если он этого хочет (метод hover_at) —
## в отличие от interact_at (по клику). Так VrwebVideoScreen ловит «движение мыши» по экрану и
## проявляет/прячет свой UI. Объект сам решает, когда UI гаснет (по таймауту), поэтому явного
## hover-exit не шлём — достаточно перестать звать hover_at, когда луч ушёл.
func _dispatch_hover() -> void:
	if _ray == null or not _ray.is_colliding():
		return
	var col := _ray.get_collider()
	if col != null and col.has_method("hover_at"):
		col.hover_at(_ray.get_collision_point())


## Объект под лучом прицела (или null, если луч ни во что не упёрся).
func _aim_collider() -> Object:
	if _ray == null or not _ray.is_colliding():
		return null
	return _ray.get_collider()


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
