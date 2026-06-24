class_name GeometryTopView
extends Control

## Вид сверху на раскладку из SpaceLayout. Рисует комнаты на сетке: футпринт-клетки
## (пентамино — каждая деталь своим оттенком), описывающий прямоугольник, подпись с id и
## потребностью, и дорожки между непримкнувшими комнатами. Панорама (ЛКМ-драг), зум (колесо),
## выбор комнаты (клик).
##
## Чисто отладочная проекция той же раскладки, что строит реальное 3D-пространство
## (см. docs/geometry-lab.md): 3D-геометрию из неё собирает world_generator.gd.

signal room_selected(room_id: int)

const CELL := 24.0            # размер клетки сетки, px (в graph-координатах)
const CLICK_THRESHOLD := 6.0

const COLOR_BG := Color(0.09, 0.10, 0.13)
const COLOR_GRID := Color(1, 1, 1, 0.05)
const COLOR_CELL_BORDER := Color(0, 0, 0, 0.35)
const COLOR_BBOX := Color(1, 1, 1, 0.25)
const COLOR_BBOX_SEL := Color(1.0, 0.85, 0.30)
const COLOR_CORRIDOR := Color(1.0, 0.23, 0.74)        # ярко-розовый путь, виден поверх комнат
const COLOR_CORRIDOR_FAR := Color(1.0, 0.55, 0.1)     # оранжевый — связь, которая не примкнула (запасной путь)
const COLOR_UNROUTED := Color(1.0, 0.15, 0.15)        # красный — связь без прохода (маршрут не найден)
const COLOR_ROUTE := Color(0.25, 0.95, 0.35)          # зелёный — внутренний маршрут движения сквозь комнату
const COLOR_TEXT := Color(0.95, 0.97, 1.0)
const COLOR_TEXT_DIM := Color(0.72, 0.76, 0.85)

var _layout: Dictionary = {}
var _rooms: Dictionary = {}
var _root: int = -1
var _selected: int = -1

var _pan := Vector2.ZERO
var _zoom := 1.0
var _dragging := false
var _press_pos := Vector2.ZERO
var _moved := false


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


## Принимает раскладку из SpaceLayout.build и перерисовывает, вписывая в вид.
func set_layout(layout: Dictionary) -> void:
	_layout = layout
	_rooms = layout.get("rooms", {})
	_root = layout.get("root", -1)
	_selected = -1
	fit_view()
	queue_redraw()


func clear() -> void:
	_layout = {}
	_rooms = {}
	_root = -1
	_selected = -1
	queue_redraw()


# --- Преобразования координат (клетки -> экран) ---

func _cell_to_screen(cell: Vector2) -> Vector2:
	return cell * CELL * _zoom + _pan


func _screen_to_cell(p: Vector2) -> Vector2:
	return (p - _pan) / (CELL * _zoom)


func fit_view() -> void:
	if _rooms.is_empty():
		_pan = size * 0.5
		_zoom = 1.0
		return
	var min_c := Vector2(INF, INF)
	var max_c := Vector2(-INF, -INF)
	for id in _rooms:
		var rd: Dictionary = _rooms[id]
		var base := Vector2(rd.get("pos", Vector2i.ZERO))
		var dims := Vector2(rd.get("dims", Vector2i.ONE))
		min_c = min_c.min(base)
		max_c = max_c.max(base + dims)
	var span := (max_c - min_c) * CELL
	var pad := 48.0
	var avail := size - Vector2(pad, pad) * 2.0
	var zx := avail.x / maxf(span.x, 1.0)
	var zy := avail.y / maxf(span.y, 1.0)
	_zoom = clampf(minf(zx, zy), 0.1, 2.0)
	var center := (min_c + max_c) * 0.5 * CELL
	_pan = size * 0.5 - center * _zoom
	queue_redraw()


# --- Отрисовка ---

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	if _rooms.is_empty():
		var font := get_theme_default_font()
		draw_string(font, Vector2(24, 36), "Пусто — загрузите страницу",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, COLOR_TEXT_DIM)
		return

	_draw_grid()

	# Комнаты: футпринт-клетки + описывающий прямоугольник.
	for id in _rooms:
		_draw_room(id)

	_draw_routes()
	_draw_corridors()

	# Подписи поверх всего.
	var font := get_theme_default_font()
	for id in _rooms:
		_draw_label(id, font)


func _draw_grid() -> void:
	# Лёгкая сетка только при достаточном зуме, иначе каша.
	var step := CELL * _zoom
	if step < 8.0:
		return
	var origin := _cell_to_screen(Vector2.ZERO)
	var start_x := fmod(origin.x, step)
	var start_y := fmod(origin.y, step)
	var x := start_x
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), COLOR_GRID, 1.0)
		x += step
	var y := start_y
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), COLOR_GRID, 1.0)
		y += step


func _draw_room(id: int) -> void:
	var rd: Dictionary = _rooms[id]
	var base := Vector2(rd.get("pos", Vector2i.ZERO))
	var pieces: Array = rd.get("pieces", [])
	var room_color := _room_color(id)

	for pi in pieces.size():
		# Детали внутри комнаты слегка разной яркости — чтобы пентамино различались.
		var shade := room_color
		if pieces.size() > 1:
			shade = room_color.lightened(0.12 * (pi % 3)) if pi % 2 == 0 else room_color.darkened(0.12 * (pi % 3))
		for c in pieces[pi]:
			_draw_cell(base + Vector2(c), shade)

	# Описывающий прямоугольник.
	var dims := Vector2(rd.get("dims", Vector2i.ONE))
	var tl := _cell_to_screen(base)
	var br := _cell_to_screen(base + dims)
	var rect := Rect2(tl, br - tl)
	var is_sel := id == _selected
	draw_rect(rect, COLOR_BBOX_SEL if is_sel else COLOR_BBOX, false, 3.0 if is_sel else 1.5)


