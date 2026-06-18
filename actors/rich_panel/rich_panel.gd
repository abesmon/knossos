class_name RichPanel
extends StaticBody3D

## Эктор-абзац: один блок форматированного текста с кликабельными inline-ссылками.
## Текст рендерится RichTextLabel'ом в SubViewport, кладётся текстурой на 3D-квад.
## Клик игрока (луч) мапится в координаты вьюпорта и синтетически прокидывается в
## RichTextLabel — тот сам определяет ссылку под точкой и эмитит meta_clicked.

signal link_activated(transition: Dictionary)

const GROUP := "rich_panel"
const PANEL_WIDTH_PX := 960       # шире = текст растёт вширь, а не вверх (меньше высоких столбов)
const MAX_HEIGHT_PX := 832        # потолок высоты панели (~2.6 м): выше — скролл, а не башня
const PIXEL_PER_METER := 320.0   # перевод пикселей вьюпорта в метры квада
const FONT_SIZE := 24            # дефолтный кегль вьюпорта, если мир не задал свой
const MARGIN := 18
const SCROLLBAR_W := 16          # ширина заметного скроллбара у прокручиваемых панелей, px

var _runs: Array = []
var _metas: Array = []           # индекс url-меты -> Transition
var _bbcode := ""
var _w_px := PANEL_WIDTH_PX
var _h_px := 120
var _font_size := FONT_SIZE      # кегль вьюпорта; мир задаёт его из базы текста страницы
var _probing := false            # is_active_at «кликает» вхолостую, чтобы узнать, есть ли ссылка
var _probe_hit := false          # результат такого пробного клика
var _probe_transition = null     # Transition под точкой пробного клика (для строки статуса)
var _scrollable := false         # контент выше потолка ⇒ панель прокручивается колесом
var _thumb: ColorRect = null     # собственный индикатор скролла (штатный бар RichTextLabel прячем)

@onready var _viewport: SubViewport = $SubViewport
@onready var _bg: ColorRect = $SubViewport/Background
@onready var _label: RichTextLabel = $SubViewport/RichTextLabel
@onready var _mesh: MeshInstance3D = $Mesh
@onready var _collision: CollisionShape3D = $CollisionShape3D


## Вызывается ДО add_child: готовит bbcode и оценивает высоту панели.
## font_world_m — желаемая мир-высота глифа (базовый текст страницы); <0 — дефолт.
func setup(runs: Array, font_world_m: float = -1.0) -> void:
	_runs = runs
	if font_world_m > 0.0:
		_font_size = max(8, int(round(font_world_m * PIXEL_PER_METER)))
	_build_bbcode()
	_estimate_height()


func get_height_m() -> float:
	return _h_px / PIXEL_PER_METER


func _ready() -> void:
	add_to_group(GROUP)
	_layout_viewport()
	_build_quad()
	# Высота из setup() — лишь оценка для раскладки мира. После того как RichTextLabel
	# реально разложит текст, подгоняем панель под фактическую высоту (иначе текст обрезается),
	# а при переполнении потолка включаем скролл вместо башни. См. _refit.
	_refit.call_deferred()


## Прокрутка колесом мыши, если контент выше потолка панели. dir: +1 вниз, -1 вверх.
## Player вызывает это у объекта под прицелом (общий канал, как interact_at).
func scroll_by(dir: float) -> void:
	if not _scrollable:
		return
	var bar := _label.get_v_scroll_bar()
	if bar == null:
		return
	bar.value = clampf(bar.value + dir * _font_size * 1.4 * 3.0, bar.min_value, bar.max_value)
	_update_thumb()
	# Вьюпорт рисуется по требованию (UPDATE_ONCE) — после скролла просим перерисовать кадр.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Маппит точку попадания луча в пиксель вьюпорта и «кликает» там за игрока.
func interact_at(point: Vector3) -> void:
	var px := _point_to_px(point)
	if px.x < 0.0:
		return
	_push_click(px)


