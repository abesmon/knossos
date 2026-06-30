class_name StrokePath
extends RefCounted

## Чистый слой данных/геометрии штриха карандаша (engine-agnostic, как SceneChanges): накапливает
## сэмплы пути, прореживает их на лету, упрощает (Douglas–Peucker) и сериализует в плоский props
## для эфемерного объекта kind="stroke". НЕ знает про сеть и 3D-ноды — оперирует точками (Vector3
## как математический примитив) и на выходе даёт ПЛОСКИЙ массив float, чтобы сериализованную форму
## мог реализовать и не-Godot слой. Полное описание инструмента — в docs/pencil-tool.md, протокол
## объекта — в docs/ephemeral-changes.md.
##
## Жизненный цикл: инструмент кормит точки add_sample() во время ведения ЛКМ; при отпускании зовёт
## simplify() и build_props() — готовый props уходит в op=add одним объектом (финализация при
## отпускании, см. docs/pencil-tool.md).

## Минимальный сдвиг между соседними сэмплами (м): ближе — точка не добавляется (прореживание на
## лету, чтобы дрожание мыши на месте не плодило точки).
const MIN_SAMPLE_DIST := 0.03
## Допуск упрощения Douglas–Peucker (м): почти-коллинеарные точки выкидываются — меньше вершин меша
## и байт в сети.
const SIMPLIFY_EPS := 0.02
## Потолок числа точек: штрих и так ограничен MAX_PROPS_BYTES в SceneChanges (~8 КБ), но режем явно,
## чтобы длинная линия не упёрлась в отказ коммита уже после рисования.
const MAX_POINTS := 256

var _points: Array[Vector3] = []   # накопленный путь (мировые координаты)


## Добавить сэмпл, если он достаточно далеко от предыдущего (или это первая точка) и не достигнут
## потолок. Возвращает true, если точка реально добавилась — вызывающий перерисует превью.
func add_sample(p: Vector3) -> bool:
	if _points.size() >= MAX_POINTS:
		return false
	if not _points.is_empty() and _points[_points.size() - 1].distance_to(p) < MIN_SAMPLE_DIST:
		return false
	_points.append(p)
	return true


## Упростить путь Douglas–Peucker'ом: выкинуть точки, отстоящие от хорды меньше чем на eps.
## Зовётся один раз при завершении штриха (перед отправкой).
func simplify(eps: float = SIMPLIFY_EPS) -> void:
	if _points.size() <= 2:
		return
	var keep := _rdp(_points, 0, _points.size() - 1, eps)
	keep.sort()
	var out: Array[Vector3] = []
	var prev := -1
	for i in keep:   # _rdp может вернуть один индекс дважды (узлы рекурсии) — дедупим по возрастанию
		if i != prev:
			out.append(_points[i])
			prev = i
	_points = out


func point_count() -> int:
	return _points.size()


## Достаточно ли точек, чтобы это был рисуемый штрих (минимум отрезок).
func is_drawable() -> bool:
	return _points.size() >= 2


## Последняя точка пути ({} нет — Vector3.ZERO; вызывающий проверяет point_count).
func last_point() -> Vector3:
	return _points[_points.size() - 1] if not _points.is_empty() else Vector3.ZERO


## Точки как ПЛОСКИЙ массив float [x0,y0,z0, x1,y1,z1, …] — компактная JSON-сериализуемая форма.
func to_flat() -> Array:
	var out: Array = []
	for p in _points:
		out.append(p.x)
		out.append(p.y)
		out.append(p.z)
	return out


## Готовый props для op=add: { points:[…], color:[r,g,b], width }. Всё JSON-сериализуемо.
func build_props(color: Color, width: float) -> Dictionary:
	return {
		"points": to_flat(),
		"color": [color.r, color.g, color.b],
		"width": width,
	}


# --- Статические хелперы разбора (для StrokeActor и ластика) ---

## Плоский [x,y,z,…] -> массив точек Vector3. Хвост неполной тройки игнорируется.
static func flat_to_points(flat) -> Array:
	var out: Array = []
	if typeof(flat) != TYPE_ARRAY:
		return out
	var n := (flat as Array).size()
	var i := 0
	while i + 2 < n:
		out.append(Vector3(float(flat[i]), float(flat[i + 1]), float(flat[i + 2])))
		i += 3
	return out


## Минимальное расстояние от точки p до полилинии (по всем отрезкам). Для хит-теста ластика.
## INF, если точек меньше двух (нечего пересекать).
static func distance_to_polyline(flat, p: Vector3) -> float:
	var pts := flat_to_points(flat)
	if pts.size() < 2:
		return INF
	var best := INF
	for i in range(pts.size() - 1):
		best = minf(best, _dist_point_segment(p, pts[i], pts[i + 1]))
	return best


## Расстояние от точки до отрезка [a,b].
static func _dist_point_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- Douglas–Peucker (рекурсивно собирает индексы оставляемых точек) ---

static func _rdp(pts: Array, first: int, last: int, eps: float) -> Array:
	var keep := [first, last]
	if last <= first + 1:
		return keep
	var a: Vector3 = pts[first]
	var b: Vector3 = pts[last]
	var dmax := 0.0
	var index := -1
	for i in range(first + 1, last):
		var d := _dist_point_segment(pts[i], a, b)
		if d > dmax:
			dmax = d
			index = i
	if dmax > eps and index != -1:
		keep.append_array(_rdp(pts, first, index, eps))
		keep.append_array(_rdp(pts, index, last, eps))
	return keep
