class_name WorldGenerator
extends RefCounted

## Фаза геометрии (F) из docs/html-to-3d-topology.md. Потребляет ТОЛЬКО артефакт
## топологии (Dictionary) + seed и сочиняет конкретное навигируемое пространство.
##
## Раскладка v3 — «кварталы на сетке». Вся геометрия живёт в целочисленных клетках сетки
## GRID, поэтому КАЖДАЯ стена ложится на линию сетки (единое выравнивание). Поддеревья
## пакуются прямоугольниками с «улицами»-зазорами между блоками (кластеризация + компактность);
## коридоры маршрутизируются ортогонально по улицам, не заходя в комнаты и не пересекаясь.
##
## Фазы:
##   1. замер объектов     -> футпринт каждой настенной панели (_object_size)
##   2. размер комнаты      -> сторона под объекты, снапнутая к клеткам (_room_cells/_room_size)
##   3. упаковка блоками     -> комнаты на единой сетке, кластерами (_room_cell, _positions)
##   4. роутинг коридоров    -> ортогональные пути по улицам, проёмы в стенах (_room_openings)
##   5. геометрия            -> полы/стены-с-проёмами/объекты/коридоры
## Случайность — только в цветах/атмосфере (_rng от seed); раскладка детерминирована.

const PORTAL_SCENE := preload("res://actors/portal/portal.tscn")
const RICH_PANEL_SCENE := preload("res://actors/rich_panel/rich_panel.tscn")

# --- Сетка ---
const GRID := 3.0               # размер клетки сетки = ширина коридора/проёма, м
const STREET_CELLS := 1         # зазор-улица между комнатами (≥ ширины коридора), клеток
const ROOM_MIN_CELLS := 2       # минимальная сторона комнаты, клеток
const CORR := -1                # маркер коридорной клетки в _occ (id комнат ≥ 0)

# --- Пружинная утряска раскладки (force-directed) ---
const RELAX_ITERS := 320        # потолок итераций утряски
const RELAX_MAX_STEP := GRID    # максимум сдвига узла за итерацию, м
const RELAX_EPS := 0.01         # порог «утряслось» (макс. сдвиг за итерацию), м
const SPRING_MIN := 0.05        # сила пружины у корня (ближе к корню — слабее)
const SPRING_MAX := 0.22        # сила пружины у листьев (листья тянет сильнее всего)
const GRID_PULL := 0.06         # сила притяжения комнаты к линиям сетки
const COLLIDE_K := 0.6          # сила расталкивания пересекающихся кругов
const RELAX_GAP := GRID * 0.75  # зазор-улица, заложенный в радиус круга комнаты, м
const PLACE_MAX_RADIUS := 256   # потолок спирального поиска свободной клетки при снапе

const WALL_HEIGHT := 3.2        # минимальная высота стен, м
const WALL_THICK := 0.3
const ROUTE_EXPAND := 16        # запас области поиска коридора вокруг пары комнат, клеток

# --- Расстановка объектов по стенам ---
const OBJECT_INSET := 1.2       # отступ объекта от своей стены внутрь комнаты, м
const CORNER_MARGIN := 1.0      # отступ крайних объектов от углов вдоль стены, м
const OBJECT_GAP := 0.6         # зазор между соседними панелями вдоль стены, м
const HEAD_CLEARANCE := 0.8     # запас над самым высоким объектом до верха стены, м
const DOOR_MARGIN := 0.5        # отступ объектов от края проёма вдоль стены, м
# Запасной футпринт портала-ссылки (portal.tscn: 1.2 x 2.2 + подпись над ним).
const PORTAL_W := 1.4
const PORTAL_H := 2.6

# --- Масштаб: единый перевод CSS-пикселей страницы в метры мира ---
const M_PER_BASE_LINE := 0.18   # мир-высота глифа базового текста, м
const LABEL_PIXEL_SIZE := 0.006 # Label3D: 1px кегля Godot -> м
const PANEL_WIDTH_M := 2.2      # ширина текстовой таблички-Label3D, м
const IMAGE_FALLBACK_EM := 20.0 # ширина картинки без размеров в HTML, в «эмах» базы
const HEADING_EM := {1: 2.0, 2: 1.5, 3: 1.17, 4: 1.0, 5: 0.83, 6: 0.67}

var _space: Dictionary
var _rooms: Dictionary
var _root_id: int = -1
var _seed: int
var _rng := RandomNumberGenerator.new()
var _base_url: String = ""
var _image_loader: ImageLoader = null
var _base_px := 16.0
var _m_per_px := M_PER_BASE_LINE / 16.0
var _rich_w_m := 2.375
var _rich_font_px := 24

var _dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# Замеры/раскладка по фазам.
var _parent_of: Dictionary = {}   # childId -> parentId
var _object_size: Dictionary = {} # objectId -> Vector2(w, h), м
var _room_cells: Dictionary = {}  # roomId -> сторона в клетках (cw)
var _room_size: Dictionary = {}   # roomId -> сторона в метрах (cw*GRID)
var _room_wall_h: Dictionary = {} # roomId -> высота стен, м
var _pos2: Dictionary = {}        # roomId -> Vector2: координаты центра при утряске, м
var _radius: Dictionary = {}      # roomId -> float: безопасный радиус круга комнаты, м
var _depth: Dictionary = {}       # roomId -> int: глубина от корня (листья глубже -> пружины сильнее)
var _room_cell: Dictionary = {}   # roomId -> Vector2i: левый-верхний угол комнаты на сетке
var _occ: Dictionary = {}         # Vector2i -> roomId | CORR
var _corr_cells: Dictionary = {}  # Vector2i -> true: клетки полов-коридоров
var _room_openings: Dictionary = {} # roomId -> [{key, lo, hi}] проёмы в стенах (локальные м)
var _object_room: Dictionary = {} # objectId -> roomId
var _positions: Dictionary = {}   # roomId -> Vector3 (центр пола, мир)
var _shift := Vector3.ZERO        # сдвиг сетки в мир (корень к началу координат)

