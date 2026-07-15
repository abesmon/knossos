class_name ImagePanel
extends WorldUiSurface

## Эктор-картинка: 3D-квад с реальной текстурой страницы. До загрузки показывает
## заглушку «🖼 alt»; текстура подтягивается прогрессивно через ImageLoader уже после
## сборки мира и заменяет заглушку, подгоняя пропорции квада под пропорции картинки.
##
## Картинка может быть и ссылкой (`<a><img></a>`): тогда несёт Transition и кликается
## лучом игрока так же, как Portal/RichPanel — через общий интерфейс interact_at.
## Один и тот же эктор используется и для HTML `<img>`, и для `<VRWebImage>`/ImagePlacementTool:
## происхождение картинки не создаёт новый визуальный класс. Отличающиеся правила размещения
## задаются конфигурацией `Anchor`, а `src` позволяет автономно загрузить текстуру через общий
## ImageLoader мира.

signal link_activated(transition: Dictionary)

const GROUP := "image_panel"
# Единая метрика мира: 1 м = 128 пикселей. Размеры картинки из HTML (width/height)
# переводятся в метры через неё — та же линейка, что у текста и ширин панелей.
# Если HTML-размера нет, стартует BASE_WIDTH; после прихода текстуры размер уточняется по
# натуральным пикселям с cap'ом, а WorldGenerator пересчитывает packing комнаты.
const PX_PER_METER := 128.0
const BASE_WIDTH := 1.2        # запасная ширина квада, если мир не задал свою, м
# Потолки не ограничивают картинку (она занимает свой реальный размер), но нужны как
# дефолт-капы для экрана <video> в WorldGenerator._measure_video.
const MAX_WIDTH := 6.3
const MAX_HEIGHT := 3.0
const NATURAL_MAX_WIDTH := 6.3 # cap для картинок без HTML-размера после прихода текстуры
const DEFAULT_RATIO := 0.66    # стартовые пропорции заглушки до загрузки
const EYE_LEVEL := 1.6         # высота центра картинки, м (= высота камеры игрока)
const FLOOR_GAP := 0.1         # минимальный зазор от низа высокой картинки до пола, м
const FLOATING_MAX_WIDTH := 3.0 # дефолтный cap свободно размещённой картинки без width, м

enum Anchor { FLOOR, CENTER }

var _alt: String = ""
var _transition = null
# Желаемые размеры из HTML (метры, 0 = не заданы) и запасная ширина — их задаёт мир,
# переводя width/height страницы в метры общим масштабом. См. WorldGenerator._build_image_panel.
var _want_w := 0.0
var _want_h := 0.0
var _fallback_w := BASE_WIDTH
# Максимальная ширина квада (метры, 0 = без ограничения): доступная ширина стены за вычетом
# safe-area. Картинка ужимается под неё с сохранением пропорций, чтобы не вылезти за края стены —
# даже если натуральная текстура/HTML-размер шире. Задаёт мир из раскладки комнаты.
var _max_w := 0.0
var _anchor: int = Anchor.FLOOR

## Источник для автономного режима (`<VRWebImage>`). HTML-пайплайн может оставить его пустым
## и вызвать request_load с уже разрешённым URL и конкретным ImageLoader.
var src := "":
	set(value):
		if src == value:
			return
		src = value
		if is_inside_tree():
			_request_from_world()

@onready var _mesh: MeshInstance3D = $Front
@onready var _mesh_back: MeshInstance3D = $Back
@onready var _quad: QuadMesh = _mesh.mesh
@onready var _mat: StandardMaterial3D = _mesh.material_override
@onready var _label: Label3D = $Placeholder
@onready var _collision: CollisionShape3D = $Collision
@onready var _shape: BoxShape3D = _collision.shape
var _height_m := BASE_WIDTH * DEFAULT_RATIO


## Вызывается ДО add_child. transition (если есть) делает картинку кликабельной ссылкой.
## want_w/want_h — размеры из HTML в метрах (0 = неизвестно); fallback_w — ширина по умолчанию.
func setup(alt: String, transition = null, want_w: float = 0.0, want_h: float = 0.0,
		fallback_w: float = BASE_WIDTH, max_w: float = 0.0,
		anchor: int = Anchor.FLOOR) -> void:
	_alt = alt
	_transition = transition
	_want_w = want_w
	_want_h = want_h
	if fallback_w > 0.0:
		_fallback_w = fallback_w
	_max_w = max_w
	_anchor = anchor


func get_height_m() -> float:
	return _height_m


func ui_size() -> Vector2:
	return _quad.size


func ui_center_local() -> Vector3:
	return _mesh.position


