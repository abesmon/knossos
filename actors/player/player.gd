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

## Esc, когда мышь уже отпущена (мы возимся с UI) — просьба открыть настройки.
## В браузинге мира тот же Esc сначала отпускает мышь (см. _unhandled_input).
signal settings_requested

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
var _hovered_ui: Object = null
var _focused_world_ui: Object = null
var _manipulating := false   # зажата средняя кнопка: мышь/колесо крутят держимый предмет
var _using_held := false     # ЛКМ нажата и ушла как use держимому предмету (для парного use_end)

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
## Система инструментов (см. docs/client/tools.md). Публичное: main подписывается на её сигналы
## (status_hint, image_pick_requested) и достаёт инструменты через tools.get_tool(id).
var tools: ToolManager


func _ready() -> void:
	capture_mouse(true)
	_setup_local_avatar()
	_setup_tools()
	_apply_fov()
	Settings.changed.connect(_apply_fov)


## Угол обзора камеры — из Settings.fov (настройки → «Основные»); применяется живьём при
## движении ползунка (см. scenes/settings.gd._on_fov_changed) и при сохранении.
func _apply_fov() -> void:
	if _camera != null:
		_camera.fov = Settings.fov


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


## Система инструментов: ToolManager создаёт инструменты (рисование, картинка, пузырь) и
## маршрутизирует ввод (хоткеи слотов, ЛКМ/ПКМ — из _unhandled_input). Артефакты вешаются
## в корень мира (наш родитель — он же переживает навигацию). См. docs/client/tools.md.
func _setup_tools() -> void:
	tools = ToolManager.new()
	tools.name = "ToolManager"
	add_child(tools)
	tools.setup(_camera, get_parent(), self)


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


var _mouse_capture_requested := false
var _mouse_focus_claims: Dictionary = {} # token -> reason; любой token удерживает UI-режим
var _next_mouse_focus_token := 1


## Базовое желание мира захватить мышь. Активные UI focus leases имеют приоритет: запрос
## запоминается, но применяется только после освобождения последнего token.
func capture_mouse(on: bool) -> void:
	_mouse_capture_requested = on
	_apply_mouse_capture(on and _mouse_focus_claims.is_empty())


## Компонент UI входит в стек требований свободной мыши. Возвращённый token обязан быть
## освобождён release_mouse_focus; порядок освобождения не важен, вложенные окна безопасны.
func claim_mouse_focus(reason: String) -> int:
	var token := _next_mouse_focus_token
	_next_mouse_focus_token += 1
	_mouse_focus_claims[token] = reason
	_apply_mouse_capture(false)
	return token


func release_mouse_focus(token: int) -> void:
	if token <= 0 or not _mouse_focus_claims.has(token):
		return
	_mouse_focus_claims.erase(token)
	_apply_mouse_capture(_mouse_capture_requested and _mouse_focus_claims.is_empty())


func mouse_is_captured() -> bool:
	return _looking


func _apply_mouse_capture(on: bool) -> void:
	if _looking == on and Input.mouse_mode == (Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE):
		return
	_looking = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	if on:
		# Уходим в браузинг мира: снимаем фокус с любого активного UI-элемента, чтобы
		# Space/Enter не «дожали» кнопку или поле ввода, на котором остался фокус.
		var vp := get_viewport()
		if vp != null:
			vp.gui_release_focus()
	# Инструменты сами решают, что отменять при смене захвата (прицеливание, незавершённый штрих).
	if tools != null:
		tools.on_mouse_capture_changed(on)
	mouse_capture_changed.emit(on)


## Окно/приложение потеряло фокус: Alt-Tab, переключение на другое приложение или открытие
## внешнего приложения по external-ссылке (mailto:/tel:/…). Сам MOUSE_MODE_CAPTURED при этом
## «залипает» — курсор ОС физически свободен, но движения мыши всё ещё крутят камеру. Снимаем
## захват, чтобы потеря фокуса гасила и захват движения; вернуться в браузинг — клик по окну.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _looking:
		capture_mouse(false)


