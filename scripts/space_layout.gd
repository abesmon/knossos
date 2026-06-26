class_name SpaceLayout
extends RefCounted

## ЕДИНЫЙ генератор пространства (фаза геометрии F). Чистый алгоритм раскладки: формы
## комнат из пентамино и их примыкание от корня, БЕЗ какой-либо визуализации. Один и тот же
## экземпляр кормит и отладочный вид сверху (scenes/geometry_top_view.gd, площадка
## scenes/geometry_debug.gd), и реальное 3D-пространство, по которому ходит игрок
## (WorldGenerator строит геометрию из этой раскладки). См. docs/geometry-lab.md.
##
## Вход — артефакт топологии (Dictionary из TopologyBuilder) + seed. Координат у
## топологии нет, всё сочиняется здесь. Алгоритм (см. docs/geometry-lab.md):
##   1. оценка потребности комнаты = число объектов + запас на проход (_estimate_need);
##   2. выбор формы: need ≤ 4 — прямоугольник 2×2/3×2 (вращается); иначе ceil(need/5)
##      случайных пентамино (_make_shape);
##   3. упаковка форм в максимально компактный описывающий прямоугольник (_pack_pieces);
##   4. раскладка комнат от корня, каждый ребёнок примыкает к родителю; если примкнуть
##      некуда — кладём так, чтобы минимизировать путь (_place_rooms);
##   5. дорожки между комнатами, которые не примкнули (_route).
##
## Выход — Dictionary раскладки (см. build), который потребляют GeometryTopView (вид сверху)
## и WorldGenerator (3D-геометрия комнат, стен с проёмами-дверьми, коридоров).

## Запас клеток на свободный проход в комнате. Пока заглушка (всегда 1); позже —
## функция от плотности/связности комнаты. См. _passage_slots.
const PASSAGE_SLOTS := 1

## Порог формы: комната с потребностью не выше этого — прямоугольник, иначе пентамино.
const RECT_THRESHOLD := 4

## Варианты прямоугольной комнаты (до вращения), клетки. 2×2 = 4 слота, 3×2 = 6.
const RECT_OPTIONS := [Vector2i(2, 2), Vector2i(3, 2)]

const NEIGHBORS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## Вероятность [0..1] заполнить найденный алков (пустую клетку-«зубец» внутри/на краю формы)
## частью комнаты — см. _close_alcoves.
var alcove_fill_chance := 0.5
## Вероятность [0..1], что комната (вместе со своим поддеревом) будет подтянута к родителю по
## свободному месту после раскладки — см. _pull_to_parent.
var pull_to_parent_chance := 0.5

## Внутренний маршрут движения сквозь комнату (см. _compute_routes). Целевая длина пути ≈
##   реальная_длина × route_base_excess × (route_deadend_mult если лист) × (пентамино-множитель).
## route_base_excess — базовая «избыточность» (петлистость) пути.
var route_base_excess := 1.5
## Множитель избыточности для тупиков-листьев (маршрут вход→вход «погулять и вернуться»).
var route_deadend_mult := 2.0
## Вклад пентамино: для комнаты-пентамино множитель = max(1, pent_count × route_pentomino_mult).
var route_pentomino_mult := 0.5

## Бюджет шагов рандомизированного DFS при поиске простого маршрута заданной длины в комнате.
const ROUTE_BUDGET := 6000

var _rng := RandomNumberGenerator.new()
var _pents: Array = []   # 12 свободных пентамино, каждый — Array[Vector2i]


func _init() -> void:
	_pents = _build_pentominoes()


## Главный вход. space — артефакт топологии, seed — детерминирует случайность.
## Возвращает:
##   {
##     root: int,
##     rooms: { id -> {
##        need, kind, shape_kind ("rect"|"pentomino"),
##        dims: Vector2i (описывающий прямоугольник, клетки),
##        cells: Array[Vector2i] (футпринт относительно своего угла),
##        pieces: Array[Array[Vector2i]] (клетки по деталям — для раскраски),
##        pos: Vector2i (позиция угла на общей сетке) } },
##     corridors: [ {from:int, to:int} ],   # пары комнат, которые не примкнули
##   }
func build(space: Dictionary, seed_value: int) -> Dictionary:
	_rng.seed = seed_value
	var rooms: Dictionary = space.get("rooms", {})
	var root: int = space.get("root", -1)

	var out_rooms := {}
	for id in rooms:
		var room: Dictionary = rooms[id]
		var need := _estimate_need(room)
		var shape := _make_shape(need)
		out_rooms[id] = {
			"need": need,
			"kind": room.get("kind", "room"),
			"shape_kind": "rect" if need <= RECT_THRESHOLD else "pentomino",
			"dims": shape["dims"],
			"cells": shape["cells"],
			"pieces": shape["pieces"],
		}

	# Раскладка мутирует out_rooms (pos/pieces/cells/dims под выбранную ориентацию) и
	# возвращает связи родитель→ребёнок с путём по клеткам.
	var corridors := _place_rooms(space, out_rooms)
	# Пост-фаза: с вероятностью подтянуть комнаты (с их поддеревом) к родителю по свободному месту.
	_pull_to_parent(space, out_rooms, corridors)
	# Внутренние маршруты движения сквозь каждую комнату (после финальных позиций и дверей).
	_compute_routes(space, out_rooms, corridors)
	# Отладочные "виртуальные стены" у маршрутов: кандидаты под более плотную упаковку объектов.
	_compute_virtual_walls(out_rooms, corridors)
	return {"root": root, "rooms": out_rooms, "corridors": corridors}


# --- Фаза 1: потребность комнаты ---

func _estimate_need(room: Dictionary) -> int:
	var objects: Array = room.get("objects", [])
	return objects.size() + _passage_slots(room)


## Запас клеток на проход. Заглушка — потом сюда плотность/связность комнаты.
func _passage_slots(_room: Dictionary) -> int:
	return PASSAGE_SLOTS


# --- Фаза 2: форма комнаты ---

## need ≤ 4 → один прямоугольник 2×2/3×2 (вращение даёт packer);
## need > 4 → ceil(need/5) случайных пентамино (но не меньше 2), упакованных компактно.
func _make_shape(need: int) -> Dictionary:
	var shape: Dictionary
	if need <= RECT_THRESHOLD:
		var opt: Vector2i = RECT_OPTIONS[_rng.randi() % RECT_OPTIONS.size()]
		shape = _pack_pieces([_rect_cells(opt)])
	else:
		var count: int = maxi(2, int(ceil(float(need) / 5.0)))
		var pieces: Array = []
		for _i in count:
			pieces.append(_pents[_rng.randi() % _pents.size()])
		shape = _pack_pieces(pieces)
	_close_alcoves(shape)
	return shape


