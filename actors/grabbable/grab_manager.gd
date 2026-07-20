class_name GrabManager
extends Node

## Клиентская половина grabbable-системы (docs/client/grabbable.md). Держит реестр
## Grabbable-узлов мира, ведёт их hold-состояние через общий Replicated State
## (schema GrabStateSchema — норматив в docs/space/grabbable.md) и реализует
## attachment-модель: по сети идёт только (holder, hand, grip, rest), а мировую позу
## держимого предмета каждый клиент выводит сам из якоря руки локально
## интерполированного аватара — ноль трафика во время удержания.
##
## Живёт в мире (сносится при навигации). Grabbable-узлы регистрируются сами через
## группу "grab_manager" — сканов/ресканов при стриминге страницы не нужно.

const SCHEMA_ID := GrabStateSchema.ID
const SCHEMA_VERSION := GrabStateSchema.VERSION
const OBJECT_PREFIX := "grab:"
const HAND_RIGHT := "right"
const HAND_LEFT := "left"
const SWEEP_INTERVAL := 1.0

## Синтетические fallback-якоря (норматив разрешает клиенту свои): точка «руки» на капсуле
## без AvatarAttachmentPoint и «рука» десктопного первого лица под камерой (приём HAND_OFFSET
## системы инструментов).
const FALLBACK_CAPSULE_OFFSET := Vector3(0.35, 1.05, -0.25)
const LOCAL_HAND_OFFSET := Vector3(0.32, -0.25, -0.7)

## Пределы подстройки adjustable-предмета (клиентская политика, не норматив): дистанция вдоль
## взгляда и чувствительность колеса/мыши.
const MIN_HOLD_DISTANCE := 0.35
const MAX_HOLD_DISTANCE := 3.5
const DISTANCE_STEP := 0.18
const ROTATE_SENSITIVITY := 0.01
const ROLL_STEP := 0.20
## Как часто подстройка держателя уходит в канон (остальным). Промежуточные кадры держатель
## видит локально-оптимистично, поэтому редких коммитов достаточно и трафик ограничен.
const ADJUST_COMMIT_INTERVAL := 0.12

var _player: Node3D = null
var _remote_view: Node = null
var _grabbables: Dictionary = {}   # object_id -> Grabbable
var _held: Dictionary = {}         # object_id -> {holder: String, hand: String, grip: Transform3D}
var _local_held: Dictionary = {}   # hand -> object_id
var _sweep_accum := 0.0
## Оптимистичный хват СВОЕГО предмета: пока держим сами, источник картинки — он, а не канон
## (иначе подстройка «дёргалась» бы на каждую свою же дельту). hand -> Transform3D.
var _local_grip: Dictionary = {}
var _adjust_pending := false
var _adjust_accum := 0.0


func _ready() -> void:
	add_to_group("grab_manager")
	NetworkManager.register_replicated_schema(SCHEMA_ID,
			GrabStateSchema.definition(NetworkManager.DEFAULT_RANK))
	NetworkManager.replicated_state_received.connect(_on_replicated_state)
	NetworkManager.authority_changed.connect(_on_authority_changed)


func setup(player: Node3D, remote_view: Node) -> void:
	_player = player
	_remote_view = remote_view


# --- Реестр (Grabbable регистрируются сами при входе в дерево) ---

func register_grabbable(g: Grabbable) -> void:
	if g.grab_id == "":
		Log.warn("grab", "<VRWebGrabbable> без id — предмет не синхронизируется и не интерактивен")
		return
	var oid := OBJECT_PREFIX + g.grab_id
	if _grabbables.has(oid) and _grabbables[oid] != g and is_instance_valid(_grabbables[oid]):
		Log.warn("grab", "дубль id grabbable «%s» — второй экземпляр игнорируется" % g.grab_id)
		return
	_grabbables[oid] = g
	_register_state_object(oid, g)
	# Snapshot комнаты мог прийти раньше материализации узла — догоняем текущее состояние.
	if NetworkManager.replicated_revision(oid, SCHEMA_ID) > 0:
		var state := NetworkManager.replicated_state(oid, SCHEMA_ID)
		_apply_state(oid, state, state)


func unregister_grabbable(g: Grabbable) -> void:
	var oid := OBJECT_PREFIX + g.grab_id
	if _grabbables.get(oid) != g:
		return
	if _held.has(oid):
		_detach(oid, g)
	_grabbables.erase(oid)
	NetworkManager.unregister_replicated_object(oid, SCHEMA_ID)