## Под прицелом ли реальная inline-ссылка (а не просто текст)? Нужно Player'у для
## подсветки курсора. У RichTextLabel нет публичного «meta под точкой», а meta_hover по
## синтетическому движению мыши во вьюпорте не срабатывает (в отличие от клика). Поэтому
## «кликаем» вхолостую под флагом _probing: _on_meta_clicked не выполняет переход, а лишь
## выставляет _probe_hit — так мы переиспользуем единственный рабочий канал hit-теста.
func is_active_at(point: Vector3) -> bool:
	var px := _point_to_px(point)
	if px.x < 0.0:
		return false
	_probing = true
	_probe_hit = false
	_probe_transition = null
	_push_click(px)
	_probing = false
	return _probe_hit


## Куда ведёт ссылка под прицелом — для строки статуса. Переиспользует Transition,
## пойманный последним пробным is_active_at (Player зовёт его в том же кадре перед этим).
func aim_hint_at(_point: Vector3) -> String:
	return TransitionText.describe(_probe_transition)


## Точка попадания луча -> пиксель вьюпорта. Vector2(-1, -1) — квад ещё не построен.
func _point_to_px(point: Vector3) -> Vector2:
	var quad := _mesh.mesh as QuadMesh
	if quad == null:
		return Vector2(-1, -1)
	var local := to_local(point)
	var size := quad.size
	var u := clampf((local.x + size.x * 0.5) / size.x, 0.0, 1.0)
	var v := clampf((size.y * 0.5 - local.y) / size.y, 0.0, 1.0)
	return Vector2(u * _viewport.size.x, v * _viewport.size.y)


