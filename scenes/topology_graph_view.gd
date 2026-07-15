class_name TopologyGraphView
extends Control

## Визуализатор артефакта топологии (Dictionary из TopologyBuilder) как 2D-графа.
## Комнаты/соединители — узлы, связи родитель→ребёнок — рёбра. Раскладка «tidy tree»:
## глубина дерева -> ось Y, листья раскладываются по X, родитель центрируется над детьми.
## Поддерживает панорамирование (ЛКМ-драг), зум (колесо) и выбор узла (клик).
##
## Координат у топологии нет — это чисто отладочная проекция, чтобы глазами проверить
## результат контракции (см. docs/html-to-3d-topology.md, docs/implementation-phase1.md).

signal node_selected(room_id: int)

## Режимы раскладки: TREE — нисходящее «tidy tree» (глубина → Y);
## RADIAL — «паук»: корень в центре, глубина → радиус, поддеревья расходятся секторами.
enum Layout { TREE, RADIAL }

const NODE_W := 168.0
const NODE_H := 76.0
const X_SPACING := 196.0
const Y_SPACING := 132.0
const RING_SPACING := 260.0   # расстояние между кольцами уровней в радиальном режиме
const CLICK_THRESHOLD := 6.0

const COLOR_BG := Color(0.09, 0.10, 0.13)
const COLOR_ROOM := Color(0.20, 0.33, 0.50)
const COLOR_CONNECTOR := Color(0.52, 0.36, 0.16)
const COLOR_ROOM_ROOT := Color(0.24, 0.46, 0.40)
const COLOR_EDGE := Color(0.55, 0.60, 0.70, 0.85)
const COLOR_BORDER := Color(0.85, 0.88, 0.95)
const COLOR_SELECTED := Color(1.0, 0.85, 0.30)
const COLOR_TEXT := Color(0.93, 0.95, 1.0)
const COLOR_TEXT_DIM := Color(0.72, 0.76, 0.85)

var _space: Dictionary = {}
var _rooms: Dictionary = {}
var _root: int = -1
var _positions: Dictionary = {}   # roomId -> Vector2 (в graph-координатах, центр узла)
var _leaf_cursor: float = 0.0
var _layout: int = Layout.TREE

var _pan := Vector2(0, 0)
var _zoom := 1.0
var _dragging := false
var _press_pos := Vector2.ZERO
var _moved := false
var _selected: int = -1


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


## Принимает артефакт топологии и перестраивает граф, авто-подгоняя вид.
func set_space(space: Dictionary) -> void:
	_space = space
	_rooms = space.get("rooms", {})
	_root = space.get("root", -1)
	_selected = -1
	_compute_layout()
	fit_view()
	queue_redraw()


func clear() -> void:
	_space = {}
	_rooms = {}
	_root = -1
	_positions = {}
	_selected = -1
	queue_redraw()


## Переключает режим раскладки (Layout.TREE / Layout.RADIAL) и пересобирает граф.
func set_layout(mode: int) -> void:
	if mode == _layout:
		return
	_layout = mode
	_compute_layout()
	fit_view()
	queue_redraw()


func get_layout() -> int:
	return _layout


# --- Раскладка ---

func _compute_layout() -> void:
	_positions = {}
	_leaf_cursor = 0.0
	if _root == -1 or not _rooms.has(_root):
		return
	if _layout == Layout.RADIAL:
		var leaves := _count_leaves(_root, {})
		var step := TAU / maxf(leaves, 1.0)
		_assign_radial(_root, 0, step, {})
	else:
		_assign(_root, 0, {})


## Число листьев в поддереве — нужно, чтобы поделить полный круг на равные секторы.
func _count_leaves(id: int, visited: Dictionary) -> float:
	if visited.has(id) or not _rooms.has(id):
		return 1.0
	visited[id] = true
	var children: Array = _rooms[id].get("children", [])
	if children.is_empty():
		return 1.0
	var total := 0.0
	for c in children:
		total += _count_leaves(c, visited)
	return total