func _ready() -> void:
	super()
	add_to_group(GROUP)
	# Свободно размещённая картинка без авторского width не должна заслонять комнату.
	# Для HTML-картинки ограничение приходит от доступной ширины стены.
	if _anchor == Anchor.CENTER and _max_w <= 0.0 and _want_w <= 0.0:
		_max_w = FLOATING_MAX_WIDTH

	_quad.size = _initial_size()
	# Каждая грань рисуется только со своей стороны (CULL_BACK), а изнанку даёт
	# второй квад, развёрнутый на 180° вокруг Y (_mesh_back). Так картинка читается
	# одинаково с обеих сторон, без зеркала, которое давала единая двусторонняя грань.
	_mat.cull_mode = BaseMaterial3D.CULL_BACK
	# Unlit: текстура показывается как есть, без зависимости от освещения сцены —
	# иначе обратная грань (и грань без света) уходила бы в темноту.
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_label.text = _placeholder_text()
	_update_layout()
	_request_from_world.call_deferred()


## Просит текстуру у лоадера; когда придёт — заменит заглушку (или пометит, что не вышло).
func request_load(url: String, loader: ImageLoader) -> void:
	if url == "" or loader == null:
		return
	loader.request_image(url, _on_texture)


## Автономная загрузка для узлов vrweb/инструмента: ImageLoader один на текущий мир.
func _request_from_world() -> void:
	if src == "" or not is_inside_tree():
		return
	var loader := get_tree().get_first_node_in_group(ImageLoader.GROUP) as ImageLoader
	if loader != null:
		request_load(src, loader)


func _on_texture(tex: Texture2D) -> void:
	if not is_instance_valid(self):
		return
	if tex == null:
		_label.text = _placeholder_text() + " ✕"
		return

	var size := tex.get_size()
	var aspect: float = 1.0 if size.y <= 0 else float(size.x) / float(size.y)
	# Размеры из HTML главнее: оба заданы -> берём как есть; один -> второй из пропорций
	# реальной текстуры; ничего нет -> натуральные пиксели текстуры в общей метрике, но с cap'ом.
	# WorldGenerator слушает size_changed и перепаковывает комнату после позднего уточнения.
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
		w = float(size.x) / PX_PER_METER
		h = float(size.y) / PX_PER_METER
		if w > NATURAL_MAX_WIDTH:
			var k := NATURAL_MAX_WIDTH / w
			w *= k
			h *= k
		if h > MAX_HEIGHT:
			var k2 := MAX_HEIGHT / h
			w *= k2
			h *= k2
	var old_size := _quad.size
	_quad.size = _clamp_size(Vector2(w, h))

	_mat.albedo_texture = tex
	_mat.albedo_color = Color.WHITE
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Остаёмся в unlit (см. _ready): картинка одинаково яркая с обеих сторон.
	# Без этого StandardMaterial3D игнорирует альфу PNG/GIF и прозрачные пиксели
	# рендерятся своим RGB (обычно чёрным) — отсюда «чёрный фон». Альфу включаем
	# только если она реально есть, чтобы не платить за сортировку прозрачных
	# у непрозрачных JPEG.
	if _has_alpha(tex):
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_label.visible = false
	_update_layout()
	if old_size.distance_to(_quad.size) > 0.01:
		notify_size_changed(_quad.size)


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
func _on_ui_accept(_uv: Vector2) -> void:
	if _is_link():
		link_activated.emit(_transition)


## Под прицелом ли кликабельная картинка-ссылка? Player'у — для подсветки курсора.
## У картинки ссылкой служит вся панель, так что точка попадания не важна.
func _ui_is_active(_uv: Vector2) -> bool:
	return _is_link()


## Куда ведёт картинка-ссылка — для строки статуса (превью ссылки в углу браузера).
func _ui_hint(_uv: Vector2) -> String:
	return TransitionText.describe(_transition) if _is_link() else ""


func _is_link() -> bool:
	return _transition != null and typeof(_transition) == TYPE_DICTIONARY


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


## Размер квада берётся как есть — без пола и потолков: картинка занимает ровно свой размер по
## метрике 1м=512px, хоть крошечная, хоть огромная. Единственный кап — _max_w (ширина стены за
## вычетом safe-area): шире неё картинку ужимаем с сохранением пропорций, чтобы не вылезти за края
## стены. Плюс страхуемся от вырожденного нуля, чтобы квад не схлопнулся.
func _clamp_size(s: Vector2) -> Vector2:
	var w := maxf(0.001, s.x)
	var h := maxf(0.001, s.y)
	if _max_w > 0.0 and w > _max_w:
		h *= _max_w / w
		w = _max_w
	return Vector2(w, h)


func _update_layout() -> void:
	_height_m = _quad.size.y
	if _anchor == Anchor.CENTER:
		_mesh.position = Vector3.ZERO
		_mesh_back.position = Vector3.ZERO
		_shape.size = Vector3(_quad.size.x, _height_m, 0.08)
		_collision.position = Vector3.ZERO
		_label.position = Vector3(0, 0, 0.06)
		return
	# Центр картинки — на уровне глаз (корень эктора на полу): мелкие картинки висят перед
	# лицом, высокие приподняты так, чтобы низ не вжимался в пол (FLOOR_GAP).
	var center_y := maxf(EYE_LEVEL, _height_m * 0.5 + FLOOR_GAP)
	_mesh.position = Vector3(0, center_y, 0)
	_mesh_back.position = Vector3(0, center_y, 0)
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
