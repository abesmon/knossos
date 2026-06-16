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

# --- Наэкранный UI (прогресс-бар + буфер), проявляется при «движении мыши» по экрану ---
const UI_IDLE_HIDE := 2.0       # с без движения точки прицела (мышь замерла) → прячем UI
const UI_LOST_HIDE := 0.2       # с без луча на экране → прячем UI
const UI_FADE_SPEED := 6.0      # скорость проявления/затухания UI, 1/с
const UI_MOVE_EPS := 0.0025     # м: смещение точки прицела меньше — считаем «мышь не двигалась»
const UI_FRONT_Z := 0.012       # вынос UI перед плоскостью экрана, м (анти-z-fighting)
# Базовые цвета элементов (альфа домножается на текущую прозрачность UI при затухании).
const COL_TRACK := Color(0.0, 0.0, 0.0, 0.55)      # дорожка-фон
const COL_BUFFER := Color(0.55, 0.57, 0.62, 0.7)   # буфер (скачанная часть)
const COL_PROGRESS := Color(0.95, 0.25, 0.25, 0.95) # проигранная часть

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

# Наэкранный UI: контейнер + дорожка/буфер/прогресс (3D-квады) + подпись времени.
var _ui: Node3D
var _ui_track: MeshInstance3D
var _ui_buffer: MeshInstance3D
var _ui_progress: MeshInstance3D
var _ui_time: Label3D
var _ui_alpha := 0.0           # текущая прозрачность UI (0 спрятан, 1 показан)
var _track_w := 0.0            # ширина дорожки прогресса, м (из размера квада)
var _bar_h := 0.0             # толщина бара, м
var _bar_y := 0.0             # y-центр бара в локальных координатах (для хит-теста seek)
var _last_hover := Vector3.ZERO
var _have_hover := false
var _idle_accum := 999.0       # с с последнего движения точки прицела
var _since_hover := 999.0      # с с последнего hover_at (луч ушёл, если велико)


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
	_build_ui()
	_update_collision()
	_layout_ui()


## Привязать к логическому плееру (делает VrwebVideoManager после scan).
func bind(player: VrwebVideoPlayer) -> void:
	_player = player
	if player == null:
		return
	player.texture_ready.connect(_on_texture)
	set_process(true)   # гоняем UI-цикл (прогресс/буфер/затухание) пока есть плеер
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


## UI-цикл: пока пропорции квада не подогнаны под кадр — подгоняем (размер видео известен не
## сразу), а затем каждый кадр обновляем наэкранный UI (видимость по «движению мыши»,
## прогресс/буфер). Включён, пока экран привязан к плееру (см. bind).
func _process(delta: float) -> void:
	if _player == null:
		return
	if not _auto_sized:
		_apply_aspect(_player.current_texture())
	_update_ui(delta)


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
	_layout_ui()
	_auto_sized = true


## Общий интерфейс взаимодействия по лучу игрока. Клик по видимому прогресс-бару — перемотка
## в эту точку, клик в остальную часть экрана — play/pause (как было).
func interact_at(point: Vector3) -> void:
	if _player == null:
		return
	if _ui_alpha > 0.5 and _seek_at(point):
		return
	_player.toggle()


## Если клик попал по видимому бару — перематывает плеер в соответствующую позицию и
## возвращает true. Зона клика по вертикали щедрая (бар тонкий — попасть точно трудно).
func _seek_at(point: Vector3) -> bool:
	var dur: float = _player.duration()
	if dur <= 0.0:
		return false
	var local := to_local(point)
	if absf(local.y - _bar_y) > _bar_h * 0.5 + _quad.size.y * 0.04:
		return false
	var left := -_track_w * 0.5
	if local.x < left - 0.02 or local.x > left + _track_w + 0.02:
		return false
	_player.seek(clampf((local.x - left) / _track_w, 0.0, 1.0) * dur)
	return true


## Прицел на экране считается активным (main подсвечивает курсор), как у Portal/RichPanel.
func is_active_at(_point: Vector3) -> bool:
	return _player != null


# --- Наэкранный UI: прогресс-бар + буфер, проявляется при «движении мыши» по экрану ---

## Игрок непрерывно кормит точкой прицела (см. Player._dispatch_hover). Сдвиг точки = «мышь
## двигается» → держим/проявляем UI; замерла или луч ушёл — UI гаснет (по таймауту в _update_ui).
func hover_at(point: Vector3) -> void:
	_since_hover = 0.0
	if not _have_hover or point.distance_to(_last_hover) > UI_MOVE_EPS:
		_idle_accum = 0.0
	_last_hover = point
	_have_hover = true