# Результат генерации, нужный main.
var spawn_point := Vector3.ZERO
var label_positions: Dictionary = {}   # anchorId -> Vector3


static func generate(space: Dictionary, parent: Node3D, seed_value: int, on_transition: Callable,
		base_url: String = "", image_loader: ImageLoader = null) -> WorldGenerator:
	var g := WorldGenerator.new()
	g._base_url = base_url
	g._image_loader = image_loader
	g._build(space, parent, seed_value, on_transition)
	return g


func _build(space: Dictionary, parent: Node3D, seed_value: int, on_transition: Callable) -> void:
	_space = space
	_rooms = space.get("rooms", {})
	_seed = seed_value
	_rng.seed = seed_value
	_base_px = float(space.get("typography", {}).get("base_px", 16.0))
	if _base_px <= 0.0:
		_base_px = 16.0
	_m_per_px = M_PER_BASE_LINE / _base_px
	_rich_w_m = float(RichPanel.PANEL_WIDTH_PX) / RichPanel.PIXEL_PER_METER
	_rich_font_px = max(8, int(round(_px_to_m(_base_px) * RichPanel.PIXEL_PER_METER)))
	_root_id = space.get("root", -1)
	if _root_id == -1 or not _rooms.has(_root_id):
		return

	_build_parent_map()
	_measure_objects()                       # фаза 1
	_compute_room_dims()                     # фаза 2 (+ снап к клеткам)
	_relax_layout()                          # фаза 3 (пружинная утряска, seeded)
	_snap_to_cells()                         # снап на сетку + дискретное расталкивание
	_finalize_positions()
	_fill_occupancy()
	_route_corridors()                       # фаза 4

	for id in _rooms.keys():
		for obj in _rooms[id]["objects"]:
			_object_room[obj["id"]] = id
		_build_room(id, parent, on_transition)  # фаза 5
	_build_corridor_floors(parent)
	_resolve_labels(space.get("labels", {}))
	_build_atmosphere(parent, _root_id)

	spawn_point = _positions.get(_root_id, Vector3.ZERO) + Vector3(0, 1.0, _room_size.get(_root_id, GRID * 2) * 0.3)


func _build_parent_map() -> void:
	for id in _rooms.keys():
		for ch in _rooms[id]["children"]:
			_parent_of[ch] = id


func _link_count(id: int) -> int:
	var n: int = _rooms[id]["children"].size()
	if _parent_of.has(id):
		n += 1
	return n


# --- Фаза 1: замер объектов (футпринт настенной панели) ---

func _measure_objects() -> void:
	for id in _rooms.keys():
		for obj in _rooms[id]["objects"]:
			_object_size[obj["id"]] = _measure_object(obj)


func _measure_object(obj: Dictionary) -> Vector2:
	var type: String = obj.get("type", "text")
	if type == "image":
		return _measure_image(obj)
	var fn = obj.get("function", null)
	if fn != null and typeof(fn) == TYPE_DICTIONARY:
		return Vector2(PORTAL_W, PORTAL_H)
	var runs: Array = obj.get("content", {}).get("runs", [])
	if type == "text" and not runs.is_empty() and (_runs_have_links(runs) or _obj_text(obj).length() > 200):
		return Vector2(_rich_w_m, RichPanel.estimate_height_m(runs, _rich_font_px))
	if type == "list" and _list_has_links(obj):
		return Vector2(_rich_w_m, RichPanel.estimate_height_m(_list_runs(obj), _rich_font_px))
	if type == "table" and _table_has_links(obj):
		return Vector2(_rich_w_m, RichPanel.estimate_height_m(_table_runs(obj), _rich_font_px))
	return _measure_panel(obj)


func _measure_panel(obj: Dictionary) -> Vector2:
	var type: String = obj.get("type", "text")
	var px := _base_px
	var text := ""
	match type:
		"heading":
			var level: int = int(obj.get("content", {}).get("level", 2))
			px = _base_px * float(HEADING_EM.get(level, 1.0))
			text = _obj_text(obj)
		"media":
			text = "▷ " + _obj_text(obj)
		"button", "input":
			text = "▢ " + _obj_text(obj)
		"list":
			text = _list_text(obj)
		"table":
			px = _base_px * 0.9
			text = _table_text(obj)
		_:
			text = _obj_text(obj)
	var glyph_m := _px_to_m(px)
	var h := _panel_height(_truncate(text, 220), glyph_m)
	return Vector2(PANEL_WIDTH_M, h)


func _measure_image(obj: Dictionary) -> Vector2:
	var content: Dictionary = obj.get("content", {})
	var want_w := _px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _px_to_m(float(content.get("height_px", 0.0)))
	var fallback_w := _px_to_m(_base_px * IMAGE_FALLBACK_EM)
	var w := 0.0
	var h := 0.0
	if want_w > 0.0 and want_h > 0.0:
		w = want_w
		h = want_h
	elif want_w > 0.0:
		w = want_w
		h = want_w * ImagePanel.DEFAULT_RATIO
	elif want_h > 0.0:
		h = want_h
		w = want_h / ImagePanel.DEFAULT_RATIO
	else:
		w = fallback_w
		h = fallback_w * ImagePanel.DEFAULT_RATIO
	if w > ImagePanel.MAX_WIDTH:
		var k := ImagePanel.MAX_WIDTH / w
		w *= k
		h *= k
	if h > ImagePanel.MAX_HEIGHT:
		var k2 := ImagePanel.MAX_HEIGHT / h
		w *= k2
		h *= k2
	return Vector2(maxf(0.2, w), maxf(0.2, h))


# --- Фаза 2: размер комнаты под объекты, снапнутый к сетке ---

func _compute_room_dims() -> void:
	for id in _rooms.keys():
		_compute_room_dim(id)