func _unhandled_input(event: InputEvent) -> void:
	if is_instance_valid(_focused_world_ui):
		if event.is_action_pressed("ui_cancel"):
			_focused_world_ui.release_keyboard_focus()
			_focused_world_ui = null
			capture_mouse(true)
			get_viewport().set_input_as_handled()
			return
		if _focused_world_ui.forward_keyboard_input(event):
			get_viewport().set_input_as_handled()
			return
	else:
		_focused_world_ui = null
	if event is InputEventMouseMotion and _looking:
		# Зажата средняя кнопка и в руке adjustable-предмет — мышь вращает ЕГО, а не камеру
		# (в VRChat это неудобные клавиши I/J/K/L/U/O, см. docs/client/grabbable.md).
		var gm := _grab_manager()
		if _manipulating and gm != null and gm.holding_adjustable():
			gm.adjust_rotation(event.relative)
			return
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera.rotate_x(-event.relative.y * mouse_sensitivity)
		_camera.rotation.x = clamp(_camera.rotation.x, -1.4, 1.4)
	elif event.is_action_pressed("player_manipulate"):
		_manipulating = true
	elif event.is_action_released("player_manipulate"):
		_manipulating = false
	elif event.is_action_pressed("player_main_action"):
		if _looking:
			# Приоритет ЛКМ: активный инструмент → use держимого предмета → взаимодействие
			# (порталы/панели/взятие grabbable через interact_at).
			if not tools.handle_primary_pressed():
				var gm := _grab_manager()
				if gm != null and gm.local_held() != null:
					_using_held = true
					gm.use_held()
				else:
					_try_interact()
		else:
			capture_mouse(true)
	elif event.is_action_released("player_main_action"):
		# Отпускание основного действия — активному инструменту (завершить штрих и т.п.);
		# если нажатие ушло как use держимому предмету — парное use_end (фазы, как
		# OnPickupUseDown/Up в VRChat; см. docs/space/grabbable.md).
		if _looking:
			tools.handle_primary_released()
		if _using_held:
			_using_held = false
			var gm := _grab_manager()
			if gm != null:
				gm.use_held_end()
	elif event.is_action_pressed("player_secondary_action") and _looking:
		# Второстепенное действие — активному инструменту (отмена прицеливания и т.п.).
		tools.handle_secondary_pressed()
	elif _looking and event.is_action_pressed("player_scale_up"):
		if not _scroll_to_grabbable(1.0):
			# Гасим в _physics_process: запрос к direct_space_state безопасен только там.
			_scroll_pending += -1.0
	elif _looking and event.is_action_pressed("player_scale_down"):
		if not _scroll_to_grabbable(-1.0):
			_scroll_pending += 1.0
	elif event is InputEventPanGesture and _looking:
		# Тачпад на macOS шлёт прокрутку двумя пальцами не колесом, а pan-жестом (delta.y).
		_scroll_pending += event.delta.y * TRACKPAD_SCROLL_SCALE
	elif event.is_action_pressed("ui_cancel"):
		if _looking:
			# Из браузинга мира — сначала отпускаем мышь.
			capture_mouse(false)
		else:
			# Мышь уже свободна (возимся с UI) — Esc открывает настройки.
			# Гасим событие: иначе тот же Esc долетит до _unhandled_input
			# оверлея настроек и сразу же его закроет (а закрытие — recapture).
			settings_requested.emit()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("player_interact"):
		_try_interact()
	elif event.is_action_pressed("player_drop"):
		# G — положить держимый предмет в точку прицела (см. docs/client/grabbable.md).
		if _looking:
			var gm := _grab_manager()
			if gm != null:
				gm.release_held()
	elif event.is_action_pressed("tool_slot_2"):
		# Запрос активации инструменту слота 2 (рисование: нет → карандаш → ластик → нет).
		tools.handle_slot_action(&"tool_slot_2")
	elif event.is_action_pressed("tool_slot_3"):
		# Запрос активации инструменту слота 3 (размещение картинки: тумблер).
		tools.handle_slot_action(&"tool_slot_3")
	elif event.is_action_pressed("debug_toggle"):
		_toggle_debug()
	elif event.is_action_pressed("player_jump"):
		if _looking:
			_handle_space_tap()
	elif event.is_action_pressed("player_chat"):
		if _looking:
			chat_requested.emit()


## Захвачена ли мышь (браузинг мира). Инструменты по этому решают, можно ли активироваться.
func is_mouse_captured() -> bool:
	return _looking


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
	var script_input = _script_input_for(col)
	var active: bool = script_input != null or (col != null and col.has_method("is_active_at") \
			and col.is_active_at(_ray.get_collision_point()))
	var hint: String = ""
	if script_input != null:
		hint = script_input.hint()
	elif active and col.has_method("aim_hint_at"):
		hint = col.aim_hint_at(_ray.get_collision_point())
	if active != _aim_active or hint != _aim_hint:
		_aim_active = active
		_aim_hint = hint
		aim_target_changed.emit(active, hint)


## Непрерывно кормит точкой прицела world-space UI под лучом и явно сообщает уход hover.
## Это нужно canvas-контролам для mouse_exited и медиа-панелям для мгновенного сброса UI.
func _dispatch_hover() -> void:
	var current: Object = null
	var col := _aim_collider()
	if col != null and col.has_method("hover_at"):
		current = col
	if current != _hovered_ui:
		if is_instance_valid(_hovered_ui) and _hovered_ui.has_method("pointer_exit"):
			_hovered_ui.pointer_exit()
		_hovered_ui = current
		if current != null and current.has_method("pointer_enter"):
			current.pointer_enter()
	if current != null:
		current.hover_at(_ray.get_collision_point())


