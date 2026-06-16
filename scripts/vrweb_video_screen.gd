class_name VrwebVideoScreen
extends StaticBody3D

## Поверхность-экран VRWeb: 3D-квад, на который натянута текстура логического плеера
## (VrwebVideoPlayer). Одну текстуру плеера можно показать на нескольких экранах. До
## появления кадра показывает заглушку «▶ video». Кликабелен лучом игрока (общий интерфейс
## interact_at, как ImagePanel/Portal) — клик переключает play/pause (shared-управление).
##
## Размещается тегом <VRWebVideoScreen player="<id>"> (общий плеер) или
## <VRWebVideoScreen src="<url>"> (свой плеер); привязку делает VrwebVideoManager.
## См. docs/video-player.md.

const GROUP := "video_screen"
const DEFAULT_WIDTH := 3.2          # ширина по умолчанию, если size не задан, м
const DEFAULT_RATIO := 9.0 / 16.0   # пропорции по умолчанию (16:9) до прихода кадра

## Привязка из тега (читает менеджер): id общего плеера ИЛИ url собственного.
var player_id := ""
var src := ""
## Параметры неявного плеера (только когда задан src, а не player) — читает менеджер.
var autoplay := false
var loop := false
var volume := 1.0

var _want_w := 0.0   # размеры из тега (size="ш:в"), 0 = авто из пропорций видео
var _want_h := 0.0

var _player: VrwebVideoPlayer = null
var _mesh: MeshInstance3D
var _quad: QuadMesh
var _mat: StandardMaterial3D
var _label: Label3D
var _shape: BoxShape3D
var _auto_sized := false   # уже подогнали пропорции под кадр


## Параметры из тега. Зовётся билдером до add_child. size — Vector2 в метрах (0,0 = авто).
func setup(p_player_id: String, p_src: String, size: Vector2) -> void:
	player_id = p_player_id
	src = p_src
	_want_w = maxf(size.x, 0.0)
	_want_h = maxf(size.y, 0.0)


func _ready() -> void:
	add_to_group(GROUP)
	# Слой 2 — только для клик-луча; игрок проходит сквозь экран (его маска — слой 1).
	collision_layer = 2
	collision_mask = 0

	_quad = QuadMesh.new()
	_quad.size = _initial_size()
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _quad
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.05, 0.05, 0.07)
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh.material_override = _mat
	add_child(_mesh)

	_label = Label3D.new()
	_label.text = "▶ video" if VrwebVideoPlayer.is_available() else "▶ video unavailable"
	_label.font_size = 48
	_label.outline_size = 12
	_label.pixel_size = 0.006
	_label.modulate = Color(0.8, 0.85, 1.0)
	add_child(_label)

	var collision := CollisionShape3D.new()
	_shape = BoxShape3D.new()
	collision.shape = _shape
	add_child(collision)
	_update_collision()


## Привязать к логическому плееру (делает VrwebVideoManager после scan).
func bind(player: VrwebVideoPlayer) -> void:
	_player = player
	if player == null:
		return
	player.texture_ready.connect(_on_texture)
	var existing := player.current_texture()
	if existing != null:   # кадр мог появиться до привязки
		_on_texture(existing)


func _on_texture(tex: Texture2D) -> void:
	if tex == null:
		return
	_mat.albedo_texture = tex
	_mat.albedo_color = Color.WHITE
	_label.visible = false
	_apply_aspect(tex)
	if not _auto_sized:
		set_process(true)   # размер видео мог быть ещё неизвестен — подгоним позже


## Подгоняет пропорции квада под кадр, если size в теге не задан. Размер видео доступен
## не сразу, поэтому пробуем и в _process до успеха.
func _process(_delta: float) -> void:
	if _player == null or _auto_sized:
		set_process(false)
		return
	_apply_aspect(_player.current_texture())
	if _auto_sized:
		set_process(false)


func _apply_aspect(tex: Texture2D) -> void:
	if tex == null or (_want_w > 0.0 and _want_h > 0.0):
		return
	var ts := tex.get_size()
	if ts.x <= 0 or ts.y <= 0:
		return
	var aspect := float(ts.x) / float(ts.y)
	var w := _want_w if _want_w > 0.0 else (_want_h * aspect if _want_h > 0.0 else DEFAULT_WIDTH)
	var h := _want_h if _want_h > 0.0 else w / aspect
	_quad.size = Vector2(w, h)
	_update_collision()
	_auto_sized = true


## Общий интерфейс взаимодействия по лучу игрока — клик переключает play/pause.
func interact_at(_point: Vector3) -> void:
	if _player != null:
		_player.toggle()


func _initial_size() -> Vector2:
	if _want_w > 0.0 and _want_h > 0.0:
		return Vector2(_want_w, _want_h)
	if _want_w > 0.0:
		return Vector2(_want_w, _want_w * DEFAULT_RATIO)
	if _want_h > 0.0:
		return Vector2(_want_h / DEFAULT_RATIO, _want_h)
	return Vector2(DEFAULT_WIDTH, DEFAULT_WIDTH * DEFAULT_RATIO)


func _update_collision() -> void:
	_shape.size = Vector3(_quad.size.x, _quad.size.y, 0.05)