func _compute_room_dim(id: int) -> void:
	var objs: Array = _rooms[id]["objects"]
	var total := 0.0
	var max_w := 0.0
	var max_h := 0.0
	for obj in objs:
		var s: Vector2 = _object_size[obj["id"]]
		total += s.x + OBJECT_GAP
		max_w = maxf(max_w, s.x)
		max_h = maxf(max_h, s.y)
	# Периметр (4 стены минус полосы проходов) должен покрыть суммарную длину объектов.
	var doors: int = mini(_link_count(id), 4)
	var need := (total + float(doors) * GRID) * 1.2
	var l := need / 4.0 + 2.0 * CORNER_MARGIN
	l = maxf(l, max_w + 2.0 * (CORNER_MARGIN + DOOR_MARGIN))
	# Снап к клеткам.
	var cw: int = max(ROOM_MIN_CELLS, int(ceil(l / GRID)))
	_room_cells[id] = cw
	_room_size[id] = float(cw) * GRID
	_room_wall_h[id] = maxf(WALL_HEIGHT, max_h + HEAD_CLEARANCE)


# --- Фаза 3: пружинная утряска раскладки (force-directed), seeded ---

## Континуальная утряска: пружины родитель↔ребёнок (листья сильнее, к корню слабее) +
## расталкивание кругов (не дают налезать) + притяжение к сетке (стены ложатся на линии).
## Сид задаёт ТОЛЬКО стартовый разброс; сама релаксация детерминирована ⇒ один сид = один итог.
func _relax_layout() -> void:
	_compute_depths()
	for id in _rooms.keys():
		_radius[id] = _room_size[id] * 0.5 + RELAX_GAP
	_rng.seed = _seed
	_pos2[_root_id] = Vector2.ZERO
	_init_positions(_root_id)

	var max_depth := 1
	for id in _depth.keys():
		max_depth = max(max_depth, _depth[id])

	for _iter in RELAX_ITERS:
		var disp: Dictionary = {}
		for id in _rooms.keys():
			disp[id] = Vector2.ZERO
		_apply_springs(disp, max_depth)
		_apply_collision(disp)
		_apply_grid_pull(disp)
		var max_move := 0.0
		for id in _rooms.keys():
			var m: Vector2 = (disp[id] as Vector2).limit_length(RELAX_MAX_STEP)
			_pos2[id] += m
			max_move = maxf(max_move, m.length())
		if max_move < RELAX_EPS:
			break


func _compute_depths() -> void:
	_depth[_root_id] = 0
	var q: Array = [_root_id]
	var qi := 0
	while qi < q.size():
		var id: int = q[qi]
		qi += 1
		for ch in _rooms[id]["children"]:
			_depth[ch] = _depth[id] + 1
			q.append(ch)


## Стартовый разброс: каждый ребёнок — на сумму радиусов от родителя в случайную сторону (seed).
func _init_positions(id: int) -> void:
	for ch in _rooms[id]["children"]:
		var ang := _rng.randf() * TAU
		var dist: float = _radius[id] + _radius[ch]
		_pos2[ch] = _pos2[id] + Vector2(cos(ang), sin(ang)) * dist
		_init_positions(ch)


## Пружины родитель↔ребёнок. Длина покоя = соприкосновение кругов; сила растёт с глубиной
## ребёнка (листья тянет сильнее всего, ближе к корню — слабее).
func _apply_springs(disp: Dictionary, max_depth: int) -> void:
	for ch in _rooms.keys():
		if not _parent_of.has(ch):
			continue
		var p: int = _parent_of[ch]
		var d: Vector2 = _pos2[ch] - _pos2[p]
		var dist: float = d.length()
		if dist < 0.0001:
			d = Vector2.RIGHT
			dist = 0.0001
		var dir: Vector2 = d / dist
		var rest: float = _radius[p] + _radius[ch]
		var t: float = float(_depth[ch]) / float(max_depth)
		var k: float = lerpf(SPRING_MIN, SPRING_MAX, t)
		var f: float = k * (dist - rest)
		disp[ch] -= dir * f * 0.5
		disp[p] += dir * f * 0.5


## Расталкивание пересекающихся кругов — комнаты не налезают и не схлопываются.
func _apply_collision(disp: Dictionary) -> void:
	var ids: Array = _rooms.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: int = ids[i]
			var b: int = ids[j]
			var d: Vector2 = _pos2[b] - _pos2[a]
			var dist: float = d.length()
			var mind: float = _radius[a] + _radius[b]
			if dist >= mind:
				continue
			var dir: Vector2 = (d / dist) if dist > 0.0001 else Vector2.RIGHT
			var push: float = (mind - dist) * COLLIDE_K
			disp[a] -= dir * push * 0.5
			disp[b] += dir * push * 0.5


## Притяжение к сетке: тянет комнату так, чтобы её угол (а значит и стены) лёг на линии GRID.
func _apply_grid_pull(disp: Dictionary) -> void:
	for id in _rooms.keys():
		var half: float = _room_size[id] * 0.5
		var corner: Vector2 = _pos2[id] - Vector2(half, half)
		var snap_corner := Vector2(roundf(corner.x / GRID) * GRID, roundf(corner.y / GRID) * GRID)
		var target: Vector2 = snap_corner + Vector2(half, half)
		disp[id] += (target - _pos2[id]) * GRID_PULL