## Ищет в форме «алковы» — вогнутости с симметричными краями — и с вероятностью
## alcove_fill_chance достраивает их частью комнаты (клетки приписываются к соседней детали для
## раскраски). Алков = непрерывный ряд пустых клеток (по строке или столбцу), у которого с ОБОИХ
## концов стенки (фланги) и сплошная задняя стенка с одной перпендикулярной стороны. Пример:
##   x o o x          x o o o x        — заполняются целиком (ровные края);
##   x x x x          x x x x x
##   x o o o o        — заполнится только нижний ровный ряд (xooox),
##   x o o o x          а верхний останется торчать хвостиком (правый край неровный).
##   x x x x x
## Заполнение итеративное: закрытый ряд открывает доступ к лежащему за ним. Решение (заполнять
## или нет) принимается по разу на каждый отдельный ряд-алков. Размер прямоугольника не меняется.
func _close_alcoves(shape: Dictionary) -> void:
	if alcove_fill_chance <= 0.0:
		return
	var occ := {}   # локальная клетка -> индекс детали
	for pi in shape["pieces"].size():
		for c in shape["pieces"][pi]:
			occ[c] = pi
	var dims: Vector2i = shape["dims"]
	var decided := {}
	var guard := 0
	while guard < 256:
		guard += 1
		var any_new := false
		for run in _find_alcove_runs(occ, dims):
			var key := _key(run)
			if decided.has(key):
				continue
			decided[key] = true
			any_new = true
			if _rng.randf() >= alcove_fill_chance:
				continue
			for c in run:
				if occ.has(c):
					continue
				var pidx := _neighbor_piece(c, occ)
				if pidx < 0:
					continue
				occ[c] = pidx
				shape["pieces"][pidx].append(c)
				shape["cells"].append(c)
		if not any_new:
			break


## Все ряды-алковы текущей формы: максимальные ряды пустых клеток (горизонтальные и вертикальные)
## со стенками на обоих концах (фланги) и сплошной задней стенкой с одной перпендикулярной стороны.
func _find_alcove_runs(occ: Dictionary, dims: Vector2i) -> Array:
	var runs: Array = []
	# Горизонтальные ряды (открыты вверх или вниз).
	for y in range(dims.y):
		var x := 0
		while x < dims.x:
			if occ.has(Vector2i(x, y)):
				x += 1
				continue
			var x1 := x
			while x < dims.x and not occ.has(Vector2i(x, y)):
				x += 1
			var x2 := x - 1
			if not occ.has(Vector2i(x1 - 1, y)) or not occ.has(Vector2i(x2 + 1, y)):
				continue   # нет стенки на одном из концов — не симметрично
			if _row_backed(occ, x1, x2, y, 1) or _row_backed(occ, x1, x2, y, -1):
				var run: Array = []
				for xx in range(x1, x2 + 1):
					run.append(Vector2i(xx, y))
				runs.append(run)
	# Вертикальные ряды (открыты влево или вправо).
	for x in range(dims.x):
		var y := 0
		while y < dims.y:
			if occ.has(Vector2i(x, y)):
				y += 1
				continue
			var y1 := y
			while y < dims.y and not occ.has(Vector2i(x, y)):
				y += 1
			var y2 := y - 1
			if not occ.has(Vector2i(x, y1 - 1)) or not occ.has(Vector2i(x, y2 + 1)):
				continue
			if _col_backed(occ, x, y1, y2, 1) or _col_backed(occ, x, y1, y2, -1):
				var run: Array = []
				for yy in range(y1, y2 + 1):
					run.append(Vector2i(x, yy))
				runs.append(run)
	return runs


## Сплошная ли задняя стенка под/над горизонтальным рядом x1..x2 на строке y (dy = +1 низ, −1 верх).
func _row_backed(occ: Dictionary, x1: int, x2: int, y: int, dy: int) -> bool:
	for xx in range(x1, x2 + 1):
		if not occ.has(Vector2i(xx, y + dy)):
			return false
	return true


## Сплошная ли задняя стенка слева/справа от вертикального ряда y1..y2 на столбце x (dx = +1 право, −1 лево).
func _col_backed(occ: Dictionary, x: int, y1: int, y2: int, dx: int) -> bool:
	for yy in range(y1, y2 + 1):
		if not occ.has(Vector2i(x + dx, yy)):
			return false
	return true


func _neighbor_piece(c: Vector2i, occ: Dictionary) -> int:
	for d in NEIGHBORS:
		if occ.has(c + d):
			return occ[c + d]
	return -1


func _rect_cells(dims: Vector2i) -> Array:
	var cells: Array = []
	for y in dims.y:
		for x in dims.x:
			cells.append(Vector2i(x, y))
	return cells


# --- Фаза 3: упаковка деталей в компактный прямоугольник ---

## Жадная упаковка «снизу-влево с приращением». Первая деталь кладётся в начало; каждая
## следующая перебирается по всем ориентациям и позициям в окрестности уже уложенного,
## должна примыкать к нему (связность = компактность) и не пересекаться. Из допустимых
## выбирается та, что даёт наименьший описывающий прямоугольник (с бонусом за квадратность).
## Возвращает {cells, pieces, dims} с нормализованными к (0,0) координатами.
func _pack_pieces(pieces: Array) -> Dictionary:
	var occ := {}            # Vector2i -> индекс детали
	var piece_cells: Array = []

	for pi in pieces.size():
		var orients := _orientations(pieces[pi])
		if occ.is_empty():
			var first: Array = orients[_rng.randi() % orients.size()]
			for c in first:
				occ[c] = pi
			piece_cells.append(first.duplicate())
			continue

		var bb := _bbox_of_keys(occ)
		var best: Array = []
		var best_score := INF
		for orient in orients:
			var osz := _extent(orient)
			for oy in range(bb.position.y - osz.y, bb.position.y + bb.size.y + 1):
				for ox in range(bb.position.x - osz.x, bb.position.x + bb.size.x + 1):
					var off := Vector2i(ox, oy)
					var trial := _try_place(orient, off, occ)
					if trial.is_empty():
						continue
					var score := _score_bbox(occ, trial)
					if score < best_score:
						best_score = score
						best = trial
		if best.is_empty():
			# теоретически недостижимо (окрестность всегда вмещает), но не падаем
			best = _try_place(orients[0], bb.position + Vector2i(bb.size.x, 0), occ)
		for c in best:
			occ[c] = pi
		piece_cells.append(best)

	# Нормализуем всё к (0,0).
	var bb2 := _bbox_of_keys(occ)
	var origin: Vector2i = bb2.position
	var all_cells: Array = []
	for i in piece_cells.size():
		var shifted: Array = []
		for c in piece_cells[i]:
			var p: Vector2i = c - origin
			shifted.append(p)
			all_cells.append(p)
		piece_cells[i] = shifted
	return {"cells": all_cells, "pieces": piece_cells, "dims": bb2.size}