func _register_state_object(oid: String, g: Grabbable) -> void:
	# Начальный rest — декларированная поза узла (детерминирована страницей, одинакова у всех
	# клиентов). Канон начинает действовать с первого snapshot/delta авторитета.
	NetworkManager.register_replicated_object(oid, SCHEMA_ID, {
		"rest": GrabStateSchema.pack_transform(g.transform),
		"theft": g.theft_allowed,
		"adjustable": g.adjustable,
	})


func _on_authority_changed(_authority: int, _is_me: bool) -> void:
	# reset_session при пересборке меша удаляет объекты Store, схемы живут — восстанавливаем
	# декларации; каноническое состояние приедет snapshot-ом (см. VrwebVideoManager, тот же приём).
	for oid in _grabbables:
		if is_instance_valid(_grabbables[oid]):
			_register_state_object(oid, _grabbables[oid])


# --- Применение канонических дельт ---

func _on_replicated_state(object_id: String, schema_id: String, state: Dictionary,
		changed: Dictionary, _revision: int) -> void:
	if schema_id != SCHEMA_ID:
		return
	_apply_state(object_id, state, changed)


func _apply_state(object_id: String, state: Dictionary, changed: Dictionary) -> void:
	var g: Grabbable = _grabbables.get(object_id)
	if g == null or not is_instance_valid(g):
		return
	var holder := str(state.get("holder_user_id", ""))
	var hand := str(state.get("hand", ""))
	var prev: Dictionary = _held.get(object_id, {})
	if holder == "":
		var was_held := not prev.is_empty()
		if was_held:
			_detach(object_id, g)
		if was_held or changed.has("rest"):
			g.apply_rest(state.get("rest"))
		return
	if not prev.is_empty() and str(prev["holder"]) == holder and str(prev["hand"]) == hand:
		_held[object_id]["grip"] = GrabStateSchema.unpack_transform(state.get("grip"))
		return
	if not prev.is_empty():
		_detach(object_id, g)   # перехват (theft): drop прежнему держателю, grab новому
	_held[object_id] = {
		"holder": holder, "hand": hand,
		"grip": GrabStateSchema.unpack_transform(state.get("grip")),
	}
	g.set_held(true)
	if holder == _my_user():
		_local_held[hand] = object_id
		_local_grip[hand] = _held[object_id]["grip"]
		_set_player_aim_exception(g, true)
		_set_player_holding(hand, true)
	g.grab.emit(holder, hand)


func _detach(object_id: String, g: Grabbable) -> void:
	var prev: Dictionary = _held.get(object_id, {})
	_held.erase(object_id)
	g.set_held(false)
	var holder := str(prev.get("holder", ""))
	var hand := str(prev.get("hand", ""))
	if holder == _my_user() and _local_held.get(hand) == object_id:
		_local_held.erase(hand)
		_local_grip.erase(hand)
		_set_player_aim_exception(g, false)
		_set_player_holding(hand, false)
	g.drop.emit(holder, hand)


# --- Локальные действия игрока ---

## Правила локального взаимодействия: свободный предмет берётся, свой — нет (он уже в руке),
## чужой — только при theft="allow".
func can_local_grab(g: Grabbable) -> bool:
	var info: Dictionary = _held.get(OBJECT_PREFIX + g.grab_id, {})
	if info.is_empty():
		return true
	return str(info["holder"]) != _my_user() and g.theft_allowed


func hint_for(g: Grabbable) -> String:
	var info: Dictionary = _held.get(OBJECT_PREFIX + g.grab_id, {})
	if info.is_empty():
		return "Взять"
	if str(info["holder"]) == _my_user():
		return ""
	return "Забрать" if g.theft_allowed else "Занято"


## Запрос захвата (десктоп v1 — всегда правая рука; hand в проводе с первого дня, VR будет
## слать фактическую руку и естественный хват). Без optimistic-применения: предмет ложится в
## руку каноническим delta (offline standalone коммитит немедленно).
##
## Хват зависит от режима (аналог VRChat Orientation):
##  - fixed (Orientation=Grip/ExactGrip) — авторский grip, предмет снапится в канонную позу;
##  - adjustable (Orientation=None) — фактическая поза в момент захвата, предмет НЕ прыгает;
##    дальше держатель подстраивает его сам (adjust_*).
func request_grab(g: Grabbable) -> void:
	if g.grab_id == "" or not can_local_grab(g) or _local_held.has(HAND_RIGHT):
		return
	var grip := g.grip_transform
	if g.adjustable:
		var anchor = _local_anchor(HAND_RIGHT)
		if anchor is Transform3D:
			# Хват берётся КАК ЕСТЬ, без клампа: предмет не должен дёрнуться в момент захвата.
			# Дальность и так ограничена лучом взаимодействия, а подстройка клампится отдельно.
			grip = (anchor as Transform3D).affine_inverse() * g.global_transform
	NetworkManager.request_replicated_command(OBJECT_PREFIX + g.grab_id, SCHEMA_ID, SCHEMA_VERSION,
			"grab", {"hand": HAND_RIGHT, "grip": GrabStateSchema.pack_transform(grip)})