## Жёсткий снап на целочисленные клетки + дискретное расталкивание: точная сетка и зазор
## ≥STREET_CELLS-улица между комнатами (для прокладки коридоров) гарантированы.
## Снап на сетку коллизионно-свободной спиральной укладкой: комнаты ставятся от центра
## наружу в порядке близости к началу; каждая — в свою желаемую клетку, а если та занята
## (с учётом зазора STREET_CELLS) — спиралью ищется ближайшая свободная. Гарантирует точную
## сетку, отсутствие пересечений и зазор-улицу ≥STREET_CELLS между всеми комнатами. Детерминированно.
func _snap_to_cells() -> void:
	var ids: Array = _rooms.keys()
	var desired: Dictionary = {}
	for id in ids:
		var half: float = _room_size[id] * 0.5
		var corner: Vector2 = _pos2[id] - Vector2(half, half)
		desired[id] = Vector2i(int(round(corner.x / GRID)), int(round(corner.y / GRID)))
	# Сначала комнаты ближе к центру (устойчивое ядро), затем наружу.
	ids.sort_custom(func(a, b):
		var da: float = (_pos2[a] as Vector2).length_squared()
		var db: float = (_pos2[b] as Vector2).length_squared()
		if absf(da - db) > 0.01:
			return da < db
		return a < b)
	var blocked: Dictionary = {}   # клетки, занятые футпринтами + зазором
	for id in ids:
		var w: int = _room_cells[id]
		var c: Vector2i = _place_free(desired[id], w, blocked)
		_room_cell[id] = c
		_block_room(c, w, blocked)


## Спиральный поиск свободной клетки-угла под футпринт w×w вокруг желаемой start.
func _place_free(start: Vector2i, w: int, blocked: Dictionary) -> Vector2i:
	var r := 0
	while r <= PLACE_MAX_RADIUS:
		for off in _ring(r):
			var cand: Vector2i = start + off
			if _fits(cand, w, blocked):
				return cand
		r += 1
	return start


func _fits(c: Vector2i, w: int, blocked: Dictionary) -> bool:
	for dx in w:
		for dy in w:
			if blocked.has(Vector2i(c.x + dx, c.y + dy)):
				return false
	return true


## Резервирует футпринт комнаты, расширенный на STREET_CELLS (по Чебышёву) ⇒ соседи держат зазор.
func _block_room(c: Vector2i, w: int, blocked: Dictionary) -> void:
	var m := STREET_CELLS
	for dx in range(-m, w + m):
		for dy in range(-m, w + m):
			blocked[Vector2i(c.x + dx, c.y + dy)] = true


## Клетки-смещения на «кольце» Чебышёва радиуса r (r=0 — сам центр).
func _ring(r: int) -> Array:
	if r == 0:
		return [Vector2i.ZERO]
	var out: Array = []
	for x in range(-r, r + 1):
		out.append(Vector2i(x, -r))
		out.append(Vector2i(x, r))
	for y in range(-r + 1, r):
		out.append(Vector2i(-r, y))
		out.append(Vector2i(r, y))
	return out


## Сдвигает сетку в мир так, чтобы корень был у начала координат; считает центры комнат.
func _finalize_positions() -> void:
	var rc: Vector2i = _room_cell[_root_id]
	var rcw: int = _room_cells[_root_id]
	_shift = -Vector3((rc.x + rcw * 0.5) * GRID, 0.0, (rc.y + rcw * 0.5) * GRID)
	for id in _rooms.keys():
		var c: Vector2i = _room_cell[id]
		var cw: int = _room_cells[id]
		_positions[id] = _cell_world(c.x + cw * 0.5, c.y + cw * 0.5)


func _fill_occupancy() -> void:
	for id in _rooms.keys():
		var c: Vector2i = _room_cell[id]
		var cw: int = _room_cells[id]
		for dx in cw:
			for dy in cw:
				_occ[Vector2i(c.x + dx, c.y + dy)] = id


func _cell_world(col: float, row: float) -> Vector3:
	return Vector3(col * GRID, 0.0, row * GRID) + _shift


# --- Фаза 4: ортогональный роутинг коридоров по улицам ---

func _route_corridors() -> void:
	# Порядок — BFS от корня (короткие локальные маршруты раньше).
	var order: Array = [_root_id]
	var qi := 0
	while qi < order.size():
		var id: int = order[qi]
		qi += 1
		for ch in _rooms[id]["children"]:
			_route_edge(id, ch)
			order.append(ch)


func _route_edge(a: int, b: int) -> void:
	# Сначала строго по свободным улицам (коридоры не пересекаются), иначе разрешаем
	# проходить по чужим коридорам (общая клетка-перекрёсток, один пол), иначе фолбэк.
	if _bfs_route(a, b, false):
		return
	if _bfs_route(a, b, true):
		return
	_fallback_route(a, b)


## BFS по клеткам сетки от кольца вокруг a до клетки, смежной с b. allow_corr — можно ли
## проходить по уже проложенным коридорам. Возвращает успех; при успехе резервирует путь
## и регистрирует проёмы у a и b.
func _bfs_route(a: int, b: int, allow_corr: bool) -> bool:
	var lo := Vector2i.ZERO
	var hi := Vector2i.ZERO
	var bounds := _route_bounds(a, b)
	lo = bounds[0]
	hi = bounds[1]

	var came: Dictionary = {}        # cell -> предыдущая клетка (источник указывает на себя)
	var src_room: Dictionary = {}    # source cell -> клетка-стена a, к которой он примыкает
	var frontier: Array = []
	for bc in _border_cells(a):
		for d in _dirs:
			var nb: Vector2i = bc + d
			if _occ.get(nb, CORR - 1) == a:
				continue
			if not _in_bounds(nb, lo, hi) or _passable(nb, allow_corr) == false:
				continue
			if not came.has(nb):
				came[nb] = nb
				src_room[nb] = bc
				frontier.append(nb)

	var qi := 0
	var goal := Vector2i.ZERO
	var goal_b := Vector2i.ZERO
	var found := false
	while qi < frontier.size():
		var cur: Vector2i = frontier[qi]
		qi += 1
		var bcell := _adjacent_to(cur, b)
		if bcell.x != 2147483647:
			goal = cur
			goal_b = bcell
			found = true
			break
		for d in _dirs:
			var nb: Vector2i = cur + d
			if came.has(nb) or not _in_bounds(nb, lo, hi):
				continue
			if _passable(nb, allow_corr):
				came[nb] = cur
				frontier.append(nb)
	if not found:
		return false

	# Восстановление пути источник..goal.
	var path: Array = []
	var node := goal
	while true:
		path.append(node)
		var p: Vector2i = came[node]
		if p == node:
			break
		node = p
	path.reverse()

	for c in path:
		_occ[c] = CORR
		_corr_cells[c] = true

	# Проёмы: у a — между его стеной и первой клеткой пути; у b — между последней и b.
	var a_wall: Vector2i = src_room[path[0]]
	_add_opening(a, a_wall, path[0] - a_wall)
	_add_opening(b, goal_b, goal - goal_b)
	return true


