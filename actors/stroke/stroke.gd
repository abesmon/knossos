class_name StrokeActor
extends Node3D

## Эктор-штрих: материализация эфемерного объекта kind="stroke" (рисунок карандаша). Строит ОДИН
## меш (тонкую трубу вдоль полилинии) в единственный MeshInstance3D — цель «минимум мешей»: один
## draw-call на штрих, без физ-коллайдеров. Точки в props — мировые координаты (parent="" корень),
## поэтому узел стоит в начале координат, а вершины абсолютны. См. docs/pencil-tool.md.
##
## Два пути использования:
##  • Канонический — EphemeralView инстанцирует из записи журнала и зовёт setup_object(object).
##  • Превью/локальный — DrawingTool сам инстанцирует, рисует по ходу ведения append_point() и
##    (офлайн) финализирует setup_object с готовым props.
##
## Состоит в группе "ephemeral_stroke" — по ней ластик находит штрихи для хит-теста (hit_by).

const GROUP := "ephemeral_stroke"
## Граней в поперечнике трубы: 4 — дёшево и достаточно «объёмно» с любого угла.
const SIDES := 4
const DEFAULT_WIDTH := 0.02

## id записи в журнале ("" — локальный офлайн-штрих, удаляется напрямую, без сети) и автор
## (для решения ластика «моё/чужое»).
var object_id: String = ""
var author: String = ""

var _radius: float = DEFAULT_WIDTH * 0.5
var _points: Array[Vector3] = []     # текущие вершины (мировые) — для превью-достройки и хит-теста
var _mat: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	add_to_group(GROUP)
	if _mat == null:
		_setup_material(Color(1, 1, 1))


## Контракт EphemeralView: принять плоский объект { id, author, props:{points,color,width} } и
## построить меш. Зовётся при создании и (редко, при finalize-on-release) при update/ресинке.
func setup_object(object: Dictionary) -> void:
	object_id = str(object.get("id", object_id))
	author = str(object.get("author", author))
	var props: Dictionary = object.get("props", {})
	_radius = maxf(0.002, float(props.get("width", DEFAULT_WIDTH))) * 0.5
	_setup_material(_color_from(props.get("color", [1, 1, 1])))
	_points = _vec_array(StrokePath.flat_to_points(props.get("points", [])))
	_rebuild()


# --- Превью/локальный режим (DrawingTool) ---

## Начать живой штрих: задать цвет/толщину и очистить точки. Дальше — append_point по ходу ведения.
func begin_preview(color: Color, width: float) -> void:
	_radius = maxf(0.002, width) * 0.5
	_setup_material(color)
	_points.clear()
	_rebuild()


## Достроить превью одной точкой и перерисовать меш (≤MAX_POINTS точек — дёшево).
func append_point(p: Vector3) -> void:
	_points.append(p)
	_rebuild()


# --- Хит-тест ластика ---

## Пересекает ли сфера радиуса radius в точке point этот штрих (по полилинии с учётом толщины).
func hit_by(point: Vector3, radius: float) -> bool:
	if _points.size() < 2:
		return false
	var flat: Array = []
	for v in _points:
		flat.append(v.x); flat.append(v.y); flat.append(v.z)
	return StrokePath.distance_to_polyline(flat, point) <= _radius + radius


# --- Построение меша ---

func _setup_material(color: Color) -> void:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.albedo_color = color
	if _mesh != null:
		_mesh.material_override = _mat


## Перестроить меш-трубу из текущих _points в единственный ImmediateMesh.
func _rebuild() -> void:
	if _mesh == null:
		return
	var im := ImmediateMesh.new()
	if _points.size() >= 2:
		_emit_tube(im, _points, _radius)
	_mesh.mesh = im
	_mesh.material_override = _mat


## Труба с параллельным переносом рамки (без закрутки) вдоль полилинии: на каждой точке — кольцо из
## SIDES вершин, соседние кольца сшиваются четырёхугольниками (по два треугольника). Концы открыты.
func _emit_tube(im: ImmediateMesh, pts: Array, r: float) -> void:
	var rings: Array = []          # Array[Array[Vector3]]
	var normal := Vector3.ZERO
	for i in pts.size():
		var tangent := _tangent(pts, i)
		if normal == Vector3.ZERO:
			normal = _initial_normal(tangent)
		else:
			# Параллельный перенос: проекция прежней нормали на плоскость, перпендикулярную касательной.
			normal = (normal - tangent * tangent.dot(normal))
			if normal.length() < 0.001:
				normal = _initial_normal(tangent)
			else:
				normal = normal.normalized()
		var binormal := tangent.cross(normal).normalized()
		var ring: Array = []
		for k in SIDES:
			var a := TAU * float(k) / float(SIDES)
			ring.append(pts[i] + (normal * cos(a) + binormal * sin(a)) * r)
		rings.append(ring)

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings.size() - 1):
		var a: Array = rings[i]
		var b: Array = rings[i + 1]
		for k in SIDES:
			var k2 := (k + 1) % SIDES
			# Четырёхугольник a[k]-a[k2]-b[k2]-b[k] → два треугольника.
			im.surface_add_vertex(a[k]);  im.surface_add_vertex(a[k2]); im.surface_add_vertex(b[k2])
			im.surface_add_vertex(a[k]);  im.surface_add_vertex(b[k2]); im.surface_add_vertex(b[k])
	im.surface_end()


## Касательная в точке i полилинии (усреднение соседних направлений на изломах).
func _tangent(pts: Array, i: int) -> Vector3:
	var last := pts.size() - 1
	var t := Vector3.ZERO
	if i > 0:
		t += (pts[i] - pts[i - 1])
	if i < last:
		t += (pts[i + 1] - pts[i])
	return t.normalized() if t.length() > 0.0001 else Vector3.FORWARD


## Стартовая нормаль, гарантированно не коллинеарная касательной.
func _initial_normal(tangent: Vector3) -> Vector3:
	var up := Vector3.UP
	if absf(tangent.dot(up)) > 0.99:
		up = Vector3.RIGHT
	return (up - tangent * tangent.dot(up)).normalized()


func _color_from(arr) -> Color:
	if typeof(arr) == TYPE_ARRAY and (arr as Array).size() >= 3:
		return Color(float(arr[0]), float(arr[1]), float(arr[2]))
	return Color(1, 1, 1)


## Array -> типизированный Array[Vector3] (flat_to_points возвращает нетипизированный).
func _vec_array(arr) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for v in arr:
		out.append(v)
	return out
