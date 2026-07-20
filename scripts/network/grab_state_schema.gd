class_name GrabStateSchema
extends RefCounted

## Нормативная машина hold-состояния grabbable-предметов (schema "vrweb.grabbable.hold").
## Канон: КТО держит объект (holder_user_id), КАКОЙ рукой (hand), с каким хватом (grip)
## и где объект покоится, когда свободен (rest). Мировая поза держимого предмета — производная
## презентация (якорь руки × grip), в канон не входит и по сети не гоняется.
## Контракт и таблица переходов — docs/space/grabbable.md; клиентская часть — docs/client/grabbable.md.

const ID := "vrweb.grabbable.hold"
const VERSION := 1

## Поза = [px,py,pz, qx,qy,qz,qw] (метры; кватернион в порядке x,y,z,w). Оси — конвенция
## VRWML (правая тройка, Y вверх), см. docs/space/grabbable.md#wire-конвенции.
const POSE_IDENTITY: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
const MAX_HAND_BYTES := 32
const MAX_USER_BYTES := 128
const MAX_POSE_ABS := 100000.0


static func definition(default_rank: int) -> Dictionary:
	return {
		"version": VERSION,
		"fields": {
			"holder_user_id": {"type": "string", "default": "", "max_bytes": MAX_USER_BYTES},
			"hand": {"type": "string", "default": "", "max_bytes": MAX_HAND_BYTES},
			"grip": {"type": "array", "default": POSE_IDENTITY.duplicate(),
				"max_items": 7, "items": {"type": "float", "default": 0.0}},
			"rest": {"type": "array", "default": POSE_IDENTITY.duplicate(),
				"max_items": 7, "items": {"type": "float", "default": 0.0}},
			# Политика кражи фиксируется при регистрации объекта (из атрибута тега) и командами
			# не меняется — у схемы намеренно нет команды-сеттера.
			"theft": {"type": "bool", "default": true},
			# Режим удержания (атрибут mode): false — fixed (снап в авторский хват),
			# true — adjustable (естественный хват + подстройка держателем). Тоже фиксируется
			# при регистрации: reducer обязан валидировать adjust, даже если узел ещё не построен.
			"adjustable": {"type": "bool", "default": false},
		},
		"default_write_rule": {"any_of": [
			"authority",
			{"rank": {"op": "lte", "value": default_rank}},
		]},
		"commands": {
			"grab": {"reducer": GrabStateSchema.reduce_grab},
			"release": {"reducer": GrabStateSchema.reduce_release},
			"adjust": {"reducer": GrabStateSchema.reduce_adjust},
		},
	}


## grab(hand, grip): взять свободный предмет или перехватить чужой (если theft разрешён).
## Аноним (пустой user_id) держать не может: holder == "" означает «свободен».
static func reduce_grab(state: Dictionary, args: Dictionary, context: Dictionary) -> Dictionary:
	var user_id := str(context.get("user_id", ""))
	if user_id == "" or user_id.to_utf8_buffer().size() > MAX_USER_BYTES:
		return {}
	var hand := str(args.get("hand", ""))
	if hand == "" or hand.to_utf8_buffer().size() > MAX_HAND_BYTES:
		return {}
	if not valid_pose(args.get("grip")):
		return {}
	var holder := str(state.get("holder_user_id", ""))
	if holder != "" and holder != user_id and not bool(state.get("theft", true)):
		return {}
	return {"holder_user_id": user_id, "hand": hand, "grip": normalized_pose(args["grip"])}


## adjust(grip): держатель подстраивает хват (дистанция/поворот в слоте). Разрешено только
## владельцу текущего удержания и только для adjustable-предметов — у fixed хват задан автором.
static func reduce_adjust(state: Dictionary, args: Dictionary, context: Dictionary) -> Dictionary:
	if not bool(state.get("adjustable", false)):
		return {}
	var holder := str(state.get("holder_user_id", ""))
	if holder == "" or holder != str(context.get("user_id", "")):
		return {}
	if not valid_pose(args.get("grip")):
		return {}
	return {"grip": normalized_pose(args["grip"])}


## release(rest): положить предмет. Разрешено держателю; авторитет может освобождать
## принудительно (авто-release ушедшего держателя, модерация).
static func reduce_release(state: Dictionary, args: Dictionary, context: Dictionary) -> Dictionary:
	var holder := str(state.get("holder_user_id", ""))
	if holder == "":
		return {}
	var user_id := str(context.get("user_id", ""))
	if user_id != holder and not bool(context.get("is_authority", false)):
		return {}
	if not valid_pose(args.get("rest")):
		return {}
	return {"holder_user_id": "", "hand": "", "rest": normalized_pose(args["rest"])}


## Поза валидна: ровно 7 конечных чисел в разумных пределах, кватернион не вырожден.
static func valid_pose(value) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 7:
		return false
	for item in value:
		if typeof(item) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(item)) \
				or absf(float(item)) > MAX_POSE_ABS:
			return false
	var q := Vector4(float(value[3]), float(value[4]), float(value[5]), float(value[6]))
	return q.length() > 0.1


## Канонизация перед записью в состояние: числа во float, кватернион нормирован.
static func normalized_pose(value: Array) -> Array:
	var q := Quaternion(float(value[3]), float(value[4]), float(value[5]), float(value[6])).normalized()
	return [float(value[0]), float(value[1]), float(value[2]), q.x, q.y, q.z, q.w]


static func pack_transform(t: Transform3D) -> Array:
	var q := t.basis.get_rotation_quaternion()
	return [t.origin.x, t.origin.y, t.origin.z, q.x, q.y, q.z, q.w]


## Масштаб в позу не входит (объект сохраняет собственный scale) — см. норматив.
static func unpack_transform(pose) -> Transform3D:
	if not valid_pose(pose):
		return Transform3D.IDENTITY
	var q := Quaternion(float(pose[3]), float(pose[4]), float(pose[5]), float(pose[6])).normalized()
	return Transform3D(Basis(q), Vector3(float(pose[0]), float(pose[1]), float(pose[2])))