## Прямой манхэттенский тоннель как крайняя мера (если улицы переполнены). Может пройти
## близко к комнатам, но гарантирует достижимость поддерева.
func _fallback_route(a: int, b: int) -> void:
	var ca: Vector2i = _room_cell[a]
	var cwa: int = _room_cells[a]
	var cb: Vector2i = _room_cell[b]
	var cwb: int = _room_cells[b]
	var ac := Vector2i(ca.x + cwa / 2, ca.y + cwa / 2)
	var bc := Vector2i(cb.x + cwb / 2, cb.y + cwb / 2)
	var da := _toward(ac, bc)
	var db := _toward(bc, ac)
	var a_wall := _border_toward(a, da)
	var b_wall := _border_toward(b, db)
	var start := a_wall + da
	var goal := b_wall + db
	var path := _manhattan(start, goal)
	for c in path:
		if not _occ.has(c) or _occ[c] == CORR:
			_occ[c] = CORR
		_corr_cells[c] = true
	_add_opening(a, a_wall, da)
	_add_opening(b, b_wall, db)


func _route_bounds(a: int, b: int) -> Array:
	var ca: Vector2i = _room_cell[a]
	var cwa: int = _room_cells[a]
	var cb: Vector2i = _room_cell[b]
	var cwb: int = _room_cells[b]
	var lo := Vector2i(min(ca.x, cb.x), min(ca.y, cb.y)) - Vector2i(ROUTE_EXPAND, ROUTE_EXPAND)
	var hi := Vector2i(max(ca.x + cwa, cb.x + cwb), max(ca.y + cwa, cb.y + cwb)) + Vector2i(ROUTE_EXPAND, ROUTE_EXPAND)
	return [lo, hi]


func _in_bounds(c: Vector2i, lo: Vector2i, hi: Vector2i) -> bool:
	return c.x >= lo.x and c.x <= hi.x and c.y >= lo.y and c.y <= hi.y


func _passable(cell: Vector2i, allow_corr: bool) -> bool:
	if not _occ.has(cell):
		return true
	return allow_corr and _occ[cell] == CORR


## Клетки-стены комнаты (периметр футпринта).
func _border_cells(id: int) -> Array:
	var c: Vector2i = _room_cell[id]
	var cw: int = _room_cells[id]
	var out: Array = []
	for dx in cw:
		for dy in cw:
			if dx == 0 or dy == 0 or dx == cw - 1 or dy == cw - 1:
				out.append(Vector2i(c.x + dx, c.y + dy))
	return out


## Клетка комнаты id, смежная с cell (или sentinel x=2147483647, если нет).
func _adjacent_to(cell: Vector2i, id: int) -> Vector2i:
	for d in _dirs:
		var nb: Vector2i = cell + d
		if _occ.get(nb, CORR - 1) == id:
			return nb
	return Vector2i(2147483647, 0)


## Регистрирует проём в стене комнаты id: room_cell — клетка-стена, d — наружу (в коридор).
func _add_opening(id: int, room_cell: Vector2i, d: Vector2i) -> void:
	var c0: Vector2i = _room_cell[id]
	var cw: int = _room_cells[id]
	var key := _dir_key(d)
	var k: int = (room_cell.y - c0.y) if d.x != 0 else (room_cell.x - c0.x)
	var lo := (-cw * 0.5 + float(k)) * GRID
	var op := {"key": key, "lo": lo, "hi": lo + GRID}
	if not _room_openings.has(id):
		_room_openings[id] = []
	# Не дублируем один и тот же проём (две дороги в одну клетку-стену).
	for o in _room_openings[id]:
		if o["key"] == key and absf(o["lo"] - lo) < 0.01:
			return
	_room_openings[id].append(op)


func _dir_key(d: Vector2i) -> String:
	if d == Vector2i(1, 0):
		return "px"
	if d == Vector2i(-1, 0):
		return "nx"
	if d == Vector2i(0, 1):
		return "pz"
	return "nz"


func _toward(from: Vector2i, to: Vector2i) -> Vector2i:
	var dx := to.x - from.x
	var dy := to.y - from.y
	if abs(dx) >= abs(dy):
		return Vector2i(signi(dx), 0) if dx != 0 else Vector2i(1, 0)
	return Vector2i(0, signi(dy))


## Клетка-стена комнаты в направлении d (середина соответствующей стороны).
func _border_toward(id: int, d: Vector2i) -> Vector2i:
	var c: Vector2i = _room_cell[id]
	var cw: int = _room_cells[id]
	var mid: int = cw / 2
	if d == Vector2i(1, 0):
		return Vector2i(c.x + cw - 1, c.y + mid)
	if d == Vector2i(-1, 0):
		return Vector2i(c.x, c.y + mid)
	if d == Vector2i(0, 1):
		return Vector2i(c.x + mid, c.y + cw - 1)
	return Vector2i(c.x + mid, c.y)


func _manhattan(start: Vector2i, goal: Vector2i) -> Array:
	var out: Array = []
	var cur := start
	out.append(cur)
	while cur.x != goal.x:
		cur += Vector2i(signi(goal.x - cur.x), 0)
		out.append(cur)
	while cur.y != goal.y:
		cur += Vector2i(0, signi(goal.y - cur.y))
		out.append(cur)
	return out