func _build_ui() -> void:
	_ui = Node3D.new()
	_ui.visible = false
	add_child(_ui)
	_ui_track = _make_bar(COL_TRACK)
	_ui_buffer = _make_bar(COL_BUFFER)
	_ui_progress = _make_bar(COL_PROGRESS)
	_ui_time = Label3D.new()
	_ui_time.font_size = 28
	_ui_time.outline_size = 8
	_ui_time.pixel_size = 0.0016
	_ui_time.modulate = Color(0.9, 0.93, 1.0)
	_ui.add_child(_ui_time)


## Цветной квад-бар для дорожки/буфера/прогресса. Базовый цвет — в meta (альфа домножается
## на _ui_alpha при затухании). Размер/позиция выставляются в _layout_ui и _refresh_bars.
func _make_bar(col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.001, 0.001)
	m.mesh = q
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.material_override = mat
	m.set_meta("base_color", col)
	_ui.add_child(m)
	return m


## Раскладка UI под текущий размер квада: бар внизу экрана на ширину 92% и подпись над ним.
## Зовётся при создании и при каждой смене размера (_apply_aspect).
func _layout_ui() -> void:
	if _ui == null:
		return
	var w := _quad.size.x
	var h := _quad.size.y
	_track_w = w * 0.92
	_bar_h = clampf(h * 0.022, 0.018, 0.05)
	_bar_y = -h * 0.5 + h * 0.06
	(_ui_track.mesh as QuadMesh).size = Vector2(_track_w, _bar_h)
	_ui_track.position = Vector3(0.0, _bar_y, UI_FRONT_Z)
	# Буфер и прогресс рисуются поверх дорожки (чуть ближе к зрителю), высота с дорожкой.
	(_ui_buffer.mesh as QuadMesh).size.y = _bar_h
	(_ui_progress.mesh as QuadMesh).size.y = _bar_h
	_ui_buffer.position = Vector3(0.0, _bar_y, UI_FRONT_Z + 0.001)
	_ui_progress.position = Vector3(0.0, _bar_y, UI_FRONT_Z + 0.002)
	_ui_time.position = Vector3(0.0, _bar_y + _bar_h * 0.5 + h * 0.05, UI_FRONT_Z)


func _update_ui(delta: float) -> void:
	if _ui == null:
		return
	_since_hover += delta
	_idle_accum += delta
	# Показываем, когда луч на экране (hover_at звали недавно) И «мышь» двигалась недавно.
	var ray_here := _since_hover <= UI_LOST_HIDE
	var target := 1.0 if (ray_here and _idle_accum < UI_IDLE_HIDE) else 0.0
	_ui_alpha = move_toward(_ui_alpha, target, UI_FADE_SPEED * delta)
	if _ui_alpha <= 0.001:
		_ui.visible = false
		return
	_ui.visible = true
	_refresh_bars()
	_apply_alpha()


## Длины буфера/прогресса и подпись времени из состояния плеера.
func _refresh_bars() -> void:
	if _player == null:
		return
	var dur: float = _player.duration()
	var pos: float = _player.position()
	var prog := clampf(pos / dur, 0.0, 1.0) if dur > 0.0 else 0.0
	_set_fill(_ui_buffer, _player.buffered_fraction())
	_set_fill(_ui_progress, prog)
	var glyph := "▶" if _player.is_playing() else "‖"
	if _player.is_buffering():
		glyph = "…"
	_ui_time.text = ("%s  %s / %s" % [glyph, _fmt_time(pos), _fmt_time(dur)]) if dur > 0.0 \
		else "%s  %s" % [glyph, _fmt_time(pos)]


## Бар-заливка от левого края дорожки на долю f (0..1).
func _set_fill(node: MeshInstance3D, f: float) -> void:
	var width := maxf(_track_w * clampf(f, 0.0, 1.0), 0.0005)
	(node.mesh as QuadMesh).size.x = width
	node.position.x = -_track_w * 0.5 + width * 0.5


## Домножает альфу всех элементов на _ui_alpha — плавное проявление/затухание UI.
func _apply_alpha() -> void:
	_fade_bar(_ui_track)
	_fade_bar(_ui_buffer)
	_fade_bar(_ui_progress)
	_ui_time.modulate.a = _ui_alpha
	_ui_time.outline_modulate.a = _ui_alpha


func _fade_bar(node: MeshInstance3D) -> void:
	var base: Color = node.get_meta("base_color")
	(node.material_override as StandardMaterial3D).albedo_color = \
		Color(base.r, base.g, base.b, base.a * _ui_alpha)


func _fmt_time(t: float) -> String:
	var s := int(maxf(t, 0.0))
	@warning_ignore("integer_division")
	return "%d:%02d" % [s / 60, s % 60]


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
