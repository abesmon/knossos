class_name Grabbable
extends StaticBody3D

## Обёртка <VRWebGrabbable>: делает произвольное VRWML-содержимое предметом, который можно
## взять в руку (см. docs/space/grabbable.md — норматив; docs/client/grabbable.md — клиент).
## Hold-состояние ведёт GrabManager через Replicated State. Если ровно один прямой ребёнок —
## RigidBody3D, он становится физическим корнем того же subject: в свободном режиме обёртка
## следует за ним, а во время удержания сетевой adapter приостанавливается и позу выводит рука.
##
## Тело — StaticBody3D на слое 2 (как пузырь/панели): его ловит только клик-луч игрока,
## тело игрока проходит сквозь. Без явного CollisionShape3D-ребёнка коллайдер строится
## автоматически из объединённого AABB видимой геометрии.

## Портируемые события для скриптинга страницы (handle.on): grab/drop — на всех клиентах из
## канонических дельт; use — transient, только на клиенте держателя.
signal grab(user_id: String, hand: String)
signal drop(user_id: String, hand: String)
signal use(user_id: String, hand: String)
signal use_end(user_id: String, hand: String)

const GROUP := "grabbables"

## Стабильный id элемента страницы. Пустой — предмет не синхронизируется и не интерактивен
## (норматив: сетевой адрес выводится только из авторского id).
var grab_id := ""
## Политика кражи (атрибут theft): можно ли перехватывать из чужой руки.
var theft_allowed := true
## Авторский хват для режима fixed: поза предмета относительно якоря руки (атрибут grip).
## В режиме adjustable игнорируется — хват берётся из фактической позы в момент захвата.
var grip_transform := Transform3D.IDENTITY
## Режим удержания (атрибут mode): false — fixed (снап в авторский хват, аналог VRChat
## Orientation=Grip/ExactGrip), true — adjustable (естественный хват в момент захвата +
## подстройка держателем, аналог VRChat Orientation=None + AllowManipulationWhenEquipped).
var adjustable := false
## Можно ли взять предмет (скриптовая ручка set_enabled, аналог VRChat pickupable):
## false блокирует новые захваты, но не выбивает предмет из уже держащей руки.
var enabled := true

var _manager: Node = null
var _auto_shape: CollisionShape3D = null
var _shape_dirty := false
var _frozen_bodies: Dictionary = {}   # RigidBody3D -> прежний freeze
var _initial_child_poses: Dictionary = {}  # Node3D (прямой ребёнок) -> Transform3D
var _network_body: RigidBody3D = null
var _network_body_top_level := false
var _held_presentation := false


func _init() -> void:
	collision_layer = 2
	collision_mask = 0


func _ready() -> void:
	add_to_group(GROUP)
	_capture_child_poses()
	_configure_network_body()
	_request_shape_rebuild()
	# Дети эфемерных grabbable монтируются позже отдельными объектами (build_element детей
	# не строит) — коллайдер и исходные позы догоняют их появление.
	child_entered_tree.connect(_on_child_changed)
	child_exiting_tree.connect(_on_child_changed)
	var manager := get_tree().get_first_node_in_group("grab_manager")
	if manager != null:
		bind_manager(manager)


## Привязка к менеджеру. Зовётся с двух сторон: самим предметом (если менеджер уже есть) и
## менеджером при его появлении. Второе обязательно: снимок сцены может материализовать
## предметы РАНЬШЕ менеджера (бандловый item собирается синхронно), и без усыновления такой
## предмет навсегда остался бы без владельца — висел бы в воздухе и не брался в руку.
func bind_manager(manager: Node) -> void:
	if manager == null or not manager.has_method("register_grabbable"):
		return
	if _manager != manager:
		_manager = manager
	# Повторный вызов намеренный: GrabManager использует его для самовосстановления, если
	# scene_reset заменил/удалил registry-запись между _ready нового и _exit_tree старого узла.
	manager.register_grabbable(self)