# --- Фаза 5: геометрия ---

func _build_room(id: int, parent: Node3D, on_transition: Callable) -> void:
	var room: Dictionary = _rooms[id]
	var holder := Node3D.new()
	holder.name = "Room_%d" % id
	holder.position = _positions[id]
	parent.add_child(holder)

	var is_connector: bool = room["kind"] == "connector"
	var l: float = _room_size[id]
	var floor_color := _room_color(room, is_connector)
	_add_box(holder, Vector3(l, 0.4, l), Vector3(0, -0.2, 0), floor_color, true)
	_build_walls(holder, id, floor_color.lightened(0.1))
	_place_objects(room, holder, on_transition)


## Четыре стены; на каждой вычитаем интервалы-проёмы (_room_openings) и ставим сегменты.
func _build_walls(holder: Node3D, id: int, color: Color) -> void:
	var l: float = _room_size[id]
	var h: float = _room_wall_h[id]
	var half := l * 0.5
	var ops: Array = _room_openings.get(id, [])
	for w in _wall_defs():
		var gaps: Array = []
		for o in ops:
			if o["key"] == w["key"]:
				gaps.append([o["lo"], o["hi"]])
		gaps.sort_custom(func(p, q): return p[0] < q[0])
		var cursor := -half
		for g in gaps:
			_add_wall_seg(holder, w, cursor, g[0], half, h, color)
			cursor = g[1]
		_add_wall_seg(holder, w, cursor, half, half, h, color)


func _wall_defs() -> Array:
	return [
		{"kind": "x", "sign": 1.0, "yaw": -PI * 0.5, "key": "px"},
		{"kind": "x", "sign": -1.0, "yaw": PI * 0.5, "key": "nx"},
		{"kind": "z", "sign": 1.0, "yaw": PI, "key": "pz"},
		{"kind": "z", "sign": -1.0, "yaw": 0.0, "key": "nz"},
	]


func _add_wall_seg(holder: Node3D, w: Dictionary, lo: float, hi: float, half: float, h: float, color: Color) -> void:
	if hi - lo <= 0.05:
		return
	var center := (lo + hi) * 0.5
	var length := hi - lo
	if w["kind"] == "x":
		_add_box(holder, Vector3(WALL_THICK, h, length), Vector3(w["sign"] * half, h * 0.5, center), color, true)
	else:
		_add_box(holder, Vector3(length, h, WALL_THICK), Vector3(center, h * 0.5, w["sign"] * half), color, true)


## Расставляет объекты по стенам shelf-укладкой: сперва сплошные стены, затем стены с
## проёмами (по свободным интервалам). Курсор двигается на ширину объекта + зазор.
func _place_objects(room: Dictionary, holder: Node3D, on_transition: Callable) -> void:
	var objs: Array = room["objects"]
	if objs.is_empty():
		return
	var spans := _wall_spans(room["id"])
	if spans.is_empty():
		return
	var si := 0
	for obj in objs:
		var w: float = _object_size[obj["id"]].x
		while si < spans.size() and spans[si]["cursor"] + w > spans[si]["hi"] + 0.001:
			si += 1
		if si >= spans.size():
			si = spans.size() - 1
		var span: Dictionary = spans[si]
		var t: float = span["cursor"] + w * 0.5
		span["cursor"] = span["cursor"] + w + OBJECT_GAP
		_build_object(obj, holder, _span_pos(span, t), span["w"]["yaw"], on_transition)


func _wall_spans(id: int) -> Array:
	var l: float = _room_size[id]
	var half := l * 0.5
	var inset := half - OBJECT_INSET
	var along_lo := -half + CORNER_MARGIN
	var along_hi := half - CORNER_MARGIN
	var ops: Array = _room_openings.get(id, [])
	var solid: Array = []
	var doored: Array = []
	for w in _wall_defs():
		var gaps: Array = []
		for o in ops:
			if o["key"] == w["key"]:
				gaps.append([o["lo"], o["hi"]])
		gaps.sort_custom(func(p, q): return p[0] < q[0])
		var free := _subtract_gaps(along_lo, along_hi, gaps, DOOR_MARGIN)
		var target: Array = solid if gaps.is_empty() else doored
		for iv in free:
			if iv[1] - iv[0] >= 0.6:
				target.append(_mk_span(w, iv[0], iv[1], inset))
	solid.append_array(doored)
	return solid


## Свободные интервалы [lo,hi] за вычетом gaps (расширенных margin с каждой стороны).
func _subtract_gaps(lo: float, hi: float, gaps: Array, margin: float) -> Array:
	var free: Array = []
	var cur := lo
	for g in gaps:
		var glo: float = g[0] - margin
		var ghi: float = g[1] + margin
		if glo > cur:
			free.append([cur, minf(glo, hi)])
		cur = maxf(cur, ghi)
		if cur >= hi:
			break
	if cur < hi:
		free.append([cur, hi])
	return free


func _mk_span(w: Dictionary, lo: float, hi: float, inset: float) -> Dictionary:
	return {"w": w, "lo": lo, "hi": hi, "inset": inset, "cursor": lo}


func _span_pos(span: Dictionary, t: float) -> Vector3:
	var w: Dictionary = span["w"]
	var inset: float = span["inset"]
	if w["kind"] == "x":
		return Vector3(w["sign"] * inset, 0.0, t)
	return Vector3(t, 0.0, w["sign"] * inset)


## Полы коридоров — по одному GRID-квадрату на коридорную клетку.
func _build_corridor_floors(parent: Node3D) -> void:
	for cell in _corr_cells.keys():
		var holder := Node3D.new()
		holder.position = _cell_world(cell.x + 0.5, cell.y + 0.5)
		parent.add_child(holder)
		_add_box(holder, Vector3(GRID, 0.4, GRID), Vector3(0, -0.2, 0), Color(0.3, 0.3, 0.33), true)


