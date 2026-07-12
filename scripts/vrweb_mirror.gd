class_name VrwebMirror
extends MeshInstance3D

## Зеркало в духе VRChat (VRC_MirrorReflection): плоскость, которая в реальном времени
## показывает отражение сцены. Размещается кастомным VRWeb-тегом <VRWebMirror> (см.
## scripts/vrweb_builder.gd и docs/vrweb-tags.md).
##
## Техника — планарное отражение (работает и в GL Compatibility, в отличие от
## ReflectionProbe): отдельная камера в SubViewport ставится в зеркальное отражение
## активной камеры игрока относительно плоскости зеркала и каждый кадр перерисовывает
## мир. Её кадр натягивается на плоскость шейдером по экранным координатам (SCREEN_UV),
## поэтому отражение совпадает пиксель-в-пиксель с тем, где зеркало видно на экране.
##
## Плоскость лежит в локальной XY (как QuadMesh), отражающая сторона смотрит по +Z.
## Чтобы поставить зеркало — задайте transform узла (origin + поворот). Размер задаётся
## атрибутом size="ширина:высота" в метрах.

## Слой видимости только для зеркал. Камера отражения его НЕ снимает — так зеркало не
## отражает само себя (и другие зеркала), без бесконечной обратной связи. Основная камера
## (маска по умолчанию = все слои) зеркало по-прежнему видит.
const MIRROR_LAYER := 20  # 1..20; бит (MIRROR_LAYER-1)

## Размер плоскости в метрах (ширина × высота). Меняется через setup() из <VRWebMirror size>.
var width: float = 1.0
var height: float = 2.0
## Множитель разрешения текстуры отражения (1.0 — как экран; меньше — быстрее, мутнее).
var resolution_scale: float = 1.0
## Сила декода sRGB→linear для кадра отражения (0 — светлее, 1 — темнее). Калибровка яркости
## зеркала под Compatibility-рендерер; см. resources/mirror_reflection.gdshader.
var srgb_decode: float = 0.5

@onready var _sub_viewport: SubViewport = $ReflectionViewport
@onready var _refl_cam: Camera3D = $ReflectionViewport/ReflectionCamera
@onready var _material: ShaderMaterial = material_override


## Параметры из тега. Зовётся билдером до добавления в дерево (до _ready).
func setup(p_width: float, p_height: float, p_resolution_scale: float = 1.0,
		p_srgb_decode: float = 0.5) -> void:
	width = max(p_width, 0.01)
	height = max(p_height, 0.01)
	resolution_scale = clamp(p_resolution_scale, 0.1, 1.0)
	srgb_decode = clamp(p_srgb_decode, 0.0, 1.0)


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(width, height)
	mesh = quad

	# Зеркало живёт только на своём слое, чтобы камера отражения его не снимала.
	layers = 1 << (MIRROR_LAYER - 1)

	_material.set_shader_parameter("srgb_decode", srgb_decode)
	# Камера отражения не снимает слой зеркал — иначе зеркало отразило бы само себя.
	_refl_cam.cull_mask = 0xFFFFF & ~(1 << (MIRROR_LAYER - 1))

	_material.set_shader_parameter("reflection_tex", _sub_viewport.get_texture())
	set_process(true)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _refl_cam == null:
		return

	# Разрешение текстуры отражения держим равным экрану (× resolution_scale), иначе
	# сэмплирование по SCREEN_UV не совпадёт по пропорциям.
	var screen_size := get_viewport().get_visible_rect().size
	var target_size := Vector2i(maxi(int(screen_size.x * resolution_scale), 1),
								 maxi(int(screen_size.y * resolution_scale), 1))
	if _sub_viewport.size != target_size:
		_sub_viewport.size = target_size

	# Камера отражения повторяет проекцию основной (fov/near/far/окружение), чтобы кадр
	# совпал с экраном.
	_refl_cam.fov = cam.fov
	_refl_cam.near = cam.near
	_refl_cam.far = cam.far
	_refl_cam.keep_aspect = cam.keep_aspect
	_refl_cam.environment = cam.environment
	_refl_cam.attributes = cam.attributes

	# Плоскость зеркала в мировых координатах: точка p0 + нормаль n (локальный +Z).
	var p0 := global_position
	var n := global_transform.basis.z.normalized()

	var ct := cam.global_transform
	var eye := ct.origin
	var forward := -ct.basis.z
	var up := ct.basis.y

	# Отражение точки и направления относительно плоскости (p0, n).
	var r_eye := eye - 2.0 * (eye - p0).dot(n) * n
	var ahead := eye + forward
	var r_ahead := ahead - 2.0 * (ahead - p0).dot(n) * n
	var r_up := up - 2.0 * up.dot(n) * n

	# look_at строит правосторонний базис, поэтому кадр выходит зеркально-перевёрнутым
	# по горизонтали — это и есть отражение; шейдер компенсирует флипом X (flip_x=true).
	# Зато винтинг треугольников сохраняется (нет проблем с отсечением граней).
	_refl_cam.look_at_from_position(r_eye, r_ahead, r_up)