## Пытается положить ориентацию по смещению: возвращает клетки, если не пересекается с occ
## и примыкает хотя бы одной гранью; иначе пустой массив.
func _try_place(orient: Array, off: Vector2i, occ: Dictionary) -> Array:
	var trial: Array = []
	for c in orient:
		var p: Vector2i = c + off
		if occ.has(p):
			return []
		trial.append(p)
	for p in trial:
		for d in NEIGHBORS:
			if occ.has(p + d):
				return trial
	return []


## Оценка укладки: площадь описывающего прямоугольника (главное) + штраф за неквадратность.
func _score_bbox(occ: Dictionary, extra: Array) -> float:
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for c in occ:
		min_x = minf(min_x, c.x); min_y = minf(min_y, c.y)
		max_x = maxf(max_x, c.x); max_y = maxf(max_y, c.y)
	for c in extra:
		min_x = minf(min_x, c.x); min_y = minf(min_y, c.y)
		max_x = maxf(max_x, c.x); max_y = maxf(max_y, c.y)
	var w := max_x - min_x + 1.0
	var h := max_y - min_y + 1.0
	return w * h * 2.0 + absf(w - h)


# --- Геометрия пентамино ---

## Все уникальные ориентации детали (4 поворота × 2 отражения, без дублей),
## каждая нормализована к (0,0).
func _orientations(base: Array) -> Array:
	var seen := {}
	var result: Array = []
	var cur: Array = base.duplicate()
	for _refl in 2:
		for _rot in 4:
			var n := _normalize(cur)
			var key := _key(n)
			if not seen.has(key):
				seen[key] = true
				result.append(n)
			cur = _rotate(cur)
		cur = _reflect(cur)
	return result


func _rotate(cells: Array) -> Array:
	var r: Array = []
	for c in cells:
		r.append(Vector2i(-c.y, c.x))
	return r


func _reflect(cells: Array) -> Array:
	var r: Array = []
	for c in cells:
		r.append(Vector2i(-c.x, c.y))
	return r


func _normalize(cells: Array) -> Array:
	var min_x := 1 << 30
	var min_y := 1 << 30
	for c in cells:
		min_x = mini(min_x, c.x)
		min_y = mini(min_y, c.y)
	var off := Vector2i(min_x, min_y)
	var r: Array = []
	for c in cells:
		r.append(c - off)
	return r


## Стабильный ключ множества клеток (сортировка + сериализация) — для дедупа ориентаций.
func _key(cells: Array) -> String:
	var ks: Array = []
	for c in cells:
		ks.append(c.y * 100 + c.x)
	ks.sort()
	return ",".join(ks.map(func(v): return str(v)))


func _extent(cells: Array) -> Vector2i:
	var max_x := 0
	var max_y := 0
	for c in cells:
		max_x = maxi(max_x, c.x)
		max_y = maxi(max_y, c.y)
	return Vector2i(max_x + 1, max_y + 1)


func _bbox_of_keys(occ: Dictionary) -> Rect2i:
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for c in occ:
		min_x = mini(min_x, c.x); min_y = mini(min_y, c.y)
		max_x = maxi(max_x, c.x); max_y = maxi(max_y, c.y)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


# --- Фаза 4: раскладка комнат от корня (по реальным клеткам) ---

## Запас области поиска маршрута коридора вокруг занятых клеток, клеток.
const ROUTE_MARGIN := 6
## Сколько ближайших позиций пробовать на маршрутизуемость при запасном размещении.
const FALLBACK_TRIES := 28
## Маркер занятой коридором клетки в occ (комнаты ≥ 0). Комнаты на них не ставятся, но коридоры
## могут проходить по уже проложенным коридорам.
const CORR := -1

## Обходит дерево от корня. Корень — в (0,0). Каждый ребёнок ставится так, чтобы его РЕАЛЬНЫЕ
## клетки примыкали к клеткам родителя (door), и при этом НЕ касались чужих комнат — между
## комнатой и не-родителями всегда остаётся улица ≥1 клетки. Так резервируется место под
## дорожки: коридоры прокладываются по этим улицам в обход комнат и не пересекают их.
## Если примкнуть дверью негде — ребёнок ставится в ближайшее изолированное место, до которого
## существует маршрут (запасной путь), коридор прокладывается BFS. Мутирует out-комнаты
## (pos/pieces/cells/dims под выбранную ориентацию). Возвращает связи с путём по клеткам.
func _place_rooms(space: Dictionary, shapes: Dictionary) -> Array:
	var rooms: Dictionary = space.get("rooms", {})
	var root: int = space.get("root", -1)
	var corridors: Array = []
	if root == -1 or not rooms.has(root) or not shapes.has(root):
		return corridors

	var occ := {}   # Vector2i (абс. клетка) -> id комнаты
	shapes[root]["pos"] = Vector2i.ZERO
	_stamp(occ, root, Vector2i.ZERO, shapes[root]["cells"])

	var queue: Array = [root]
	while not queue.is_empty():
		var pid: int = queue.pop_front()
		var parent_cells := _abs_cells(shapes[pid])
		var children: Array = rooms[pid].get("children", []).duplicate()
		_shuffle(children)
		for cid in children:
			if not shapes.has(cid):
				continue
			corridors.append(_place_and_connect(pid, cid, shapes, occ, parent_cells))
			queue.append(cid)
	return corridors


## Ставит ребёнка и строит связь с родителем. Сперва пытается примкнуть дверью (примыкает к
## родителю, не касаясь чужих комнат). Иначе — запасное изолированное место с маршрутом-коридором.
func _place_and_connect(pid: int, cid: int, shapes: Dictionary, occ: Dictionary, parent_cells: Dictionary) -> Dictionary:
	var shape: Dictionary = shapes[cid]
	var adj = _place_adjacent(shape, occ, parent_cells)
	if adj != null:
		_apply_placement(shape, adj)
		_stamp(occ, cid, adj["pos"], adj["cells"])
		return {"from": pid, "to": cid, "adjacent": true,
			"path": _door_path(parent_cells, _abs_cells(shape)), "unrouted": false}

	var fb := _fallback_route(shape, occ, parent_cells)
	_apply_placement(shape, fb)
	_stamp(occ, cid, fb["pos"], fb["cells"])
	# Резервируем свободные клетки коридора, чтобы их не заняла комната, размещённая позже.
	for cell in fb["path"]:
		if not occ.has(cell):
			occ[cell] = CORR
	return {"from": pid, "to": cid, "adjacent": false,
		"path": fb["path"], "unrouted": fb["unrouted"]}