# --- Объекты комнаты ---

func _build_object(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> void:
	var fn = obj.get("function", null)
	var is_link: bool = fn != null and typeof(fn) == TYPE_DICTIONARY

	if obj.get("type", "") == "image":
		_build_image_panel(obj, holder, local_pos, yaw, fn if is_link else null, on_transition)
		return

	if is_link:
		var portal: Portal = PORTAL_SCENE.instantiate()
		portal.setup(fn, _obj_text(obj))
		holder.add_child(portal)
		portal.position = local_pos
		portal.rotation.y = yaw
		if on_transition.is_valid():
			portal.activated.connect(on_transition)
		return

	var runs: Array = obj.get("content", {}).get("runs", [])
	if obj.get("type", "") == "text" and not runs.is_empty():
		if _runs_have_links(runs) or _obj_text(obj).length() > 200:
			_build_rich_panel(runs, holder, local_pos, yaw, on_transition)
			return

	match obj.get("type", "text"):
		"heading":
			var level: int = int(obj.get("content", {}).get("level", 2))
			var px: float = _base_px * float(HEADING_EM.get(level, 1.0))
			_build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.95, 0.85, 0.4), px)
		"media":
			_build_panel(holder, local_pos, yaw, "▷ " + _obj_text(obj),
				Color(0.25, 0.25, 0.3), _base_px)
		"button", "input":
			_build_panel(holder, local_pos, yaw, "▢ " + _obj_text(obj),
				Color(0.5, 0.7, 0.5), _base_px)
		"list":
			if _list_has_links(obj):
				_build_rich_panel(_list_runs(obj), holder, local_pos, yaw, on_transition)
			else:
				_build_panel(holder, local_pos, yaw, _list_text(obj),
					Color(0.6, 0.6, 0.65), _base_px)
		"table":
			if _table_has_links(obj):
				_build_rich_panel(_table_runs(obj), holder, local_pos, yaw, on_transition)
			else:
				_build_panel(holder, local_pos, yaw, _table_text(obj),
					Color(0.55, 0.6, 0.6), _base_px * 0.9)
		_:
			_build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.85, 0.85, 0.85), _base_px)


func _build_panel(holder: Node3D, local_pos: Vector3, yaw: float, text: String, color: Color, font_css_px: float) -> void:
	var node := Node3D.new()
	holder.add_child(node)
	node.position = local_pos
	node.rotation.y = yaw
	var font := _godot_font(font_css_px)
	var glyph_m := _px_to_m(font_css_px)
	var clipped := _truncate(text, 220)
	var height := _panel_height(clipped, glyph_m)
	_add_box(node, Vector3(PANEL_WIDTH_M, height, 0.15), Vector3(0, height * 0.5, 0), color, false)
	var label := Label3D.new()
	label.text = clipped
	label.font_size = font
	label.outline_size = max(8, int(font * 0.25))
	label.pixel_size = LABEL_PIXEL_SIZE
	label.width = int(PANEL_WIDTH_M / LABEL_PIXEL_SIZE)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector3(0, height * 0.5, 0.1)
	node.add_child(label)


func _panel_height(text: String, glyph_m: float) -> float:
	var char_w: float = max(0.001, glyph_m * 0.5)
	var per_line: float = max(1.0, PANEL_WIDTH_M / char_w)
	var explicit := 1 + text.count("\n")
	var wrapped := int(ceil(text.length() / per_line))
	var lines: int = max(explicit, wrapped)
	return clampf(lines * glyph_m * 1.5 + 0.4, 1.0, 6.0)