func _draw_cell(cell: Vector2, color: Color) -> void:
	var tl := _cell_to_screen(cell)
	var s := CELL * _zoom
	var rect := Rect2(tl, Vector2(s, s))
	draw_rect(rect, color)
	if s >= 6.0:
		draw_rect(rect, COLOR_CELL_BORDER, false, 1.0)


## Внутренние маршруты движения сквозь комнаты (зелёным), по центрам клеток. У проходной комнаты
## это N путей — из входа к каждому ребёнку; у листа — один путь-петля вход→вход. Разные пути одной
## комнаты могут пересекаться между собой; каждый сам с собой — нет (см. SpaceLayout._compute_routes).
func _draw_routes() -> void:
	var w := maxf(2.0 * _zoom, 1.5)
	for id in _rooms:
		for route in _rooms[id].get("routes", []):
			if route.size() < 2:
				continue
			var pts := PackedVector2Array()
			for c in route:
				pts.append(_cell_center(c))
			draw_polyline(pts, COLOR_ROUTE, w, true)
			draw_circle(pts[0], w * 1.2, COLOR_ROUTE)   # старт маршрута (вход)


## Пути связей родитель→ребёнок по ЦЕНТРАМ клеток, в обход комнат (см. SpaceLayout._route_corridor).
## Розовый — дверь/коридор примкнувшей связи; оранжевый — запасной коридор; красные кольца —
## связь без прохода (родитель замурован): крестом, без линии, чтобы НЕ рисовать пересечение.
func _draw_corridors() -> void:
	var w := maxf(3.0 * _zoom, 2.0)
	for corr in _layout.get("corridors", []):
		if corr.get("unrouted", false):
			_draw_unrouted(corr, w)
			continue
		var path: Array = corr.get("path", [])
		var color: Color = COLOR_CORRIDOR if corr.get("adjacent", true) else COLOR_CORRIDOR_FAR
		if path.is_empty():
			continue
		if path.size() == 1:
			draw_circle(_cell_center(path[0]), w, color)
			continue
		var pts := PackedVector2Array()
		for c in path:
			pts.append(_cell_center(c))
		draw_polyline(pts, color, w, true)
		draw_circle(pts[0], w * 0.9, color)
		draw_circle(pts[pts.size() - 1], w * 0.9, color)


## Связь без маршрута: помечаем красными кольцами центры обеих комнат (без соединяющей линии).
func _draw_unrouted(corr: Dictionary, w: float) -> void:
	for key in ["from", "to"]:
		var id = corr.get(key, -1)
		if not _rooms.has(id):
			continue
		var rd: Dictionary = _rooms[id]
		var center := _cell_to_screen(Vector2(rd.get("pos", Vector2i.ZERO)) + Vector2(rd.get("dims", Vector2i.ONE)) * 0.5)
		draw_arc(center, w * 2.2, 0, TAU, 20, COLOR_UNROUTED, w * 0.8)


func _cell_center(cell: Vector2i) -> Vector2:
	return _cell_to_screen(Vector2(cell) + Vector2(0.5, 0.5))


func _draw_label(id: int, font: Font) -> void:
	if _zoom < 0.35:
		return
	var rd: Dictionary = _rooms[id]
	var base := Vector2(rd.get("pos", Vector2i.ZERO))
	var pos := _cell_to_screen(base) + Vector2(4, 16) * _zoom
	var fs := int(clampf(13.0 * _zoom, 9.0, 15.0))
	var kind: String = rd.get("kind", "room")
	var mark := "C" if kind == "connector" else ("R*" if id == _root else "R")
	var line := "#%d %s n=%d %s" % [id, mark, rd.get("need", 0), rd.get("shape_kind", "")]
	draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COLOR_TEXT)


## Цвет комнаты по id (детерминированный оттенок); соединители — холоднее/темнее.
func _room_color(id: int) -> Color:
	var hue := fmod(float(id) * 0.1037 + 0.11, 1.0)
	var rd: Dictionary = _rooms.get(id, {})
	if rd.get("kind", "room") == "connector":
		return Color.from_hsv(0.58, 0.20, 0.45)
	return Color.from_hsv(hue, 0.45, 0.62)


# --- Взаимодействие (панорама/зум/клик) ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.12)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
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
	var before := _screen_to_cell(screen_pos)
	_zoom = clampf(_zoom * factor, 0.05, 4.0)
	var after := _screen_to_cell(screen_pos)
	_pan += (after - before) * CELL * _zoom
	queue_redraw()


func zoom_by(factor: float) -> void:
	_zoom_at(size * 0.5, factor)


func _handle_click(screen_pos: Vector2) -> void:
	var cell := _screen_to_cell(screen_pos)
	var hit := -1
	for id in _rooms:
		var rd: Dictionary = _rooms[id]
		var rect := Rect2(Vector2(rd.get("pos", Vector2i.ZERO)), Vector2(rd.get("dims", Vector2i.ONE)))
		if rect.has_point(cell):
			hit = id
			break
	_selected = hit
	queue_redraw()
	if hit != -1:
		room_selected.emit(hit)