func local_held() -> Grabbable:
	var oid = _local_held.get(HAND_RIGHT)
	if oid == null:
		return null
	var g: Grabbable = _grabbables.get(oid)
	return g if g != null and is_instance_valid(g) else null


## use — transient-событие только на клиенте держателя (норматив). Дальше автор страницы сам
## решает, что с ним делать (document.remote / document.state).
func use_held() -> void:
	var g := local_held()
	if g != null:
		g.use.emit(_my_user(), HAND_RIGHT)


## Положить держимый предмет РОВНО ТАМ, где он сейчас в руке: канон — его текущая мировая
## поза. Никакого переноса в точку прицела: предмет не должен «телепортироваться» из руки
## (так же ведёт себя drop в VRChat — дальше содержимое живёт своей физикой).
func release_held() -> void:
	var g := local_held()
	if g == null:
		return
	_commit_adjust(true)
	NetworkManager.request_replicated_command(OBJECT_PREFIX + g.grab_id, SCHEMA_ID, SCHEMA_VERSION,
			"release", {"rest": g.rest_pose_from_world(g.global_transform)})


# --- Подстройка хвата держателем (только adjustable) ---

## Держим ли сейчас предмет, который можно подстраивать (для роутинга ввода у игрока).
func holding_adjustable() -> bool:
	var g := local_held()
	return g != null and g.adjustable


## Колесо: отодвинуть (steps > 0) или придвинуть (steps < 0) предмет вдоль взгляда —
## та же семантика колеса, что у VRChat.
func adjust_distance(steps: float) -> void:
	if not holding_adjustable():
		return
	var grip: Transform3D = _local_grip.get(HAND_RIGHT, Transform3D.IDENTITY)
	# Якорь смотрит вдоль своего -Z, поэтому «дальше» — уменьшение z.
	grip.origin.z -= steps * DISTANCE_STEP
	grip.origin = _clamp_hold_offset(grip.origin,
			(_local_grip.get(HAND_RIGHT, Transform3D.IDENTITY) as Transform3D).origin.length())
	_set_local_grip(grip)


## Средняя кнопка + мышь: вращение предмета в слоте (yaw по горизонтали, pitch по вертикали).
## Оси берём в пространстве якоря, поэтому вращение экранно-относительное и предсказуемое.
## У VRChat это клавиши I/J/K/L/U/O — заметно менее удобно (их открытый feature request).
func adjust_rotation(motion: Vector2) -> void:
	if not holding_adjustable():
		return
	var grip: Transform3D = _local_grip.get(HAND_RIGHT, Transform3D.IDENTITY)
	var yaw := Basis(Vector3.UP, -motion.x * ROTATE_SENSITIVITY)
	var pitch := Basis(Vector3.RIGHT, -motion.y * ROTATE_SENSITIVITY)
	grip.basis = yaw * pitch * grip.basis
	_set_local_grip(grip)


## Колесо при зажатой средней кнопке: roll (третья ось) — без отдельных хоткеев.
func adjust_roll(steps: float) -> void:
	if not holding_adjustable():
		return
	var grip: Transform3D = _local_grip.get(HAND_RIGHT, Transform3D.IDENTITY)
	grip.basis = Basis(Vector3.FORWARD, steps * ROLL_STEP) * grip.basis
	_set_local_grip(grip)


## Локальный хват применяется сразу (картинка держателя), канон уходит throttled — остальные
## видят подстройку редкими дельтами, а не потоком.
func _set_local_grip(grip: Transform3D) -> void:
	_local_grip[HAND_RIGHT] = grip.orthonormalized()
	_adjust_pending = true


func _commit_adjust(force := false) -> void:
	if not _adjust_pending:
		return
	if not force and _adjust_accum < ADJUST_COMMIT_INTERVAL:
		return
	var g := local_held()
	if g == null or not g.adjustable:
		_adjust_pending = false
		return
	_adjust_accum = 0.0
	_adjust_pending = false
	NetworkManager.request_replicated_command(OBJECT_PREFIX + g.grab_id, SCHEMA_ID, SCHEMA_VERSION,
			"adjust", {"grip": GrabStateSchema.pack_transform(_local_grip.get(HAND_RIGHT,
					Transform3D.IDENTITY))})