func _build_rich_panel(runs: Array, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> void:
	var panel: RichPanel = RICH_PANEL_SCENE.instantiate()
	panel.setup(runs, _px_to_m(_base_px))
	holder.add_child(panel)
	panel.rotation.y = yaw
	var half := panel.get_height_m() * 0.5
	panel.position = local_pos + Vector3(0, max(1.6, half + 0.3), 0)
	if on_transition.is_valid():
		panel.link_activated.connect(on_transition)


func _build_image_panel(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float,
		transition, on_transition: Callable) -> void:
	var content: Dictionary = obj.get("content", {})
	var alt: String = str(content.get("alt", content.get("text", "")))
	var want_w := _px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _px_to_m(float(content.get("height_px", 0.0)))
	var fallback_w := _px_to_m(_base_px * IMAGE_FALLBACK_EM)
	var panel := ImagePanel.new()
	panel.setup(alt, transition, want_w, want_h, fallback_w)
	holder.add_child(panel)
	panel.position = local_pos
	panel.rotation.y = yaw
	if transition != null and on_transition.is_valid():
		panel.link_activated.connect(on_transition)

	var src: String = str(content.get("src", ""))
	if src != "" and _image_loader != null:
		var url := PageFetcher.resolve_url(src, _base_url)
		panel.request_load(url, _image_loader)


func _runs_have_links(runs: Array) -> bool:
	for r in runs:
		if r.get("function", null) != null:
			return true
	return false


# --- Атмосфера (свет + небо), процедурно из данных страницы ---

func _build_atmosphere(parent: Node3D, root_id: int) -> void:
	var palette := _collect_bg_colors()

	var base_hue: float
	var base_sat: float
	if palette.is_empty():
		_rng.seed = _seed
		base_hue = _rng.randf()
		base_sat = 0.35
	else:
		var avg := Color(0, 0, 0)
		for c in palette:
			avg += c
		avg /= float(palette.size())
		base_hue = avg.h
		base_sat = clampf(avg.s + 0.1, 0.2, 0.7)

	var weight := float(_rooms[root_id]["hints"].get("weight", 0))
	var richness := clampf(weight / 30.0, 0.0, 1.0)
	var elevation := deg_to_rad(lerpf(8.0, 65.0, richness))

	_rng.seed = _seed ^ 0x9E3779B9
	var azimuth := deg_to_rad(_rng.randf() * 360.0)

	var warmth := 1.0 - sin(elevation)
	var sun_color := Color.from_hsv(lerpf(base_hue, 0.07, warmth * 0.8), 0.35 + warmth * 0.3, 1.0)

	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color.from_hsv(base_hue, base_sat, 0.55)
	sky.sky_horizon_color = Color.from_hsv(lerpf(base_hue, 0.07, warmth), base_sat * 0.6, lerpf(0.95, 0.7, warmth))
	sky.ground_bottom_color = Color.from_hsv(base_hue, base_sat * 0.5, 0.12)
	sky.ground_horizon_color = sky.sky_horizon_color.darkened(0.3)
	sky.sun_angle_max = 12.0

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_res := Sky.new()
	sky_res.sky_material = sky
	env.sky = sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = lerpf(0.5, 0.9, richness)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.name = "Atmosphere"
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(-elevation, azimuth, 0.0)
	sun.light_color = sun_color
	sun.light_energy = lerpf(0.7, 1.3, sin(elevation))
	sun.shadow_enabled = true
	parent.add_child(sun)


func _collect_bg_colors() -> Array:
	var colors: Array = []
	for id in _rooms.keys():
		var css: Dictionary = _rooms[id]["hints"].get("css", {})
		if css.has("bg"):
			var c = _parse_css_color(css["bg"])
			if c != null:
				colors.append(c)
	return colors


# --- Метки якорей ---

func _resolve_labels(labels: Dictionary) -> void:
	for anchor_id in labels.keys():
		var target_id: int = labels[anchor_id]
		if _positions.has(target_id):
			label_positions[anchor_id] = _positions[target_id] + Vector3(0, 1.0, 0)
		elif _object_room.has(target_id) and _positions.has(_object_room[target_id]):
			label_positions[anchor_id] = _positions[_object_room[target_id]] + Vector3(0, 1.0, 0)


# --- Масштаб (CSS-пиксели страницы -> метры мира) ---

func _px_to_m(px: float) -> float:
	return px * _m_per_px


func _godot_font(css_px: float) -> int:
	return max(8, int(round(css_px * _m_per_px / LABEL_PIXEL_SIZE)))


# --- Низкоуровневые помощники ---

func _add_box(holder: Node3D, size: Vector3, local_pos: Vector3, color: Color, collide: bool) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	mesh.position = local_pos
	holder.add_child(mesh)
	if collide:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		body.add_child(shape)
		body.position = local_pos
		holder.add_child(body)


func _room_color(room: Dictionary, is_connector: bool) -> Color:
	var css: Dictionary = room["hints"].get("css", {})
	if css.has("bg"):
		var c = _parse_css_color(css["bg"])
		if c != null:
			return c
	if is_connector:
		return Color(0.32, 0.34, 0.4)
	_rng.seed = _seed + room["id"] * 2654435761
	return Color.from_hsv(_rng.randf(), 0.28, 0.7)


func _parse_css_color(value: String):
	value = value.strip_edges().to_lower()
	if Color.html_is_valid(value):
		return Color.html(value)
	return null


func _obj_text(obj: Dictionary) -> String:
	var content: Dictionary = obj.get("content", {})
	var t: String = content.get("text", content.get("alt", ""))
	if t.strip_edges() == "":
		var fn = obj.get("function", null)
		if fn != null:
			t = fn.get("href", fn.get("target", "ссылка"))
	return t


func _list_text(obj: Dictionary) -> String:
	var items: Array = obj.get("content", {}).get("items", [])
	var lines: PackedStringArray = []
	for it in items:
		lines.append("• " + str(it.get("text", "")))
	return "\n".join(lines)


func _list_has_links(obj: Dictionary) -> bool:
	for it in obj.get("content", {}).get("items", []):
		if _runs_have_links(it.get("runs", [])):
			return true
	return false


func _list_runs(obj: Dictionary) -> Array:
	var runs: Array = []
	for it in obj.get("content", {}).get("items", []):
		runs.append({"text": "•  ", "function": null})
		_append_runs(runs, it.get("runs", []), str(it.get("text", "")))
		runs.append({"text": "\n", "function": null})
	return runs


func _table_text(obj: Dictionary) -> String:
	var content: Dictionary = obj.get("content", {})
	var lines: PackedStringArray = []
	var caption: String = content.get("caption", "")
	if caption.strip_edges() != "":
		lines.append("▦ " + caption)
	for row in content.get("rows", []):
		var cells: PackedStringArray = []
		for cell in row.get("cells", []):
			cells.append(str(cell.get("text", "")))
		lines.append(" | ".join(cells))
	return "\n".join(lines)


func _table_has_links(obj: Dictionary) -> bool:
	for row in obj.get("content", {}).get("rows", []):
		for cell in row.get("cells", []):
			if _runs_have_links(cell.get("runs", [])):
				return true
	return false


func _table_runs(obj: Dictionary) -> Array:
	var content: Dictionary = obj.get("content", {})
	var runs: Array = []
	var caption: String = content.get("caption", "")
	if caption.strip_edges() != "":
		runs.append({"text": "▦ " + caption + "\n", "function": null})
	for row in content.get("rows", []):
		var cells: Array = row.get("cells", [])
		for i in cells.size():
			if i > 0:
				runs.append({"text": "  |  ", "function": null})
			var cell: Dictionary = cells[i]
			_append_runs(runs, cell.get("runs", []), str(cell.get("text", "")))
		runs.append({"text": "\n", "function": null})
	return runs


func _append_runs(out: Array, src_runs: Array, fallback_text: String) -> void:
	if src_runs.is_empty():
		if fallback_text != "":
			out.append({"text": fallback_text, "function": null})
		return
	for r in src_runs:
		out.append(r)


func _truncate(s: String, n: int) -> String:
	s = s.strip_edges()
	if s.length() <= n:
		return s
	return s.substr(0, n) + "…"