func _push_click(px: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = px
		_viewport.push_input(ev, true)


func _on_meta_clicked(meta: Variant) -> void:
	var idx := int(str(meta))
	# Пробный клик из is_active_at: фиксируем попадание и Transition под точкой, без перехода.
	if _probing:
		_probe_hit = true
		if idx >= 0 and idx < _metas.size():
			_probe_transition = _metas[idx]
		return
	if idx >= 0 and idx < _metas.size():
		link_activated.emit(_metas[idx])


# --- Сборка ---

func _build_bbcode() -> void:
	_metas.clear()
	var sb := ""
	for r in _runs:
		var text := str(r.get("text", "")).replace("[", "[lb]")
		var fn = r.get("function", null)
		if fn != null and typeof(fn) == TYPE_DICTIONARY:
			var idx := _metas.size()
			_metas.append(fn)
			var col := "#5cc8ff" if fn.get("kind", "") == "navigate" else "#9be7ff"
			sb += "[color=%s][u][url=%d]%s[/url][/u][/color]" % [col, idx, text]
		else:
			sb += text
	_bbcode = sb


func _estimate_height() -> void:
	_h_px = estimate_height_px(_runs, _font_size, _w_px)


## Оценка высоты панели (px) по длине текста и переносам — БЕЗ рендера. static, чтобы
## WorldGenerator мог замерить будущую панель тем же кодом, что и сама панель (футпринт
## для раскладки и фактическая геометрия совпадают). См. WorldGenerator._measure_object.
static func estimate_height_px(runs: Array, font_size: int, w_px: int = PANEL_WIDTH_PX) -> int:
	var plain := ""
	var explicit_lines := 1
	for r in runs:
		var t := str(r.get("text", ""))
		plain += t
		explicit_lines += t.count("\n")
	var usable := float(w_px - MARGIN * 2)
	var chars_per_line: float = max(1.0, usable / (font_size * 0.5))
	var wrapped := int(ceil(plain.length() / chars_per_line))
	var lines: int = max(explicit_lines, wrapped)
	var line_h := int(font_size * 1.4)
	# Тот же потолок, что у фактической панели: длинный текст уезжает в скролл, поэтому
	# и футпринт для раскладки мира не раздувается в высокую башню.
	return clampi(lines * line_h + MARGIN * 2, 80, MAX_HEIGHT_PX)


## Та же оценка в метрах квада — удобна геометрии.
static func estimate_height_m(runs: Array, font_size: int) -> float:
	return float(estimate_height_px(runs, font_size)) / PIXEL_PER_METER


func _layout_viewport() -> void:
	_viewport.size = Vector2i(_w_px, _h_px)
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.color = Color(0.09, 0.10, 0.13, 1.0)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = MARGIN
	_label.offset_top = MARGIN
	# Справа резервируем жёлоб под индикатор скролла, чтобы текст под него не заезжал.
	_label.offset_right = -(MARGIN + SCROLLBAR_W)
	_label.offset_bottom = -MARGIN
	_label.bbcode_enabled = true
	_label.scroll_active = false
	_label.add_theme_font_size_override("normal_font_size", _font_size)
	_label.add_theme_font_size_override("bold_font_size", _font_size)
	if not _label.meta_clicked.is_connected(_on_meta_clicked):
		_label.meta_clicked.connect(_on_meta_clicked)
	_hide_native_scrollbar()
	_label.text = _bbcode

	# Свой индикатор скролла поверх текста: штатный бар RichTextLabel в SubViewport не
	# показывался (терялся), отчего казалось, что длинный текст просто обрезан. Этот —
	# всегда виден, когда есть что прокручивать (см. _update_thumb).
	_thumb = ColorRect.new()
	_thumb.color = Color(0.45, 0.78, 1.0, 0.95)
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb.visible = false
	_viewport.add_child(_thumb)


## Прячет штатный вертикальный скроллбар RichTextLabel — вместо него рисуем свой _thumb.
func _hide_native_scrollbar() -> void:
	var bar := _label.get_v_scroll_bar()
	if bar == null:
		return
	var empty := StyleBoxEmpty.new()
	for s in ["grabber", "grabber_highlight", "grabber_pressed", "scroll", "scroll_focus"]:
		bar.add_theme_stylebox_override(s, empty)


## Строит/обновляет квад и коллайдер под текущие _w_px/_h_px. Повторно вызывается из _refit,
## когда панель пересчитала высоту по факту разложенного текста — пере-используем меш/материал.
func _build_quad() -> void:
	var w_m := _w_px / PIXEL_PER_METER
	var h_m := _h_px / PIXEL_PER_METER

	var quad := _mesh.mesh as QuadMesh
	if quad == null:
		quad = QuadMesh.new()
		_mesh.mesh = quad
	quad.size = Vector2(w_m, h_m)

	if _mesh.material_override == null:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_texture = _viewport.get_texture()
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_mesh.material_override = mat

	var box := _collision.shape as BoxShape3D
	if box == null:
		box = BoxShape3D.new()
		_collision.shape = box
	box.size = Vector3(w_m, h_m, 0.08)


## После реальной раскладки текста берём фактическую высоту контента (get_content_height) —
## оценка _estimate_height её систематически занижала, отсюда обрезанные снизу панели. Если
## контент выше потолка MAX_HEIGHT_PX — фиксируем высоту на потолке и включаем скролл.
func _refit() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(self):
		return
	var ch := _label.get_content_height()
	if ch <= 0:
		return   # раскладка ещё не готова — оставляем оценку, текст не теряется
	var content := int(ceil(ch)) + MARGIN * 2
	_scrollable = content > MAX_HEIGHT_PX
	_label.scroll_active = _scrollable
	var target := clampi(content, 80, MAX_HEIGHT_PX)
	if target != _h_px:
		_h_px = target
		_viewport.size = Vector2i(_w_px, _h_px)  # фон/лейбл с PRESET_FULL_RECT тянутся сами
		_build_quad()
	_update_thumb()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Двигает индикатор скролла под текущее положение: высота бегунка = доля видимого окна,
## позиция = доля прокрутки. Прячется, если прокручивать нечего.
func _update_thumb() -> void:
	if _thumb == null:
		return
	if not _scrollable:
		_thumb.visible = false
		return
	var bar := _label.get_v_scroll_bar()
	var maxv: float = bar.max_value
	var page: float = bar.page
	if bar == null or maxv <= page or maxv <= 0.0:
		_thumb.visible = false
		return
	var pad := 6.0
	var track := float(_h_px) - pad * 2.0
	var th := clampf(track * page / maxv, 28.0, track)
	var frac := clampf(bar.value / maxf(1.0, maxv - page), 0.0, 1.0)
	_thumb.position = Vector2(float(_w_px) - SCROLLBAR_W - 4.0, pad + frac * (track - th))
	_thumb.size = Vector2(SCROLLBAR_W, th)
	_thumb.visible = true