## Кламп дистанции подстройки. Верхний предел «мягкий»: если предмет уже дальше MAX (взяли
## издали), мы не дёргаем его внутрь — просто не даём отодвинуть ещё дальше. Придвигать при
## этом можно всегда, и после захода под MAX начинает действовать обычный предел.
func _clamp_hold_offset(origin: Vector3, current_distance := MAX_HOLD_DISTANCE) -> Vector3:
	var distance := origin.length()
	if distance < 0.0001:
		return Vector3(0, 0, -MIN_HOLD_DISTANCE)
	var ceiling := maxf(MAX_HOLD_DISTANCE, current_distance)
	return origin * (clampf(distance, MIN_HOLD_DISTANCE, ceiling) / distance)


# --- Attachment-модель: следование за якорем руки ---

func _process(delta: float) -> void:
	for oid in _held.keys():
		var g: Grabbable = _grabbables.get(oid)
		if g == null or not is_instance_valid(g):
			continue
		var info: Dictionary = _held[oid]
		var hand := str(info["hand"])
		var holder := str(info["holder"])
		var anchor = _anchor_for(holder, hand)
		if anchor is Transform3D:
			# Свой предмет рисуем по локальному (оптимистичному) хвату — подстройка отзывается
			# мгновенно и не ждёт round-trip; чужие — строго по канону.
			var grip: Transform3D = info["grip"]
			if holder == _my_user() and _local_held.get(hand) == oid:
				grip = _local_grip.get(hand, grip)
			g.global_transform = anchor * grip
	_adjust_accum += delta
	_commit_adjust()
	_sweep_accum += delta
	if _sweep_accum >= SWEEP_INTERVAL:
		_sweep_accum = 0.0
		_authority_sweep()


## Якорь руки держателя (мировой Transform3D) или null, если держатель сейчас не материализован
## (капсула ещё не создана) — тогда предмет остаётся где был до следующего кадра.
func _anchor_for(holder: String, hand: String):
	if holder == _my_user():
		return _local_anchor(hand)
	var capsule: Node3D = null
	if _remote_view != null and is_instance_valid(_remote_view) \
			and _remote_view.has_method("capsule_for_user"):
		capsule = _remote_view.capsule_for_user(holder)
	if capsule == null or not is_instance_valid(capsule):
		return null
	var point := _attachment_point(capsule, "hand." + hand)
	if point != null:
		return point.global_transform
	var offset := FALLBACK_CAPSULE_OFFSET
	if hand == HAND_LEFT:
		offset.x = -offset.x
	return capsule.global_transform * Transform3D(Basis.IDENTITY, offset)


## Десктопный локальный якорь — «рука» под камерой первого лица.
func _local_anchor(hand: String):
	if _player == null or not is_instance_valid(_player):
		return null
	var camera := _player.get_node_or_null("Camera3D") as Node3D
	var base := camera.global_transform if camera != null else (_player as Node3D).global_transform
	var offset := LOCAL_HAND_OFFSET
	if hand == HAND_LEFT:
		offset.x = -offset.x
	return base * Transform3D(Basis.IDENTITY, offset)


## Объявленная аватаром точка крепления (AvatarAttachmentPoint с нужным именем) на капсуле.
## Неизвестное имя руки просто не найдёт точку и уйдёт в fallback — открытый enum по нормативу.
func _attachment_point(capsule: Node, point_name: String) -> Node3D:
	for child in capsule.find_children("*", "Node3D", true, false):
		if child is AvatarAttachmentPoint and (child as AvatarAttachmentPoint).point == point_name:
			return child
	return null


# --- Авто-release ушедшего держателя (обязанность авторитета, как TTL эфемерного слоя) ---

func _authority_sweep() -> void:
	if not NetworkManager.has_authority():
		return
	var present := {_my_user(): true}
	for pid in NetworkManager.peer_ids():
		var uid := NetworkManager.user_id_of(pid)
		if uid != "":
			present[uid] = true
	for oid in _held.keys():
		var info: Dictionary = _held[oid]
		if present.has(str(info["holder"])):
			continue
		var g: Grabbable = _grabbables.get(oid)
		if g == null or not is_instance_valid(g):
			continue
		# Предмет ложится там, где рука держателя была видна в последний раз.
		NetworkManager.request_replicated_command(oid, SCHEMA_ID, SCHEMA_VERSION,
				"release", {"rest": g.rest_pose_from_world(g.global_transform)})


# --- Мостики к игроку (утиные: в тестах игрок может быть заглушкой) ---

func _my_user() -> String:
	return Settings.user_id


func _set_player_aim_exception(g: Grabbable, on: bool) -> void:
	if _player != null and is_instance_valid(_player) and _player.has_method("set_aim_exception"):
		_player.set_aim_exception(g, on)


func _set_player_holding(hand: String, held: bool) -> void:
	if _player != null and is_instance_valid(_player) and _player.has_method("set_holding"):
		_player.set_holding(hand, held)