func _exit_tree() -> void:
	if _manager != null and is_instance_valid(_manager) and _manager.has_method("unregister_grabbable"):
		_manager.unregister_grabbable(self)
	_manager = null


# --- Утиный интерфейс клик-луча (как Portal/Bubble) ---

func is_active_at(_point: Vector3) -> bool:
	if grab_id == "" or not enabled:
		return false
	return _manager == null or not _manager.has_method("can_local_grab") \
			or _manager.can_local_grab(self)


func aim_hint_at(_point: Vector3) -> String:
	if grab_id == "" or not enabled:
		return ""
	if _manager != null and _manager.has_method("hint_for"):
		return _manager.hint_for(self)
	return "Взять"


func interact_at(_point: Vector3) -> void:
	if grab_id == "" or not enabled or _manager == null or not _manager.has_method("request_grab"):
		return
	_manager.request_grab(self)


# --- Скриптовая поверхность (capability vrweb/grabbable/1, handle.call) ---

## Программно положить предмет — действует только на клиенте держателя (release семантики
## схемы; чужой клиент физически не может отпустить не свою руку). Имя release, а не drop:
## drop занят одноимённым сигналом.
func release() -> bool:
	if _manager == null or not _manager.has_method("release_object"):
		return false
	return _manager.release_object(self)


## user_id текущего держателя ("" — свободен).
func holder() -> String:
	if _manager == null or not _manager.has_method("holder_of"):
		return ""
	return _manager.holder_of(self)


## Рука держателя ("" — свободен).
func held_hand() -> String:
	if _manager == null or not _manager.has_method("held_hand_of"):
		return ""
	return _manager.held_hand_of(self)


func simulator() -> String:
	if _manager == null or not _manager.has_method("simulator_of"):
		return ""
	return _manager.simulator_of(self)


func set_enabled(on: bool) -> bool:
	enabled = on
	return true


func is_enabled() -> bool:
	return enabled


# --- Состояние удержания (вызывает GrabManager) ---

## Вход/выход из удержания. На время удержания собственное движение содержимого
## приостанавливается (freeze RigidBody3D с запоминанием прежнего значения), а прямые дети
## возвращаются в авторскую позу — чтобы предмет лежал в руке одинаково у всех клиентов,
## сколько бы его содержимое ни укатилось до захвата.
func set_held(held: bool) -> void:
	_held_presentation = held
	if held:
		_follow_network_body()
		_frozen_bodies.clear()
		for body in find_children("*", "RigidBody3D", true, false):
			_frozen_bodies[body] = (body as RigidBody3D).freeze
			if body == _network_body:
				(body as RigidBody3D).top_level = false
			(body as RigidBody3D).freeze = true
		_restore_child_poses()
	else:
		if _network_body != null and is_instance_valid(_network_body):
			var local_pose: Transform3D = _initial_child_poses.get(_network_body, Transform3D.IDENTITY)
			_network_body.global_transform = global_transform * local_pose
			_network_body.top_level = _network_body_top_level
		for body in _frozen_bodies:
			if is_instance_valid(body):
				(body as RigidBody3D).freeze = bool(_frozen_bodies[body])
		_frozen_bodies.clear()


## Канонический rest применён: предмет встаёт в позу покоя (в пространстве СВОЕГО родителя),
## содержимое — в авторскую позу. Так сходятся и rigid-предметы, чья локальная симуляция
## успела разойтись у клиентов.
func apply_rest(pose) -> void:
	transform = GrabStateSchema.unpack_transform(pose)
	_restore_child_poses()


## Текущая поза покоя в пространстве родителя — для команды release.
func rest_pose_from_world(world_target: Transform3D) -> Array:
	var parent_3d := get_parent() as Node3D
	var local := world_target if parent_3d == null \
			else parent_3d.global_transform.affine_inverse() * world_target
	return GrabStateSchema.pack_transform(local)