## Радиальная раскладка: глубина → радиус (кольца), листья равномерно по углу,
## внутренний узел берёт средний угол детей. Возвращает угол узла (радианы).
func _assign_radial(id: int, depth: int, step: float, visited: Dictionary) -> float:
	if visited.has(id) or not _rooms.has(id):
		var a := _leaf_cursor * step
		_leaf_cursor += 1.0
		return a
	visited[id] = true
	var children: Array = _rooms[id].get("children", [])
	var angle: float
	if children.is_empty():
		angle = _leaf_cursor * step
		_leaf_cursor += 1.0
	else:
		var first := 0.0
		var last := 0.0
		for i in children.size():
			var ca := _assign_radial(children[i], depth + 1, step, visited)
			if i == 0:
				first = ca
			last = ca
		angle = (first + last) * 0.5
	var radius := depth * RING_SPACING
	_positions[id] = Vector2(cos(angle), sin(angle)) * radius
	return angle


## Рекурсивно назначает graph-координаты. Листья занимают последовательные слоты по X,
## внутренний узел центрируется над детьми. Возвращает X-координату узла.
func _assign(id: int, depth: int, visited: Dictionary) -> float:
	if visited.has(id) or not _rooms.has(id):
		# Защита от циклов/висячих ссылок: топология — дерево, но не доверяем слепо.
		var fx := _leaf_cursor * X_SPACING
		_leaf_cursor += 1.0
		return fx
	visited[id] = true
	var children: Array = _rooms[id].get("children", [])
	if children.is_empty():
		var x := _leaf_cursor * X_SPACING
		_leaf_cursor += 1.0
		_positions[id] = Vector2(x, depth * Y_SPACING)
		return x

	var first := 0.0
	var last := 0.0
	for i in children.size():
		var cx := _assign(children[i], depth + 1, visited)
		if i == 0:
			first = cx
		last = cx
	var center := (first + last) * 0.5
	_positions[id] = Vector2(center, depth * Y_SPACING)
	return center


## Подгоняет pan/zoom так, чтобы весь граф поместился с полями.
func fit_view() -> void:
	if _positions.is_empty():
		_pan = size * 0.5
		_zoom = 1.0
		return
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for id in _positions:
		var p: Vector2 = _positions[id]
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	min_p -= Vector2(NODE_W, NODE_H)
	max_p += Vector2(NODE_W, NODE_H)
	var graph_size := max_p - min_p
	var pad := 40.0
	var avail := size - Vector2(pad, pad) * 2.0
	var zx := avail.x / maxf(graph_size.x, 1.0)
	var zy := avail.y / maxf(graph_size.y, 1.0)
	_zoom = clampf(minf(zx, zy), 0.1, 1.5)
	var graph_center := (min_p + max_p) * 0.5
	_pan = size * 0.5 - graph_center * _zoom
	queue_redraw()


func _graph_to_screen(p: Vector2) -> Vector2:
	return p * _zoom + _pan


func _screen_to_graph(p: Vector2) -> Vector2:
	return (p - _pan) / _zoom


# --- Отрисовка ---

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	if _positions.is_empty():
		var empty_state_font := get_theme_default_font()
		draw_string(empty_state_font, Vector2(24, 36), "Граф пуст — загрузите страницу",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, COLOR_TEXT_DIM)
		return

	# Рёбра под узлами. В дереве соединяем низ родителя с верхом ребёнка,
	# в «пауке» — центры (линии радиально расходятся из корня).
	var radial := _layout == Layout.RADIAL
	for id in _positions:
		var children: Array = _rooms[id].get("children", [])
		var from := _graph_to_screen(_positions[id] + (Vector2.ZERO if radial else Vector2(0, NODE_H * 0.5)))
		for c in children:
			if not _positions.has(c):
				continue
			var to := _graph_to_screen(_positions[c] - (Vector2.ZERO if radial else Vector2(0, NODE_H * 0.5)))
			draw_line(from, to, COLOR_EDGE, maxf(1.5 * _zoom, 1.0), true)

	# Узлы поверх рёбер.
	var node_font := get_theme_default_font()
	for id in _positions:
		_draw_node(id, node_font)


