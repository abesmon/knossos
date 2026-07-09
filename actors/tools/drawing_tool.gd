class_name DrawingTool
extends PlayerTool

## Инструмент рисования: «вложенный» инструмент с внутренним циклом режимов
## НЕТ → КАРАНДАШ → ЛАСТИК → НЕТ (каждый запрос активации — шаг цикла). Держит визуал «в руке»
## и логику ведения; артефакт — штрих (kind="stroke", актор StrokeActor).
##
## Данные и сеть — в эфемерном слое: рисование строит StrokePath, при отпускании ЛКМ один op=add
## уходит в NetworkManager (финализация при отпускании). Материализация — StrokeActor.
## Полное описание — docs/client/pencil-tool.md, система инструментов — docs/client/tools.md.

enum Mode { NONE, PENCIL, ERASER }

const STROKE := preload("res://actors/stroke/stroke.tscn")

## Вынос рабочего конца (остриё карандаша / торец ластика) вперёд от кисти, вдоль -Z (м). Точка
## рисования/стирания берётся ИЗ маркера-остриё — визуал и логика совмещены по построению.
const TIP_REACH := 0.45
## Радиус «ластика» (м): штрих стирается, если его линия ближе этого к острию ластика.
const ERASER_RADIUS := 0.1
const STROKE_WIDTH := 0.02
## Запасная дальность рисования (м), если маркер-остриё почему-то недоступен.
const DRAW_DIST := 1.0

var _mode: int = Mode.NONE
var _tip: Node3D                        # маркер рабочего конца — отсюда фактически рисуем/стираем

var _drawing := false
var _path: StrokePath
var _preview: StrokeActor

var _erasing := false
# Превью своих штрихов, отправленных в сеть и ждущих канонический узел от вьюхи: id -> preview-узел.
# Держим до прихода scene_object_added (наш id), чтобы не мигало в зазоре одной RTT.
var _pending: Dictionary = {}


func setup(camera: Camera3D, world_root: Node3D, player: Player) -> void:
	super(camera, world_root, player)
	if not NetworkManager.scene_object_added.is_connected(_on_scene_object_added):
		NetworkManager.scene_object_added.connect(_on_scene_object_added)


func _exit_tree() -> void:
	if NetworkManager.scene_object_added.is_connected(_on_scene_object_added):
		NetworkManager.scene_object_added.disconnect(_on_scene_object_added)


func tool_id() -> StringName:
	return &"drawing"


## Шаг внутреннего цикла режимов. Прерывает незавершённый штрих. Возврат false (режим НЕТ) —
## менеджер уберёт инструмент.
func activation_request() -> bool:
	_cancel_draw()
	_erasing = false
	_mode = (_mode + 1) % 3
	if _equipped:
		_refresh_held_visual()   # смена режима на уже экипированном инструменте — обновить меш
	hint_changed.emit(_hint_for_mode())
	return _mode != Mode.NONE


## Деактивация менеджером (чужой хоткей / конец цикла): полный сброс до режима НЕТ.
func _on_unequip() -> void:
	_cancel_draw()
	_erasing = false
	_mode = Mode.NONE
	_tip = null


## Потеря захвата мыши (Esc/потеря фокуса): прервать незавершённый штрих, инструмент остаётся в руке.
func on_mouse_capture_changed(captured: bool) -> void:
	if not captured:
		_cancel_draw()
		_erasing = false


func descriptor() -> Dictionary:
	match _mode:
		Mode.PENCIL:
			var c := _stroke_color()
			return {"kind": "tool-pencil", "props": {"color": [c.r, c.g, c.b], "width": STROKE_WIDTH}}
		Mode.ERASER:
			return {"kind": "tool-eraser", "props": {"radius": ERASER_RADIUS}}
	return {"kind": "", "props": {}}


func _hint_for_mode() -> String:
	match _mode:
		Mode.PENCIL:
			return "Инструмент: карандаш — зажмите ЛКМ, чтобы рисовать"
		Mode.ERASER:
			return "Инструмент: ластик — зажмите ЛКМ, чтобы стирать"
	return "Инструмент убран — ЛКМ снова взаимодействует с порталами"


# --- Основное действие (ЛКМ) ---

func primary_pressed() -> void:
	match _mode:
		Mode.PENCIL:
			_begin_stroke()
		Mode.ERASER:
			_erasing = true
			_erase_at(_draw_point())   # стереть сразу под прицелом, не дожидаясь движения


func primary_released() -> void:
	if _mode == Mode.PENCIL and _drawing:
		_finish_stroke()
	_erasing = false


func _physics_process(_delta: float) -> void:
	if _cam == null:
		return
	if _drawing:
		if _path.add_sample(_draw_point()):
			if _preview != null:
				_preview.append_point(_path.last_point())
	elif _erasing:
		_erase_at(_draw_point())


# --- Карандаш ---