# --- Авто-коллайдер и авторские позы детей ---

func _on_child_changed(_node: Node) -> void:
	_capture_child_poses()
	_configure_network_body.call_deferred()
	_request_shape_rebuild()


func _capture_child_poses() -> void:
	for child in get_children():
		if child is Node3D and not _initial_child_poses.has(child) and child != _auto_shape:
			_initial_child_poses[child] = (child as Node3D).transform


func _restore_child_poses() -> void:
	for child in _initial_child_poses:
		if is_instance_valid(child):
			if child == _network_body and (_network_body as RigidBody3D).top_level:
				(_network_body as RigidBody3D).global_transform = global_transform \
						* (_initial_child_poses[child] as Transform3D)
			else:
				(child as Node3D).transform = _initial_child_poses[child]


## Единственный direct RigidBody3D может быть физическим корнем grabbable. В свободном режиме
## он top-level, а обёртка следует за ним: aim collider остаётся на реально летящем предмете.
func _configure_network_body() -> void:
	if _network_body != null and is_instance_valid(_network_body):
		return
	var candidates := []
	for child in get_children():
		if child is RigidBody3D:
			candidates.append(child)
	if candidates.size() != 1:
		return
	_network_body = candidates[0]
	_network_body_top_level = true
	if not _held_presentation:
		var world := _network_body.global_transform
		_network_body.top_level = true
		_network_body.global_transform = world


func _physics_process(_delta: float) -> void:
	if not _held_presentation:
		_follow_network_body()


func _follow_network_body() -> void:
	if _network_body == null or not is_instance_valid(_network_body) or not _network_body.top_level:
		return
	var local_pose: Transform3D = _initial_child_poses.get(_network_body, Transform3D.IDENTITY)
	global_transform = _network_body.global_transform * local_pose.affine_inverse()


func network_body() -> RigidBody3D:
	return _network_body if _network_body != null and is_instance_valid(_network_body) else null


func network_snapshot(epoch: int, tick: int, velocity_override = null) -> Dictionary:
	var body := network_body()
	if body == null:
		return {}
	var result := RigidbodyStateSchema.snapshot(body, epoch, tick)
	if typeof(velocity_override) == TYPE_VECTOR3:
		result["linear_velocity"] = RigidbodyStateSchema.pack_vector(velocity_override)
	return result


func _request_shape_rebuild() -> void:
	if _shape_dirty:
		return
	_shape_dirty = true
	_rebuild_shape.call_deferred()


## Явный CollisionShape3D-ребёнок уважается; иначе строим бокс по объединённому AABB
## видимой геометрии (пустая обёртка получает маленький бокс-заглушку, чтобы в неё можно
## было прицелиться).
func _rebuild_shape() -> void:
	_shape_dirty = false
	if not is_inside_tree():
		return
	for child in get_children():
		if child is CollisionShape3D and child != _auto_shape:
			if _auto_shape != null and is_instance_valid(_auto_shape):
				_auto_shape.queue_free()
				_auto_shape = null
			return
	var merged := AABB()
	var found := false
	var inverse := global_transform.affine_inverse()
	for vi in find_children("*", "VisualInstance3D", true, false):
		var rel: Transform3D = inverse * (vi as VisualInstance3D).global_transform
		var local_aabb: AABB = rel * (vi as VisualInstance3D).get_aabb()
		merged = local_aabb if not found else merged.merge(local_aabb)
		found = true
	if not found:
		merged = AABB(Vector3(-0.15, -0.15, -0.15), Vector3(0.3, 0.3, 0.3))
	var box := BoxShape3D.new()
	box.size = merged.size.max(Vector3(0.05, 0.05, 0.05))
	if _auto_shape == null or not is_instance_valid(_auto_shape):
		_auto_shape = CollisionShape3D.new()
		_auto_shape.name = "AutoGrabShape"
		add_child(_auto_shape)
	_auto_shape.shape = box
	_auto_shape.position = merged.get_center()