func _draw_node(id: int, font: Font) -> void:
	var room: Dictionary = _rooms[id]
	var kind: String = room.get("kind", "room")
	var hints: Dictionary = room.get("hints", {})
	var center := _graph_to_screen(_positions[id])
	var w := NODE_W * _zoom
	var h := NODE_H * _zoom
	var rect := Rect2(center - Vector2(w, h) * 0.5, Vector2(w, h))

	var fill := COLOR_CONNECTOR if kind == "connector" else COLOR_ROOM
	if kind != "connector" and id == _root:
		fill = COLOR_ROOM_ROOT
	draw_rect(rect, fill)
	var border := COLOR_SELECTED if id == _selected else COLOR_BORDER
	var bw := 3.0 if id == _selected else 1.5
	draw_rect(rect, border, false, bw)

	# Текст рисуем только если узел достаточно крупный, иначе мешанина.
	if _zoom < 0.45:
		return
	var fs := int(clampf(13.0 * _zoom, 9.0, 14.0))
	var pad := 7.0 * _zoom
	var tx := rect.position.x + pad
	var ty := rect.position.y + pad + fs
	var line_h := fs + 3.0

	var sem: String = hints.get("semanticTag", "")
	var title := "#%d %s" % [id, kind]
	if sem != "":
		title += "  <%s>" % sem
	draw_string(font, Vector2(tx, ty), title, HORIZONTAL_ALIGNMENT_LEFT,
		w - pad * 2, fs, COLOR_TEXT)

	var objects: Array = room.get("objects", [])
	var children: Array = room.get("children", [])
	var line2 := "w=%d  obj=%d  ch=%d" % [hints.get("weight", 0), objects.size(), children.size()]
	draw_string(font, Vector2(tx, ty + line_h), line2, HORIZONTAL_ALIGNMENT_LEFT,
		w - pad * 2, fs - 1, COLOR_TEXT_DIM)

	# Третья строка — краткая сводка типов объектов.
	if not objects.is_empty():
		var summary := _objects_summary(objects)
		draw_string(font, Vector2(tx, ty + line_h * 2.0), summary, HORIZONTAL_ALIGNMENT_LEFT,
			w - pad * 2, fs - 1, COLOR_TEXT_DIM)


func _objects_summary(objects: Array) -> String:
	var counts := {}
	for o in objects:
		var t: String = o.get("type", "?")
		if o.get("function", null) != null:
			t += "→"
		counts[t] = int(counts.get(t, 0)) + 1
	var parts: Array = []
	for t in counts:
		parts.append("%s×%d" % [t, counts[t]] if counts[t] > 1 else str(t))
	return ", ".join(parts)


# --- Взаимодействие ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.is_action_pressed("view_zoom_in"):
			_zoom_at(mb.position, 1.12)
			accept_event()
		elif mb.is_action_pressed("view_zoom_out"):
			_zoom_at(mb.position, 1.0 / 1.12)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_moved = false
				_press_pos = mb.position
			else:
				_dragging = false
				if not _moved:
					_handle_click(mb.position)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_press_pos) > CLICK_THRESHOLD:
			_moved = true
		_pan += mm.relative
		queue_redraw()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := _screen_to_graph(screen_pos)
	_zoom = clampf(_zoom * factor, 0.1, 3.0)
	var after := _screen_to_graph(screen_pos)
	_pan += (after - before) * _zoom
	queue_redraw()


## Зум относительно центра вида (для кнопок/клавиш).
func zoom_by(factor: float) -> void:
	_zoom_at(size * 0.5, factor)


func get_zoom() -> float:
	return _zoom


func _handle_click(screen_pos: Vector2) -> void:
	var hit := -1
	for id in _positions:
		var center := _graph_to_screen(_positions[id])
		var half := Vector2(NODE_W, NODE_H) * 0.5 * _zoom
		var rect := Rect2(center - half, half * 2.0)
		if rect.has_point(screen_pos):
			hit = id
			break
	_selected = hit
	queue_redraw()
	if hit != -1:
		node_selected.emit(hit)
