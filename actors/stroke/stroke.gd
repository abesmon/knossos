class_name StrokeActor
extends Node3D

## Эктор-штрих: материализация специального VRWML-тега <VRWebStroke> (рисунок карандаша). Строит ОДИН
## меш (тонкую трубу вдоль полилинии) в единственный MeshInstance3D — цель «минимум мешей»: один
## draw-call на штрих, без физ-коллайдеров. Точки в attrs — мировые координаты (parent="" корень),
## поэтому узел стоит в начале координат, а вершины абсолютны. См. docs/client/pencil-tool.md.
##
## Канонический путь — VrwebBuilder создаёт актор из attrs универсального vrweb-node. Публичные
## свойства ниже принимают как разобранные VRWML-литералы, так и компактные строки чисел.
##
## Состоит в группе "ephemeral_stroke" для диагностики и тестов материализации.

const GROUP := "ephemeral_stroke"
## Граней в поперечнике трубы: 4 — дёшево и достаточно «объёмно» с любого угла.
const SIDES := 4
const DEFAULT_WIDTH := 0.02

var points = []:
	set(value):
		points = value
		_points = _vec_array(StrokePath.flat_to_points(_flat_value(value)))
		_rebuild()

var color = Color.WHITE:
	set(value):
		color = _color_from(value)
		_setup_material(color)

var width = DEFAULT_WIDTH:
	set(value):
		width = maxf(0.002, float(value))
		_radius = width * 0.5
		_rebuild()

var _radius: float = DEFAULT_WIDTH * 0.5
var _points: Array[Vector3] = []     # текущие вершины в мировых координатах
var _mat: StandardMaterial3D

@onready var _mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	add_to_group(GROUP)
	_setup_material(_color_from(color))
	_radius = maxf(0.002, float(width)) * 0.5
	_points = _vec_array(StrokePath.flat_to_points(_flat_value(points)))
	_rebuild()

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
	if arr is Color:
		return arr
	if arr is String:
		arr = _flat_value(arr)
	if typeof(arr) == TYPE_ARRAY and (arr as Array).size() >= 3:
		return Color(float(arr[0]), float(arr[1]), float(arr[2]))
	return Color(1, 1, 1)


func _flat_value(value) -> Array:
	if value is Array:
		return value
	var out: Array = []
	for token in str(value).split(" ", false):
		if token.is_valid_float():
			out.append(token.to_float())
	return out


## Array -> типизированный Array[Vector3] (flat_to_points возвращает нетипизированный).
func _vec_array(arr) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for v in arr:
		out.append(v)
	return out
