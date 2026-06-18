class_name ImagePanel
extends StaticBody3D

## Эктор-картинка: 3D-квад с реальной текстурой страницы. До загрузки показывает
## заглушку «🖼 alt»; текстура подтягивается прогрессивно через ImageLoader уже после
## сборки мира и заменяет заглушку, подгоняя пропорции квада под пропорции картинки.
##
## Картинка может быть и ссылкой (`<a><img></a>`): тогда несёт Transition и кликается
## лучом игрока так же, как Portal/RichPanel — через общий интерфейс interact_at.

signal link_activated(transition: Dictionary)

const GROUP := "image_panel"
const BASE_WIDTH := 2.6        # запасная ширина квада, если мир не задал свою, м
const MAX_WIDTH := 6.3         # потолок ширины (~0.7 комнаты), чтобы не перекрывать стены
const MAX_HEIGHT := 3.0        # потолок высоты, чтобы вытянутые картинки не пробивали стены
const DEFAULT_RATIO := 0.66    # стартовые пропорции заглушки до загрузки
const EYE_LEVEL := 1.6         # высота центра картинки, м (= высота камеры игрока)
const FLOOR_GAP := 0.1         # минимальный зазор от низа высокой картинки до пола, м

var _alt: String = ""
var _transition = null
# Желаемые размеры из HTML (метры, 0 = не заданы) и запасная ширина — их задаёт мир,
# переводя width/height страницы в метры общим масштабом. См. WorldGenerator._build_image_panel.
var _want_w := 0.0
var _want_h := 0.0
var _fallback_w := BASE_WIDTH

var _mesh: MeshInstance3D
var _quad: QuadMesh
var _mat: StandardMaterial3D
var _label: Label3D
var _collision: CollisionShape3D
var _shape: BoxShape3D
var _height_m := BASE_WIDTH * DEFAULT_RATIO


## Вызывается ДО add_child. transition (если есть) делает картинку кликабельной ссылкой.
## want_w/want_h — размеры из HTML в метрах (0 = неизвестно); fallback_w — ширина по умолчанию.
func setup(alt: String, transition = null, want_w: float = 0.0, want_h: float = 0.0, fallback_w: float = BASE_WIDTH) -> void:
	_alt = alt
	_transition = transition
	_want_w = want_w
	_want_h = want_h
	if fallback_w > 0.0:
		_fallback_w = fallback_w


func get_height_m() -> float:
	return _height_m


func _ready() -> void:
	add_to_group(GROUP)

	# Слой 2 — только для клика-луча; игрок сквозь панель проходит (его маска — слой 1).
	collision_layer = 2
	collision_mask = 0

	_quad = QuadMesh.new()
	_quad.size = _initial_size()
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _quad
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.18, 0.21, 0.28)   # тон заглушки
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = _mat
	add_child(_mesh)

	_label = Label3D.new()
	_label.text = _placeholder_text()
	_label.font_size = 40
	_label.outline_size = 10
	_label.pixel_size = 0.006
	_label.width = 360
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.modulate = Color(0.7, 0.8, 1.0)
	add_child(_label)

	_collision = CollisionShape3D.new()
	_shape = BoxShape3D.new()
	_collision.shape = _shape
	add_child(_collision)

	_update_layout()


## Просит текстуру у лоадера; когда придёт — заменит заглушку (или пометит, что не вышло).
func request_load(url: String, loader: ImageLoader) -> void:
	if url == "" or loader == null:
		return
	loader.request_image(url, _on_texture)


func _on_texture(tex: Texture2D) -> void:
	if not is_instance_valid(self):
		return
	if tex == null:
		_label.text = _placeholder_text() + " ✕"
		return

	var size := tex.get_size()
	var aspect: float = 1.0 if size.y <= 0 else float(size.x) / float(size.y)
	# Размеры из HTML главнее: оба заданы -> берём как есть; один -> второй из пропорций
	# реальной текстуры; ничего нет -> запасная ширина и пропорции текстуры.
	var w: float
	var h: float
	if _want_w > 0.0 and _want_h > 0.0:
		w = _want_w
		h = _want_h
	elif _want_w > 0.0:
		w = _want_w
		h = w / aspect
	elif _want_h > 0.0:
		h = _want_h
		w = h * aspect
	else:
		w = _fallback_w
		h = w / aspect
	_quad.size = _clamp_size(Vector2(w, h))

	_mat.albedo_texture = tex
	_mat.albedo_color = Color.WHITE
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	# Без этого StandardMaterial3D игнорирует альфу PNG/GIF и прозрачные пиксели
	# рендерятся своим RGB (обычно чёрным) — отсюда «чёрный фон». Альфу включаем
	# только если она реально есть, чтобы не платить за сортировку прозрачных
	# у непрозрачных JPEG.
	if _has_alpha(tex):
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_label.visible = false
	_update_layout()


## true, если у текстуры есть альфа-канал (значит, может быть прозрачность).
## GIF приходит как AnimatedTexture (get_image нет) — у него альфу считаем возможной:
## прозрачность в гифках обычна, а лишний альфа-режим у непрозрачной гифки дёшев.
func _has_alpha(tex: Texture2D) -> bool:
	if tex is AnimatedTexture:
		return true
	var img := tex.get_image()
	if img == null:
		return false
	return img.detect_alpha() != Image.ALPHA_NONE


## Общий интерфейс взаимодействия по лучу игрока — кликабельна только картинка-ссылка.
func interact_at(_point: Vector3) -> void:
	if _transition != null and typeof(_transition) == TYPE_DICTIONARY:
		link_activated.emit(_transition)


## Размер квада-заглушки до загрузки: что известно из HTML, иначе запасная ширина
## с дефолтными пропорциями. После прихода текстуры размер уточняется в _on_texture.
func _initial_size() -> Vector2:
	var w := _fallback_w
	var h := w * DEFAULT_RATIO
	if _want_w > 0.0 and _want_h > 0.0:
		w = _want_w
		h = _want_h
	elif _want_w > 0.0:
		w = _want_w
		h = _want_w * DEFAULT_RATIO
	elif _want_h > 0.0:
		h = _want_h
		w = _want_h / DEFAULT_RATIO
	return _clamp_size(Vector2(w, h))


## Ужимает размер под потолки ширины/высоты, сохраняя пропорции.
func _clamp_size(s: Vector2) -> Vector2:
	var w := s.x
	var h := s.y
	if w > MAX_WIDTH:
		var k := MAX_WIDTH / w
		w *= k
		h *= k
	if h > MAX_HEIGHT:
		var k := MAX_HEIGHT / h
		w *= k
		h *= k
	return Vector2(maxf(0.2, w), maxf(0.2, h))


func _update_layout() -> void:
	_height_m = _quad.size.y
	# Центр картинки — на уровне глаз (корень эктора на полу): мелкие картинки висят перед
	# лицом, высокие приподняты так, чтобы низ не вжимался в пол (FLOOR_GAP).
	var center_y := maxf(EYE_LEVEL, _height_m * 0.5 + FLOOR_GAP)
	_mesh.position = Vector3(0, center_y, 0)
	_shape.size = Vector3(_quad.size.x, _height_m, 0.08)
	_collision.position = Vector3(0, center_y, 0)
	_label.position = Vector3(0, center_y, 0.06)


func _placeholder_text() -> String:
	var t := _alt.strip_edges()
	if t == "":
		return "🖼"
	if t.length() > 40:
		t = t.substr(0, 40) + "…"
	return "🖼 " + t