func _begin_stroke() -> void:
	_path = StrokePath.new()
	_drawing = true
	_preview = STROKE.instantiate()
	_world.add_child(_preview)
	_preview.begin_preview(_stroke_color(), STROKE_WIDTH)
	# Первая точка сразу — чтобы клик без движения дал хотя бы старт линии.
	if _path.add_sample(_draw_point()):
		_preview.append_point(_path.last_point())


func _finish_stroke() -> void:
	_drawing = false
	_path.simplify()
	if not _path.is_drawable():
		_cancel_draw()
		return
	var props := _path.build_props(_stroke_color(), STROKE_WIDTH)
	if NetworkManager.in_room():
		# В комнате — канонический путь: один op=add, превью держим до прихода узла от вьюхи.
		var id := NetworkManager.new_object_id()
		_pending[id] = _preview
		NetworkManager.request_scene_action({
			"op": "add", "id": id, "kind": "stroke", "parent": "", "ttl": 0.0, "props": props,
		})
		_preview = null
	else:
		# Офлайн — оставляем превью постоянным локальным штрихом (упрощённый меш + автор для ластика).
		_preview.setup_object({"id": "", "author": Settings.user_id, "props": props})
		_preview = null
	_path = null


## Прервать незавершённый штрих (смена инструмента / пустой штрих): снять превью.
func _cancel_draw() -> void:
	_drawing = false
	_path = null
	if is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null


## Канонический узел штриха пришёл от вьюхи — снимаем соответствующее превью (зазор одной RTT закрыт).
func _on_scene_object_added(id: String, _object: Dictionary) -> void:
	var prev = _pending.get(id)
	if prev != null:
		if is_instance_valid(prev):
			prev.queue_free()
		_pending.erase(id)


# --- Ластик ---

## Стереть свои штрихи под точкой p. Сетевые — через op=remove (авторитет снимет), локальные — сразу.
func _erase_at(p: Vector3) -> void:
	for node in get_tree().get_nodes_in_group(StrokeActor.GROUP):
		var s := node as StrokeActor
		if s == null or s == _preview:
			continue
		if s.author != "" and s.author != Settings.user_id:
			continue   # чужой штрих — править нельзя (авторитет всё равно отклонит)
		if not s.hit_by(p, ERASER_RADIUS):
			continue
		if s.object_id != "":
			NetworkManager.request_scene_action({"op": "remove", "id": s.object_id})
		else:
			s.queue_free()   # локальный офлайн-штрих — снимаем напрямую


# --- Визуал «в руке» ---

## Процедурный визуал инструмента (placeholder). Кладём в контейнер-«кисть»; рабочий конец выносим
## вперёд на TIP_REACH и помечаем маркером _tip — ИЗ него берётся точка рисования/стирания
## (_draw_point), поэтому остриё визуала и фактический источник линии совмещены по построению.
## Меш ориентируем сами (цилиндр Godot стоит вдоль +Y, ластик — куб), маркер — вдоль -Z.
func make_held_node() -> Node3D:
	_tip = null
	if _mode == Mode.NONE:
		return null
	var holder := Node3D.new()
	var tip := Node3D.new()
	tip.position = Vector3(0, 0, -TIP_REACH)   # рабочий конец прямо перед кистью
	holder.add_child(tip)
	_tip = tip

	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if _mode == Mode.PENCIL:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.003      # верх (+Y → после поворота -Z) — остриё
		cyl.bottom_radius = 0.012
		cyl.height = TIP_REACH      # тянется от кисти до остриё
		mi.mesh = cyl
		mi.rotation = Vector3(deg_to_rad(-90), 0, 0)   # +Y → -Z: тонкий конец вперёд, к маркеру
		mi.position = Vector3(0, 0, -TIP_REACH * 0.5)  # центр между кистью и остриём
		mat.albedo_color = _stroke_color()
	else:
		var box := BoxMesh.new()
		box.size = Vector3(0.06, 0.045, 0.11)
		mi.mesh = box
		mi.position = Vector3(0, 0, -TIP_REACH + box.size.z * 0.5)  # торец у маркера
		mat.albedo_color = Color(0.95, 0.7, 0.75)
	mi.material_override = mat
	holder.add_child(mi)
	return holder


# --- Цвет штриха: стабильный оттенок по user_id (у каждого свой) ---

func _stroke_color() -> Color:
	var h := float(absi(hash(Settings.user_id)) % 360) / 360.0
	return Color.from_hsv(h, 0.65, 1.0)


## Точка, откуда фактически исходит рисование/стирание — мировая позиция маркера-остриё
## инструмента (визуал и логика совмещены). Запасной вариант — точка перед камерой.
func _draw_point() -> Vector3:
	if is_instance_valid(_tip):
		return _tip.global_position
	return _cam.global_position - _cam.global_transform.basis.z * DRAW_DIST
