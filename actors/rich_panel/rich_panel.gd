class_name RichPanel
extends StaticBody3D

## Эктор-абзац: один блок форматированного текста с кликабельными inline-ссылками.
## Текст рендерится RichTextLabel'ом в SubViewport, кладётся текстурой на 3D-квад.
## Клик игрока (луч) мапится в координаты вьюпорта и синтетически прокидывается в
## RichTextLabel — тот сам определяет ссылку под точкой и эмитит meta_clicked.

signal link_activated(transition: Dictionary)

const GROUP := "rich_panel"
const PANEL_WIDTH_PX := 760
const PIXEL_PER_METER := 320.0   # перевод пикселей вьюпорта в метры квада
const FONT_SIZE := 24            # дефолтный кегль вьюпорта, если мир не задал свой
const MARGIN := 18

var _runs: Array = []
var _metas: Array = []           # индекс url-меты -> Transition
var _bbcode := ""
var _w_px := PANEL_WIDTH_PX
var _h_px := 120
var _font_size := FONT_SIZE      # кегль вьюпорта; мир задаёт его из базы текста страницы

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


## Маппит точку попадания луча в пиксель вьюпорта и «кликает» там за игрока.
func interact_at(point: Vector3) -> void:
	var quad := _mesh.mesh as QuadMesh
	if quad == null:
		return
	var local := to_local(point)
	var size := quad.size
	var u := clampf((local.x + size.x * 0.5) / size.x, 0.0, 1.0)
	var v := clampf((size.y * 0.5 - local.y) / size.y, 0.0, 1.0)
	var px := Vector2(u * _viewport.size.x, v * _viewport.size.y)
	_push_click(px)


func _push_click(px: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = px
		_viewport.push_input(ev, true)


func _on_meta_clicked(meta: Variant) -> void:
	var idx := int(str(meta))
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
	# Без рендера: грубая оценка по длине текста и переносам.
	var plain := ""
	var explicit_lines := 1
	for r in _runs:
		var t := str(r.get("text", ""))
		plain += t
		explicit_lines += t.count("\n")
	var usable := float(_w_px - MARGIN * 2)
	var chars_per_line: float = max(1.0, usable / (_font_size * 0.5))
	var wrapped := int(ceil(plain.length() / chars_per_line))
	var lines: int = max(explicit_lines, wrapped)
	var line_h := int(_font_size * 1.4)
	_h_px = clampi(lines * line_h + MARGIN * 2, 80, 1500)


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
	_label.offset_right = -MARGIN
	_label.offset_bottom = -MARGIN
	_label.bbcode_enabled = true
	_label.scroll_active = false
	_label.add_theme_font_size_override("normal_font_size", _font_size)
	_label.add_theme_font_size_override("bold_font_size", _font_size)
	if not _label.meta_clicked.is_connected(_on_meta_clicked):
		_label.meta_clicked.connect(_on_meta_clicked)
	_label.text = _bbcode


func _build_quad() -> void:
	var w_m := _w_px / PIXEL_PER_METER
	var h_m := _h_px / PIXEL_PER_METER

	var quad := QuadMesh.new()
	quad.size = Vector2(w_m, h_m)
	_mesh.mesh = quad

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _viewport.get_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_mesh.material_override = mat

	var box := BoxShape3D.new()
	box.size = Vector3(w_m, h_m, 0.08)
	_collision.shape = box