func _apply_placement(shape: Dictionary, p: Dictionary) -> void:
	shape["pos"] = p["pos"]
	shape["pieces"] = p["pieces"]
	shape["cells"] = p["cells"]
	shape["dims"] = p["dims"]


## Кандидаты-двери: ориентации и позиции у родителя, где клетки ребёнка граничат с родителем,
## не пересекаются и НЕ касаются чужих комнат (улица сохраняется). Случайная или null.
func _place_adjacent(shape: Dictionary, occ: Dictionary, parent_cells: Dictionary):
	var orients := _footprint_orientations(shape["pieces"])
	var pbb := _bbox_of_keys(parent_cells)
	var candidates: Array = []
	for orient in orients:
		var osz: Vector2i = orient["dims"]
		for oy in range(pbb.position.y - osz.y - 1, pbb.position.y + pbb.size.y + 2):
			for ox in range(pbb.position.x - osz.x - 1, pbb.position.x + pbb.size.x + 2):
				var off := Vector2i(ox, oy)
				if _overlaps_cells(orient["cells"], off, occ):
					continue
				if not _adjoins(orient["cells"], off, parent_cells):
					continue
				if _touches_other(orient["cells"], off, occ, parent_cells):
					continue
				candidates.append({"pos": off, "orient": orient})
	if candidates.is_empty():
		return null
	var pick: Dictionary = candidates[_rng.randi() % candidates.size()]
	var o: Dictionary = pick["orient"]
	return {"pos": pick["pos"], "pieces": o["pieces"], "cells": o["cells"], "dims": o["dims"]}


## Запасное размещение: примкнуть дверью негде. Ищем ближайшее ИЗОЛИРОВАННОЕ место (не касается
## ни одной комнаты — вокруг остаётся улица) и проверяем, что до родителя есть маршрут в обход
## комнат (BFS). Перебираем по возрастанию расстояния ⇒ берём первый маршрутизуемый = коридор
## минимальной длины. Если маршрута нет нигде — флаг unrouted (рисуется как разрыв, без пересечения).
func _fallback_route(shape: Dictionary, occ: Dictionary, parent_cells: Dictionary) -> Dictionary:
	var orients := _footprint_orientations(shape["pieces"])
	var center := _centroid(parent_cells)
	var bb := _bbox_of_keys(occ)
	var max_dim: int = maxi(int(shape["dims"].x), int(shape["dims"].y))
	var margin: int = max_dim + 3

	var cands: Array = []
	for orient in orients:
		var sz: Vector2i = orient["dims"]
		for oy in range(bb.position.y - margin, bb.position.y + bb.size.y + margin):
			for ox in range(bb.position.x - margin, bb.position.x + bb.size.x + margin):
				var off := Vector2i(ox, oy)
				if _overlaps_cells(orient["cells"], off, occ):
					continue
				if _touches_other(orient["cells"], off, occ, {}):
					continue   # полностью изолировано: вокруг улица
				var cc := Vector2(off) + Vector2(sz) * 0.5
				var d := absf(cc.x - center.x) + absf(cc.y - center.y)
				cands.append({"pos": off, "orient": orient, "d": d})
	cands.sort_custom(func(a, b): return a["d"] < b["d"])

	var tries: int = mini(cands.size(), FALLBACK_TRIES)
	for i in tries:
		var cand: Dictionary = cands[i]
		var o: Dictionary = cand["orient"]
		var child_cells := _shift_to_set(o["cells"], cand["pos"])
		var path := _route_corridor(parent_cells, child_cells, occ)
		if not path.is_empty():
			return {"pos": cand["pos"], "pieces": o["pieces"], "cells": o["cells"],
				"dims": o["dims"], "path": path, "unrouted": false}

	# Маршрута нет (родитель замурован). Ставим в ближайшее изолированное место, связь — разрыв.
	if not cands.is_empty():
		var c0: Dictionary = cands[0]
		var o0: Dictionary = c0["orient"]
		return {"pos": c0["pos"], "pieces": o0["pieces"], "cells": o0["cells"],
			"dims": o0["dims"], "path": [], "unrouted": true}
	var far := bb.position - Vector2i(0, max_dim + 2)
	return {"pos": far, "pieces": orients[0]["pieces"], "cells": orients[0]["cells"],
		"dims": orients[0]["dims"], "path": [], "unrouted": true}


## Касается ли клетка ребёнка (со смещением off) гранью какой-либо КОМНАТЫ, не входящей в allow.
## Клетки коридоров (CORR) не считаются — стоять рядом с дорожкой можно.
func _touches_other(cells: Array, off: Vector2i, occ: Dictionary, allow: Dictionary) -> bool:
	for c in cells:
		var p: Vector2i = c + off
		for d in NEIGHBORS:
			var n: Vector2i = p + d
			if _is_room(occ, n) and not allow.has(n):
				return true
	return false


## Занята ли клетка реальной комнатой (а не коридором и не пусто).
func _is_room(occ: Dictionary, cell: Vector2i) -> bool:
	return occ.has(cell) and occ[cell] != CORR


func _shift_to_set(cells: Array, off: Vector2i) -> Dictionary:
	var s := {}
	for c in cells:
		s[c + off] = true
	return s


func _stamp(occ: Dictionary, id: int, off: Vector2i, cells: Array) -> void:
	for c in cells:
		occ[c + off] = id


## Абсолютные клетки комнаты (pos + локальные клетки) как множество Vector2i -> true.
func _abs_cells(shape: Dictionary) -> Dictionary:
	var s := {}
	var off: Vector2i = shape["pos"]
	for c in shape["cells"]:
		s[c + off] = true
	return s


func _overlaps_cells(cells: Array, off: Vector2i, occ: Dictionary) -> bool:
	for c in cells:
		if occ.has(c + off):
			return true
	return false


## Граничит ли хоть одна клетка ребёнка (со смещением off) гранью с клеткой родителя.
func _adjoins(cells: Array, off: Vector2i, parent_cells: Dictionary) -> bool:
	for c in cells:
		var p: Vector2i = c + off
		for d in NEIGHBORS:
			if parent_cells.has(p + d):
				return true
	return false


func _centroid(cells_set: Dictionary) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for c in cells_set:
		sum += Vector2(c)
		n += 1
	return sum / maxf(n, 1)


## Все уникальные ориентации футпринта (4 поворота × 2 отражения, дедуп), детали остаются
## сгруппированными (для раскраски). Каждая ориентация нормализована к (0,0).
func _footprint_orientations(pieces: Array) -> Array:
	var seen := {}
	var result: Array = []
	var cur: Array = pieces
	for _refl in 2:
		for _rot in 4:
			var norm := _normalize_pieces(cur)
			var key := _key(norm["cells"])
			if not seen.has(key):
				seen[key] = true
				result.append(norm)
			cur = _rotate_pieces(cur)
		cur = _reflect_pieces(cur)
	return result