## Объект под лучом прицела (или null, если луч ни во что не упёрся).
func _aim_collider() -> Object:
	if _ray == null or not _ray.is_colliding():
		return null
	var collider := _ray.get_collider()
	if collider is Node and not (collider as Node).is_inside_tree():
		return null
	return collider


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
	if _looking and Input.is_action_pressed("player_jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := _move_axes()
	var speed := run_speed if Input.is_action_pressed("player_sprint") else walk_speed
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
		if Input.is_action_pressed("player_jump"):
			move.y += 1.0
		if Input.is_action_pressed("player_descend"):
			move.y -= 1.0
	var speed := run_speed * 1.8 if Input.is_action_pressed("player_sprint") else fly_speed
	velocity = move.normalized() * speed if move != Vector3.ZERO else Vector3.ZERO


## WASD как вектор (x: лево/право, y: вперёд(-)/назад(+)). Пусто, если курсор отпущен.
func _move_axes() -> Vector2:
	var d := Vector2.ZERO
	if not _looking:
		return d
	if Input.is_action_pressed("player_move_forward"):
		d.y -= 1.0
	if Input.is_action_pressed("player_move_back"):
		d.y += 1.0
	if Input.is_action_pressed("player_strafe_left"):
		d.x -= 1.0
	if Input.is_action_pressed("player_strafe_right"):
		d.x += 1.0
	return d


func _try_interact() -> void:
	var col := _aim_collider()
	if col == null:
		return
	# Единый интерфейс: и Portal, и RichPanel реализуют interact_at(точка_прицела).
	var script_input = _script_input_for(col)
	if script_input != null:
		script_input.dispatch(_ray.get_collision_point())
	elif col != null and col.has_method("interact_at"):
		col.interact_at(_ray.get_collision_point())
		if col.has_method("keyboard_focus_active") and col.keyboard_focus_active():
			_focused_world_ui = col
			capture_mouse(false)


## --- Grabbable-предметы (docs/client/grabbable.md) ---

## Менеджер grabbable живёт в мире (пересоздаётся при навигации) — ищем через группу.
func _grab_manager() -> GrabManager:
	var node := get_tree().get_first_node_in_group("grab_manager")
	return node as GrabManager


## Данные прицела для скриптов (capability vrweb/aim/1, см. docs/space/scripting-api.md):
## точка/нормаль/дистанция луча взаимодействия и коллайдер под прицелом. Держимый предмет
## исключён из луча (set_aim_exception), поэтому прицел «сквозь предмет» — как у курсора.
func aim_info() -> Dictionary:
	if _ray == null or not _ray.is_colliding():
		return {"hit": false}
	var point := _ray.get_collision_point()
	return {
		"hit": true,
		"position": point,
		"normal": _ray.get_collision_normal(),
		"distance": _camera.global_position.distance_to(point) if _camera != null else 0.0,
		"collider": _aim_collider(),
	}


## Колесо мыши при держимом adjustable-предмете: обычное — дистанция (ближе/дальше, как в
## VRChat), с зажатой средней кнопкой — roll. Возвращает true, если событие поглощено
## (тогда прокрутка панелей не срабатывает).
func _scroll_to_grabbable(steps: float) -> bool:
	var gm := _grab_manager()
	if gm == null or not gm.holding_adjustable():
		return false
	if _manipulating:
		gm.adjust_roll(steps)
	else:
		gm.adjust_distance(steps)
	return true


## Держимый предмет исключается из собственного клик-луча: он висит перед камерой и иначе
## перекрывал бы прицел (лучи других игроков его по-прежнему видят — theft работает).
func set_aim_exception(body: CollisionObject3D, on: bool) -> void:
	if _ray == null or not is_instance_valid(body):
		return
	if on:
		_ray.add_exception(body)
	else:
		_ray.remove_exception(body)


## Держим ли предмет рукой — в шину аватара (HoldLeft/HoldRight, аватар может сжать кисть).
func set_holding(hand: String, held: bool) -> void:
	if _avatar_source == null:
		return
	var pname := AvatarParams.HOLD_LEFT if hand == "left" else AvatarParams.HOLD_RIGHT
	_avatar_source.params.set_value(pname, held)


func _script_input_for(node: Object):
	if node == null or not node.has_meta(VrwebScriptInputBridge.META):
		return null
	var bridge = node.get_meta(VrwebScriptInputBridge.META)
	return bridge if bridge is VrwebScriptInputBridge else null


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