func _rotate_pieces(pieces: Array) -> Array:
	var r: Array = []
	for pc in pieces:
		r.append(_rotate(pc))
	return r


func _reflect_pieces(pieces: Array) -> Array:
	var r: Array = []
	for pc in pieces:
		r.append(_reflect(pc))
	return r


## Сдвигает все детали так, чтобы минимум объединения был в (0,0). Возвращает {pieces, cells, dims}.
func _normalize_pieces(pieces: Array) -> Dictionary:
	var min_x := 1 << 30
	var min_y := 1 << 30
	for pc in pieces:
		for c in pc:
			min_x = mini(min_x, c.x)
			min_y = mini(min_y, c.y)
	var off := Vector2i(min_x, min_y)
	var out_pieces: Array = []
	var all_cells: Array = []
	for pc in pieces:
		var np: Array = []
		for c in pc:
			var p: Vector2i = c - off
			np.append(p)
			all_cells.append(p)
		out_pieces.append(np)
	return {"pieces": out_pieces, "cells": all_cells, "dims": _extent(all_cells)}


# --- Фаза 5: дорожки (пути по центрам клеток, в обход комнат) ---

## Дверь между примкнувшими комнатами: пара граничащих клеток (родитель, ребёнок). Сама дверь
## лежит на стыке этих двух комнат и никогда не пересекает третью.
func _door_path(parent_cells: Dictionary, child_cells: Dictionary) -> Array:
	for pc in parent_cells:
		for d in NEIGHBORS:
			if child_cells.has(pc + d):
				return [pc, pc + d]
	# Подстраховка (примыкания нет — не должно случаться для adjacent): ближайшие клетки.
	return [_nearest_cell(parent_cells, _centroid(child_cells)),
		_nearest_cell(child_cells, _centroid(parent_cells))]


## Кратчайший путь-коридор от родителя к ребёнку BFS по СВОБОДНЫМ клеткам (не входящим ни в одну
## комнату): старт — свободные соседи клеток родителя, финиш — свободная клетка у ребёнка. Все
## комнаты, кроме точек входа в родителя/ребёнка, — препятствия, поэтому коридор гарантированно
## НЕ пересекает комнаты. Возвращает [клетка_родителя, свободные…, клетка_ребёнка] или [] если
## прохода нет. child_cells передаётся отдельно (ребёнок ещё не проштампован в occ).
func _route_corridor(parent_cells: Dictionary, child_cells: Dictionary, occ: Dictionary) -> Array:
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for c in occ:
		lo = lo.min(c); hi = hi.max(c)
	for c in child_cells:
		lo = lo.min(c); hi = hi.max(c)
	lo -= Vector2i(ROUTE_MARGIN, ROUTE_MARGIN)
	hi += Vector2i(ROUTE_MARGIN, ROUTE_MARGIN)

	var came := {}   # свободная клетка -> предыдущая (для первой это клетка родителя)
	var q: Array = []
	for pc in parent_cells:
		for d in NEIGHBORS:
			var n: Vector2i = pc + d
			if child_cells.has(n):
				return [pc, n]   # уже примыкают (запасной случай) — короткая дверь
			if _is_room(occ, n) or came.has(n):
				continue   # по комнатам нельзя; по коридорам/пустым — можно
			came[n] = pc
			q.append(n)

	var head := 0
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		for d in NEIGHBORS:
			var t: Vector2i = cur + d
			if child_cells.has(t):
				return _reconstruct_path(came, cur, parent_cells) + [t]
		for d in NEIGHBORS:
			var n: Vector2i = cur + d
			if came.has(n) or _is_room(occ, n) or child_cells.has(n):
				continue
			if n.x < lo.x or n.y < lo.y or n.x > hi.x or n.y > hi.y:
				continue
			came[n] = cur
			q.append(n)
	return []


## Восстанавливает цепочку [клетка_родителя, свободные…, last_free] по карте came.
func _reconstruct_path(came: Dictionary, last_free: Vector2i, parent_cells: Dictionary) -> Array:
	var chain: Array = []
	var c := last_free
	while true:
		chain.append(c)
		var prev: Vector2i = came[c]
		if parent_cells.has(prev):
			chain.append(prev)
			break
		c = prev
	chain.reverse()
	return chain


func _nearest_cell(cells_set: Dictionary, target: Vector2) -> Vector2i:
	var best := Vector2i.ZERO
	var best_d := INF
	for c in cells_set:
		var d := Vector2(c).distance_squared_to(target)
		if d < best_d:
			best_d = d
			best = c
	return best


# --- Фаза 6: подтягивание комнат к родителю ---

## Для каждой не-корневой комнаты (сверху вниз) с вероятностью pull_to_parent_chance двигаем
## её ВМЕСТЕ С ПОДДЕРЕВОМ детей в сторону родителя по свободному месту, пока не упрёмся, и
## переразводим связь с родителем. Движение жёстко-телесное: внутренние коридоры поддерева едут
## с ним, чужие комнаты и чужие коридоры — препятствия, поэтому пути не ломаются. Если после
## сдвига связь с родителем не переразводится — сдвиг откатывается.
func _pull_to_parent(space: Dictionary, shapes: Dictionary, corridors: Array) -> void:
	if pull_to_parent_chance <= 0.0:
		return
	var rooms: Dictionary = space.get("rooms", {})
	var root: int = space.get("root", -1)
	if root == -1:
		return
	var child_map := {}
	var parent_map := {}
	for id in rooms:
		var ch: Array = rooms[id].get("children", [])
		child_map[id] = ch
		for c in ch:
			parent_map[c] = id

	# Порядок сверху вниз: родитель раньше ребёнка (тогда после сдвига родителя ребёнок ещё
	# подтянется к новому положению).
	var order: Array = []
	var q: Array = [root]
	while not q.is_empty():
		var x: int = q.pop_front()
		for c in child_map.get(x, []):
			order.append(c)
			q.append(c)

	for rid in order:
		if not shapes.has(rid) or not parent_map.has(rid):
			continue
		if _rng.randf() >= pull_to_parent_chance:
			continue
		_pull_subtree(rid, shapes, child_map, parent_map, corridors)


func _pull_subtree(rid: int, shapes: Dictionary, child_map: Dictionary, parent_map: Dictionary, corridors: Array) -> void:
	# Поддерево: rid и все его потомки.
	var sub := {}
	var stack: Array = [rid]
	while not stack.is_empty():
		var x: int = stack.pop_back()
		sub[x] = true
		for c in child_map.get(x, []):
			if shapes.has(c):
				stack.push_back(c)

	var parent: int = parent_map[rid]
	if not shapes.has(parent):
		return

	# Классифицируем коридоры: внутренние поддерева (едут с ним) и граничный (parent→rid).
	var internal: Array = []
	var boundary := -1
	for i in corridors.size():
		var co: Dictionary = corridors[i]
		var f_in: bool = sub.has(co["from"])
		var t_in: bool = sub.has(co["to"])
		if f_in and t_in:
			internal.append(i)
		elif co["to"] == rid and co["from"] == parent:
			boundary = i

	# Статичные препятствия: чужие комнаты + чужие коридоры (не внутренние, не граничный).
	var static_occ := {}
	for id in shapes:
		if sub.has(id):
			continue
		for c in shapes[id]["cells"]:
			static_occ[c + shapes[id]["pos"]] = id
	for i in corridors.size():
		if i == boundary or internal.has(i):
			continue
		for cell in corridors[i]["path"]:
			if not static_occ.has(cell):
				static_occ[cell] = CORR

	# Подвижные клетки поддерева (комнаты + внутренние коридоры) — проверяем на столкновения целиком.
	var moving: Array = []
	for id in sub:
		for c in shapes[id]["cells"]:
			moving.append(c + shapes[id]["pos"])
	for i in internal:
		for cell in corridors[i]["path"]:
			moving.append(cell)

	var parent_cells := _abs_cells(shapes[parent])
	var pc := _centroid(parent_cells)

	# Жадный спуск к родителю: единичные шаги, уменьшающие манхэттен, пока не упрёмся.
	var total := Vector2i.ZERO
	while true:
		var rc := Vector2(shapes[rid]["pos"] + total) + Vector2(shapes[rid]["dims"]) * 0.5
		var diff := pc - rc
		var steps := _pull_steps(diff)
		if steps.is_empty():
			break
		var moved := false
		for st in steps:
			if not _collides(moving, total + st, static_occ):
				total += st
				moved = true
				break
		if not moved:
			break

	if total == Vector2i.ZERO:
		return

	# Проверяем, что после сдвига связь с родителем переразводится; иначе откатываем.
	var occ_full := static_occ.duplicate()
	for id in sub:
		for c in shapes[id]["cells"]:
			occ_full[c + shapes[id]["pos"] + total] = id
	for i in internal:
		for cell in corridors[i]["path"]:
			var nc: Vector2i = cell + total
			if not occ_full.has(nc):
				occ_full[nc] = CORR
	var new_child := {}
	for c in shapes[rid]["cells"]:
		new_child[c + shapes[rid]["pos"] + total] = true

	var new_conn: Dictionary
	if _sets_adjacent(parent_cells, new_child):
		new_conn = {"from": parent, "to": rid, "adjacent": true,
			"path": _door_path(parent_cells, new_child), "unrouted": false}
	else:
		var path := _route_corridor(parent_cells, new_child, occ_full)
		if path.is_empty():
			return   # переразвести не удалось — откат (сдвиг не применяем)
		new_conn = {"from": parent, "to": rid, "adjacent": false, "path": path, "unrouted": false}

	# Коммит: двигаем все комнаты поддерева и его внутренние коридоры, переписываем граничную связь.
	for id in sub:
		shapes[id]["pos"] += total
	for i in internal:
		var shifted: Array = []
		for cell in corridors[i]["path"]:
			shifted.append(cell + total)
		corridors[i]["path"] = shifted
	if boundary != -1:
		corridors[boundary] = new_conn


## Единичные шаги к цели, сначала по оси с большим зазором.
func _pull_steps(diff: Vector2) -> Array:
	var sx := signi(int(diff.x)) if absf(diff.x) >= 0.5 else 0
	var sy := signi(int(diff.y)) if absf(diff.y) >= 0.5 else 0
	var steps: Array = []
	if sx == 0 and sy == 0:
		return steps
	if absf(diff.x) >= absf(diff.y):
		if sx != 0: steps.append(Vector2i(sx, 0))
		if sy != 0: steps.append(Vector2i(0, sy))
	else:
		if sy != 0: steps.append(Vector2i(0, sy))
		if sx != 0: steps.append(Vector2i(sx, 0))
	return steps


func _collides(moving: Array, delta: Vector2i, static_occ: Dictionary) -> bool:
	for c in moving:
		if static_occ.has(c + delta):
			return true
	return false


func _sets_adjacent(a: Dictionary, b: Dictionary) -> bool:
	for c in a:
		for d in NEIGHBORS:
			if b.has(c + d):
				return true
	return false


# --- Фаза 7: внутренние маршруты движения сквозь комнаты ---

## Для каждой комнаты считает маршрут движения по её клеткам и кладёт в shapes[id]["route"]
## (массив абсолютных клеток). Вход комнаты — её клетка на связи от родителя; выходы — её клетки
## на связях к детям. Проходная: маршрут вход→все выходы. Лист: петля вход→вход. Целевая длина
## раздувается множителями (избыточность/тупик/пентамино), затем прокладывается реальный путь.
func _compute_routes(_space: Dictionary, shapes: Dictionary, corridors: Array) -> void:
	var in_door := {}
	var out_doors := {}
	for id in shapes:
		out_doors[id] = []
	for corr in corridors:
		var path: Array = corr.get("path", [])
		if path.is_empty():
			continue
		var f: int = corr["from"]
		var t: int = corr["to"]
		if shapes.has(f):
			out_doors[f].append(path[0])              # клетка родителя на связи
		if shapes.has(t):
			in_door[t] = path[path.size() - 1]        # клетка ребёнка на связи

	for id in shapes:
		var allowed := _abs_cells(shapes[id])
		var outs: Array = out_doors[id]
		# Вход = клетка комнаты на связи от родителя. У корня родителя нет — берём центр комнаты,
		# чтобы пути строились ко ВСЕМ детям (а не теряли одного из выходов, ставшего входом).
		var entry: Vector2i
		if in_door.has(id):
			entry = in_door[id]
		else:
			entry = _nearest_cell(allowed, _centroid(allowed))
		var is_pent: bool = shapes[id]["shape_kind"] == "pentomino"
		var pent_count: int = shapes[id]["pieces"].size()
		shapes[id]["routes"] = _build_room_routes(entry, outs, allowed, is_pent, pent_count)


## Маршруты движения внутри комнаты — СПИСОК путей (каждый — несамопересекающийся).
## Проходная (есть дети): N путей, по одному из входа (от родителя) к каждому выходу (к ребёнку);
## пути к разным детям независимы (не следят друг за другом). Лист (нет детей): один путь-петля
## вход→…→вход с избыточностью ×deadend. Длина каждого пути ≈ реальная × base_excess × пентамино.
func _build_room_routes(entry: Vector2i, outs: Array, allowed: Dictionary, is_pent: bool, pent_count: int) -> Array:
	var pent_factor := 1.0
	if is_pent:
		pent_factor = maxf(1.0, pent_count * route_pentomino_mult)

	if outs.is_empty():
		var ecc := _eccentricity(entry, allowed)
		var leaf_real := maxf(2.0 * ecc, 2.0)
		var leaf_target := int(round(leaf_real * route_base_excess * route_deadend_mult * pent_factor))
		return [_simple_cycle(entry, allowed, leaf_target)]

	var routes: Array = []
	for o in outs:
		if o == entry:
			continue   # вырожденный путь (дверь совпала со входом)
		var real := maxi(_bfs_dist(entry, o, allowed), 1)
		var target := int(round(real * route_base_excess * pent_factor))
		routes.append(_simple_path(entry, o, allowed, target))
	if routes.is_empty():
		routes.append([entry])
	return routes


## Один простой (несамопересекающийся) путь start→goal по клеткам комнаты длиной как можно ближе к
## target. «Верёвка»: натянутая = кратчайший путь; с ростом target извивается по комнате, не пересекая
## себя, вплоть до заполнения комнаты (предел длины = площадь комнаты). Рандомизированный DFS с
## отсечением ходов, после которых goal становится недостижимой; иначе — кратчайший BFS-путь.
func _simple_path(start: Vector2i, goal: Vector2i, allowed: Dictionary, target: int) -> Array:
	if start == goal:
		return [start]
	var best := {"path": [], "score": 1 << 30}
	var path: Array = [start]
	var visited := {start: true}
	var budget := [ROUTE_BUDGET]
	_dfs_simple(start, goal, allowed, target, path, visited, best, budget)
	if best["path"].is_empty():
		var bp := _bfs_path(start, goal, allowed, {})
		best["path"] = bp if not bp.is_empty() else [start, goal]
	return best["path"]


func _dfs_simple(cur: Vector2i, goal: Vector2i, allowed: Dictionary, target: int, path: Array, visited: Dictionary, best: Dictionary, budget: Array) -> void:
	budget[0] -= 1
	if budget[0] <= 0:
		return
	if cur == goal:
		var length := path.size() - 1
		var score: int = absi(length - target)
		if score < best["score"] or (score == best["score"] and length > best["path"].size() - 1):
			best["score"] = score
			best["path"] = path.duplicate()
		return
	# К цели идём, только набрав длину (или если больше некуда) — верёвка сперва извивается.
	var nongoal: Array = []
	var goal_adj := false
	for d in NEIGHBORS:
		var n: Vector2i = cur + d
		if not allowed.has(n) or visited.has(n):
			continue
		if n == goal:
			goal_adj = true
		else:
			nongoal.append(n)
	_shuffle(nongoal)
	var delay_goal := (path.size() - 1) < (target - 1)
	var order: Array = []
	if goal_adj and not delay_goal:
		order.append(goal)
	order.append_array(nongoal)
	if goal_adj and delay_goal:
		order.append(goal)
	for n in order:
		visited[n] = true
		if n == goal or _reachable(n, goal, allowed, visited):
			path.append(n)
			_dfs_simple(n, goal, allowed, target, path, visited, best, budget)
			path.pop_back()
		visited.erase(n)
		if best["score"] == 0:
			return


## Простой ЦИКЛ из start длиной ≈ target (для листьев): DFS без повторов, замыкаем, когда вернулись
## к соседу start. Несамопересекающаяся петля; предел длины — гамильтонов цикл по клеткам комнаты.
func _simple_cycle(start: Vector2i, allowed: Dictionary, target: int) -> Array:
	var best := {"path": [], "score": 1 << 30}
	var path: Array = [start]
	var visited := {start: true}
	var budget := [ROUTE_BUDGET]
	_dfs_cycle(start, start, allowed, target, path, visited, best, budget)
	if best["path"].is_empty():
		# Запасной вариант: простой путь до самой дальней клетки (без петли, но без пересечений).
		best["path"] = _bfs_path(start, _farthest(start, allowed), allowed, {})
		if best["path"].is_empty():
			best["path"] = [start]
	return best["path"]


func _dfs_cycle(cur: Vector2i, start: Vector2i, allowed: Dictionary, target: int, path: Array, visited: Dictionary, best: Dictionary, budget: Array) -> void:
	budget[0] -= 1
	if budget[0] <= 0:
		return
	if path.size() - 1 >= 2 and _adjacent(cur, start):
		var length := path.size()   # замыкание добавит start ⇒ длина в рёбрах = path.size()
		var score: int = absi(length - target)
		if score < best["score"] or (score == best["score"] and length > best["path"].size() - 1):
			best["score"] = score
			var closed := path.duplicate()
			closed.append(start)
			best["path"] = closed
	var nbrs: Array = []
	for d in NEIGHBORS:
		var n: Vector2i = cur + d
		if allowed.has(n) and not visited.has(n):
			nbrs.append(n)
	_shuffle(nbrs)
	for n in nbrs:
		visited[n] = true
		if _reachable(n, start, allowed, visited):   # можно ли ещё вернуться к старту
			path.append(n)
			_dfs_cycle(n, start, allowed, target, path, visited, best, budget)
			path.pop_back()
		visited.erase(n)
		if best["score"] == 0:
			return


## Достижима ли goal из from по клеткам allowed, не входящим в visited (goal — исключение).
## Отсекает ходы, после которых цель «замуровывается» оставшимся путём.
func _reachable(from: Vector2i, goal: Vector2i, allowed: Dictionary, visited: Dictionary) -> bool:
	if from == goal:
		return true
	var seen := {from: true}
	var q: Array = [from]
	var head := 0
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		for d in NEIGHBORS:
			var n: Vector2i = c + d
			if seen.has(n) or not allowed.has(n):
				continue
			if n == goal:
				return true
			if visited.has(n):
				continue
			seen[n] = true
			q.append(n)
	return false


func _adjacent(a: Vector2i, b: Vector2i) -> bool:
	var diff := a - b
	return absi(diff.x) + absi(diff.y) == 1


func _bfs_path(start: Vector2i, goal: Vector2i, allowed: Dictionary, blocked: Dictionary) -> Array:
	if start == goal:
		return [start]
	var came := {start: start}
	var q: Array = [start]
	var head := 0
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		if cur == goal:
			break
		for d in NEIGHBORS:
			var n: Vector2i = cur + d
			if came.has(n) or not allowed.has(n):
				continue
			if blocked.has(n) and n != goal:
				continue
			came[n] = cur
			q.append(n)
	if not came.has(goal):
		return []
	var path: Array = []
	var c := goal
	while c != start:
		path.append(c)
		c = came[c]
	path.append(start)
	path.reverse()
	return path


func _bfs_dist(start: Vector2i, goal: Vector2i, allowed: Dictionary) -> int:
	var p := _bfs_path(start, goal, allowed, {})
	return p.size() - 1 if not p.is_empty() else 0


func _farthest(start: Vector2i, allowed: Dictionary) -> Vector2i:
	var dist := {start: 0}
	var q: Array = [start]
	var head := 0
	var best := start
	var bd := 0
	while head < q.size():
		var cur: Vector2i = q[head]
		head += 1
		for d in NEIGHBORS:
			var n: Vector2i = cur + d
			if dist.has(n) or not allowed.has(n):
				continue
			dist[n] = int(dist[cur]) + 1
			q.append(n)
			if dist[n] > bd:
				bd = dist[n]
				best = n
	return best


func _eccentricity(start: Vector2i, allowed: Dictionary) -> int:
	return _bfs_dist(start, _farthest(start, allowed), allowed)


# --- Фаза 8: виртуальные стены у внутренних маршрутов ---

## Виртуальные стены — стороны клеток маршрута, которые оказываются слева от обходчика при обходе
## дорожек туда-обратно и не ведут в другую дорожку или дверной проём. Это только debug-данные:
## фактический layout, двери, стены и слоты объектов от этого поля не меняются.
func _compute_virtual_walls(shapes: Dictionary, corridors: Array) -> void:
	var door_edges := {}
	for id in shapes:
		door_edges[id] = {}
	for corr in corridors:
		var path: Array = corr.get("path", [])
		if path.size() < 2:
			continue
		var f: int = corr.get("from", -1)
		var t: int = corr.get("to", -1)
		if shapes.has(f):
			var d_from: Vector2i = path[1] - path[0]
			if _is_unit(d_from):
				door_edges[f][_edge_key(path[0], d_from)] = true
		if shapes.has(t):
			var last: int = path.size() - 1
			var d_to: Vector2i = path[last - 1] - path[last]
			if _is_unit(d_to):
				door_edges[t][_edge_key(path[last], d_to)] = true

	for id in shapes:
		var route_set := {}
		for route in shapes[id].get("routes", []):
			for c in route:
				route_set[c] = true
		var wall_set := {}
		var walls: Array = []
		for route in shapes[id].get("routes", []):
			if _route_closed(route):
				var forward: Array = _collect_virtual_route(route, route_set, door_edges.get(id, {}))
				var back: Array = route.duplicate()
				back.reverse()
				var backward: Array = _collect_virtual_route(back, route_set, door_edges.get(id, {}))
				_append_virtual_walls(forward if forward.size() >= backward.size() else backward, wall_set, walls)
			else:
				_mark_virtual_route(route, route_set, door_edges.get(id, {}), wall_set, walls)
				var back: Array = route.duplicate()
				back.reverse()
				_mark_virtual_route(back, route_set, door_edges.get(id, {}), wall_set, walls)
		shapes[id]["virtual_walls"] = walls


func _collect_virtual_route(route: Array, route_set: Dictionary, door_edges: Dictionary) -> Array:
	var wall_set := {}
	var walls: Array = []
	_mark_virtual_route(route, route_set, door_edges, wall_set, walls)
	return walls


func _append_virtual_walls(source: Array, wall_set: Dictionary, walls: Array) -> void:
	for wall in source:
		var cell: Vector2i = wall["cell"]
		var dir: Vector2i = wall["dir"]
		var key := _edge_key(cell, dir)
		if wall_set.has(key):
			continue
		wall_set[key] = true
		walls.append(wall)


func _mark_virtual_route(route: Array, route_set: Dictionary, door_edges: Dictionary, wall_set: Dictionary, walls: Array) -> void:
	if route.size() < 2:
		return
	for i in range(route.size() - 1):
		var a: Vector2i = route[i]
		var b: Vector2i = route[i + 1]
		var d: Vector2i = b - a
		if not _is_unit(d):
			continue
		var left := Vector2i(d.y, -d.x)
		_add_virtual_wall(a, left, route_set, door_edges, wall_set, walls)
		_add_virtual_wall(b, left, route_set, door_edges, wall_set, walls)


func _add_virtual_wall(cell: Vector2i, dir: Vector2i, route_set: Dictionary, door_edges: Dictionary, wall_set: Dictionary, walls: Array) -> void:
	if route_set.has(cell + dir):
		return
	if door_edges.has(_edge_key(cell, dir)):
		return
	var key := _edge_key(cell, dir)
	if wall_set.has(key):
		return
	wall_set[key] = true
	walls.append({"cell": cell, "dir": dir})


func _route_closed(route: Array) -> bool:
	return route.size() > 2 and route[0] == route[route.size() - 1]


func _is_unit(d: Vector2i) -> bool:
	return absi(d.x) + absi(d.y) == 1


func _edge_key(cell: Vector2i, d: Vector2i) -> String:
	return "%d,%d:%d,%d" % [cell.x, cell.y, d.x, d.y]


# --- Утилиты ---

func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi() % (i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## 12 свободных пентамино (буквенные имена), каждый — нормализованный набор из 5 клеток.
func _build_pentominoes() -> Array:
	return [
		[Vector2i(1,0),Vector2i(2,0),Vector2i(0,1),Vector2i(1,1),Vector2i(1,2)],  # F
		[Vector2i(0,0),Vector2i(0,1),Vector2i(0,2),Vector2i(0,3),Vector2i(0,4)],  # I
		[Vector2i(0,0),Vector2i(0,1),Vector2i(0,2),Vector2i(0,3),Vector2i(1,3)],  # L
		[Vector2i(0,0),Vector2i(0,1),Vector2i(1,1),Vector2i(1,2),Vector2i(1,3)],  # N
		[Vector2i(0,0),Vector2i(1,0),Vector2i(0,1),Vector2i(1,1),Vector2i(0,2)],  # P
		[Vector2i(0,0),Vector2i(1,0),Vector2i(2,0),Vector2i(1,1),Vector2i(1,2)],  # T
		[Vector2i(0,0),Vector2i(2,0),Vector2i(0,1),Vector2i(1,1),Vector2i(2,1)],  # U
		[Vector2i(0,0),Vector2i(0,1),Vector2i(0,2),Vector2i(1,2),Vector2i(2,2)],  # V
		[Vector2i(0,0),Vector2i(0,1),Vector2i(1,1),Vector2i(1,2),Vector2i(2,2)],  # W
		[Vector2i(1,0),Vector2i(0,1),Vector2i(1,1),Vector2i(2,1),Vector2i(1,2)],  # X
		[Vector2i(1,0),Vector2i(0,1),Vector2i(1,1),Vector2i(1,2),Vector2i(1,3)],  # Y
		[Vector2i(0,0),Vector2i(1,0),Vector2i(1,1),Vector2i(1,2),Vector2i(2,2)],  # Z
	]
