class_name RichPanel
extends StaticBody3D

## Эктор-абзац: один блок форматированного текста с кликабельными inline-ссылками.
## Текст рендерится RichTextLabel'ом в SubViewport, кладётся текстурой на 3D-квад.
## Клик игрока (луч) мапится в координаты вьюпорта и синтетически прокидывается в
## RichTextLabel — тот сам определяет ссылку под точкой и эмитит meta_clicked.

signal link_activated(transition: Dictionary)
signal size_changed(size: Vector2)

const GROUP := "rich_panel"
# Метрика мира: 1 м = 128 px вьюпорта. Та же линейка, что у текста и картинок снаружи
# (WorldGenerator.PX_PER_METER / ImagePanel.PX_PER_METER) — поэтому ширина колонки,
# инлайн-картинки в тексте и кегль шрифта консистентны с остальным миром.
const PIXEL_PER_METER := 128.0
# Ширина панели пружинит под контент (см. _upper_w_px/_refit): текст не шире TEXT_MAX_M, но
# картинка пошире расширяет панель под свою ширину; MIN_W_M — чтобы короткий текст не сжимался
# в нечитаемую полоску. MAX_HEIGHT_M — потолок высоты, выше него контент уходит в скролл.
const TEXT_MAX_M := 1.7
const MIN_W_M := 0.5
const MAX_HEIGHT_M := 2.6
const FONT_SIZE := 24            # дефолтный кегль вьюпорта, если мир не задал свой
const MARGIN := 18
const SCROLLBAR_W := 16          # ширина заметного скроллбара у прокручиваемых панелей, px
const TEXT_MAX_W_PX := int(TEXT_MAX_M * PIXEL_PER_METER)   # текст-кап ширины панели, px вьюпорта
const MIN_W_PX := int(MIN_W_M * PIXEL_PER_METER)
const MAX_HEIGHT_PX := int(MAX_HEIGHT_M * PIXEL_PER_METER)
const CHROME_PX := MARGIN * 2 + SCROLLBAR_W                # поля + жёлоб скроллбара по ширине
const PLACEHOLDER_COLOR := Color(0.18, 0.21, 0.28, 1.0)  # тон заглушки инлайн-картинки до загрузки

var _runs: Array = []
var _metas: Array = []           # индекс url-меты -> Transition
var _meta_alt: Dictionary = {}   # индекс url-меты -> alt картинки (для строки статуса)
var _w_px := TEXT_MAX_W_PX       # текущая ширина панели, px; пружинит под контент (см. _refit)
var _h_px := 120
var _font_size := FONT_SIZE      # кегль вьюпорта; мир задаёт его из базы текста страницы
var _probing := false            # is_active_at «кликает» вхолостую, чтобы узнать, есть ли ссылка
var _probe_hit := false          # результат такого пробного клика
var _probe_transition = null     # Transition под точкой пробного клика (для строки статуса)
var _probe_alt := ""             # alt картинки под точкой пробного клика (приоритетный текст статуса)
var _scrollable := false         # контент выше потолка ⇒ панель прокручивается колесом
var _thumb: ColorRect = null     # собственный индикатор скролла (штатный бар RichTextLabel прячем)
# Источник растрового инлайна: лоадер тянет текстуры картинок-прогонов, base_url резолвит src.
var _image_loader: ImageLoader = null
var _base_url := ""
var _placeholder_tex: Texture2D = null  # 1×1 заглушка под add_image до прихода текстуры
var _img_tex: Dictionary = {}    # url -> Texture2D (null = не удалось); результаты докачки картинок
var _img_requested: Dictionary = {}  # url'ы, по которым докачка уже запрошена (без дублей)
var _repopulate_queued := false  # дебаунс перезаполнения лейбла, когда подряд приходит несколько картинок

@onready var _viewport: SubViewport = $SubViewport
@onready var _bg: ColorRect = $SubViewport/Background
@onready var _label: RichTextLabel = $SubViewport/RichTextLabel
@onready var _mesh: MeshInstance3D = $Mesh
@onready var _collision: CollisionShape3D = $CollisionShape3D
var _mesh_back: MeshInstance3D = null   # изнанка: тот же квад, развёрнутый на 180° вокруг Y


## Вызывается ДО add_child: запоминает прогоны/источник картинок и оценивает высоту панели.
## font_world_m — желаемая мир-высота глифа (базовый текст страницы); <0 — дефолт.
## image_loader/base_url — чтобы картинки-прогоны подтянули реальную текстуру (см. _append_image).
func setup(runs: Array, font_world_m: float = -1.0, image_loader: ImageLoader = null,
		base_url := "") -> void:
	_runs = runs
	_image_loader = image_loader
	_base_url = base_url
	if font_world_m > 0.0:
		_font_size = max(8, int(round(font_world_m * PIXEL_PER_METER)))
	# Стартовая ширина — верхняя граница (текст-кап или самая широкая HTML-картинка). Точную
	# ширину под текст ужмёт _refit по факту раскладки, когда станет известна ширина контента.
	_w_px = _upper_w_px()
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
	_probe_alt = ""
	_push_click(px)
	_probing = false
	return _probe_hit


## Что под прицелом — для строки статуса. У картинки-ссылки показываем её alt (описание
## картинки) И куда ведёт переход; у текстовой ссылки — только переход. Переиспользует данные,
## пойманные последним пробным is_active_at (Player зовёт его в том же кадре перед этим).
func aim_hint_at(_point: Vector3) -> String:
	var dest := TransitionText.describe(_probe_transition)
	if _probe_alt == "":
		return dest
	return "%s  %s" % [_probe_alt, dest] if dest != "" else _probe_alt


## Точка попадания луча -> пиксель вьюпорта. Vector2(-1, -1) — квад ещё не построен.
func _point_to_px(point: Vector3) -> Vector2:
	var quad := _mesh.mesh as QuadMesh
	if quad == null:
		return Vector2(-1, -1)
	var local := to_local(point)
	var size := quad.size
	var u := clampf((local.x + size.x * 0.5) / size.x, 0.0, 1.0)
	var v := clampf((size.y * 0.5 - local.y) / size.y, 0.0, 1.0)
	# Изнанка (_mesh_back) развёрнута на 180° вокруг Y — её содержимое горизонтально
	# зеркально лицевому в локальных координатах. Луч попадает в ближнюю грань бокса:
	# local.z > 0 — клик спереди, local.z < 0 — со стороны изнанки; там отражаем u,
	# чтобы пиксель вьюпорта совпал с тем, что игрок реально видит сзади. v не трогаем
	# (разворот вокруг Y вертикаль не меняет).
	if local.z < 0.0:
		u = 1.0 - u
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
			_probe_alt = str(_meta_alt.get(idx, ""))
		return
	if idx >= 0 and idx < _metas.size():
		link_activated.emit(_metas[idx])


# --- Сборка ---

## Заполняет RichTextLabel прогонами: текст/ссылки — bbcode'ом через append_text, картинки —
## реальной текстурой через add_image (см. _append_image). Каждый вызов перерисовывает лейбл
## целиком из текущего состояния (_runs + докачанные _img_tex), поэтому по приходе текстуры мы
## просто перезаполняем его заново (_schedule_repopulate). Метаданные ссылок (_metas/_meta_alt)
## собираем тут же, в порядке добавления, чтобы [url=idx] и push_meta ссылались на общий индекс.
func _populate_label() -> void:
	_metas.clear()
	_meta_alt.clear()
	_label.clear()
	for r in _runs:
		if str(r.get("type", "")) == "image":
			_append_image(r)
		else:
			_label.append_text(_text_run_bbcode(r))


## bbcode одного текстового прогона; ссылку регистрирует в _metas и красит по виду перехода.
func _text_run_bbcode(r: Dictionary) -> String:
	var text := str(r.get("text", "")).replace("[", "[lb]")
	var fn = r.get("function", null)
	if fn != null and typeof(fn) == TYPE_DICTIONARY:
		var idx := _metas.size()
		_metas.append(fn)
		var col := "#9be7ff"  # teleport (внутристраничный якорь) по умолчанию
		match fn.get("kind", ""):
			"navigate": col = "#5cc8ff"
			"external": col = "#c69bff"  # выход во внешнее приложение
		return "[color=%s][u][url=%d]%s[/url][/u][/color]" % [col, idx, text]
	return text


## Картинка-прогон: вставляем растровую текстуру прямо в поток текста. До прихода текстуры —
## серая заглушка нужного размера, после докачки — настоящая картинка (перезаполнением лейбла).
## Не удалось загрузить или нет лоадера/src — показываем alt текстовым токеном 🖼. Картинку-ссылку
## делаем кликабельной прямо по изображению: оборачиваем add_image в push_meta/pop, тогда клик
## луча (синтетический клик во вьюпорте) попадает в meta-регион и эмитит meta_clicked — отдельная
## подпись-ссылка больше не нужна. alt такой картинки уходит в строку статуса (см. aim_hint_at).
func _append_image(r: Dictionary) -> void:
	var url := _run_url(r)
	var alt := str(r.get("alt", "")).strip_edges()
	var fn = r.get("function", null)
	var has_link: bool = fn != null and typeof(fn) == TYPE_DICTIONARY

	# Нет растрового источника или докачка не удалась — текстовый токен 🖼 alt (кликабельный
	# как ссылка, если картинка завёрнута в <a>). Сам src/лоадер недоступны либо _img_tex=null.
	if url == "" or _image_loader == null or (_img_tex.has(url) and _img_tex[url] == null):
		_label.append_text(_image_token(r))
		return

	# Запрашиваем текстуру один раз на url; результат осядет в _img_tex и перезапустит заполнение.
	if not _img_requested.has(url):
		_img_requested[url] = true
		_image_loader.request_image(url, func(t: Texture2D): _on_image_result(url, t))

	var tex: Texture2D = _img_tex.get(url, null)  # null здесь = ещё грузится (failed отсеян выше)
	var tex_px := Vector2.ZERO
	if tex != null:
		tex_px = Vector2(tex.get_size())
	var size := _inline_size(r, tex_px)

	# Ссылка-картинка: push_meta делает кликабельным сам [img] (meta_clicked по клику в регион).
	if has_link:
		var idx := _metas.size()
		_metas.append(fn)
		_meta_alt[idx] = alt
		# Подчёркивание meta (как у текстовых ссылок) под картинкой смотрелось бы линией снизу —
		# гасим его: сигналом «это ссылка» служит курсор Player'а и alt в строке статуса.
		_label.push_meta(str(idx), RichTextLabel.META_UNDERLINE_NEVER)
	if tex != null:
		_label.add_image(tex, size.x, size.y, Color.WHITE, INLINE_ALIGNMENT_CENTER)
	else:
		_label.add_image(_get_placeholder(), size.x, size.y, PLACEHOLDER_COLOR,
			INLINE_ALIGNMENT_CENTER)
	if has_link:
		_label.pop()


## Докачка картинки завершилась (tex=null — не удалось): кэшируем результат по url и
## перезаполняем лейбл, чтобы заглушка сменилась картинкой (или alt-токеном при провале).
func _on_image_result(url: String, tex: Texture2D) -> void:
	if not is_instance_valid(self):
		return
	_img_tex[url] = tex
	_schedule_repopulate()


## Дебаунс: несколько картинок, пришедших в одном кадре, дают одно перезаполнение и один _refit.
func _schedule_repopulate() -> void:
	if _repopulate_queued:
		return
	_repopulate_queued = true
	_do_repopulate.call_deferred()


func _do_repopulate() -> void:
	_repopulate_queued = false
	if not is_instance_valid(self):
		return
	_populate_label()
	_refit()  # пересчитает высоту под подросший контент и попросит перерисовать кадр


## Размер инлайн-картинки в пикселях вьюпорта (= px страницы: вьюпорт 1:1, PIXEL_PER_METER).
## Приоритет — размеры из HTML (width_px/height_px); недостающее измерение берём из пропорций
## реальной текстуры. Без размеров в HTML берём СОБСТВЕННОЕ разрешение картинки (как ImagePanel),
## чтобы инлайн и отдельная картинка одного источника совпадали по размеру. Ширину капим под
## колонку текста, чтобы картинка не вылезала за панель и скроллбар.
func _inline_size(r: Dictionary, tex_px: Vector2) -> Vector2i:
	var content_w := float(_w_px - MARGIN * 2 - SCROLLBAR_W)
	var aspect := (tex_px.x / tex_px.y) if (tex_px.x > 0.0 and tex_px.y > 0.0) else -1.0
	var w := float(r.get("width_px", 0.0))
	var h := float(r.get("height_px", 0.0))
	if w > 0.0 and h > 0.0:
		pass
	elif w > 0.0:
		h = (w / aspect) if aspect > 0.0 else w * 0.66
	elif h > 0.0:
		w = (h * aspect) if aspect > 0.0 else h / 0.66
	elif tex_px.x > 0.0:
		w = tex_px.x
		h = tex_px.y
	else:
		# Текстура ещё не пришла — временный дефолт до перезаполнения по _on_image_result.
		w = minf(content_w, 360.0)
		h = w * 0.66
	if w > content_w:
		h *= content_w / w
		w = content_w
	return Vector2i(maxi(1, int(round(w))), maxi(1, int(round(h))))


## Ленивая 1×1 белая текстура под add_image: реальный размер задаёт сам add_image, а тон
## заглушки — параметром color (PLACEHOLDER_COLOR), пока не пришла настоящая текстура.
func _get_placeholder() -> Texture2D:
	if _placeholder_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_placeholder_tex = ImageTexture.create_from_image(img)
	return _placeholder_tex


## Картинка-прогон без растрового рендера (нет лоадера/src или докачка не удалась): показываем
## alt (или маркер 🖼) токеном — кликабельным, если у картинки есть функция перехода.
func _image_token(r: Dictionary) -> String:
	var alt := str(r.get("alt", "")).strip_edges()
	var label := ("🖼 " + alt) if alt != "" else "🖼"
	label = label.replace("[", "[lb]")
	var fn = r.get("function", null)
	if fn != null and typeof(fn) == TYPE_DICTIONARY:
		var idx := _metas.size()
		_metas.append(fn)
		_meta_alt[idx] = alt
		var col := "#5cc8ff"  # navigate по умолчанию
		match fn.get("kind", ""):
			"teleport": col = "#9be7ff"
			"external": col = "#c69bff"
		return "[color=%s][u][url=%d]%s[/url][/u][/color]" % [col, idx, label]
	return "[color=#9fb0c0]%s[/color]" % label


func _estimate_height() -> void:
	_h_px = estimate_height_px(_runs, _font_size, _w_px)


## Оценка высоты панели (px) по длине текста и переносам — БЕЗ рендера. static, чтобы
## WorldGenerator мог замерить будущую панель тем же кодом, что и сама панель (футпринт
## для раскладки и фактическая геометрия совпадают). См. WorldGenerator._measure_object.
static func estimate_height_px(runs: Array, font_size: int, w_px: int = TEXT_MAX_W_PX) -> int:
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


## Верхняя граница ширины панели (px): текст не шире текст-капа, но картинка пошире расширяет
## панель под себя (ширина самой широкой картинки + хром). static, чтобы WorldGenerator брал тот
## же футпринт по ширине. Учитывает только HTML-размер картинок (реальное разрешение неизвестно
## до загрузки); рантайм может подрасти под интринзик-размер уже загруженной текстуры.
static func estimate_width_px(runs: Array) -> int:
	var img := 0
	for r in runs:
		if str(r.get("type", "")) == "image":
			img = maxi(img, int(r.get("width_px", 0)))
	return maxi(TEXT_MAX_W_PX, img + CHROME_PX) if img > 0 else TEXT_MAX_W_PX


## Та же оценка ширины в метрах квада — для футпринта WorldGenerator.
static func estimate_width_m(runs: Array) -> float:
	return float(estimate_width_px(runs)) / PIXEL_PER_METER


## Верхняя граница ширины конкретной панели (px). В отличие от static estimate_width_px, видит
## реальное разрешение уже докачанных картинок-прогонов (важно для картинок без HTML-размеров).
func _upper_w_px() -> int:
	var img := _widest_image_px()
	return maxi(TEXT_MAX_W_PX, img + CHROME_PX) if img > 0 else TEXT_MAX_W_PX


## Ширина самой широкой картинки-прогона, px: размер из HTML width_px, иначе собственное
## разрешение уже загруженной текстуры (0, если её ещё нет — учтём при перезаполнении).
func _widest_image_px() -> int:
	var best := 0
	for r in _runs:
		if str(r.get("type", "")) != "image":
			continue
		var w := int(r.get("width_px", 0))
		if w <= 0:
			var tex: Texture2D = _img_tex.get(_run_url(r), null)
			if tex != null:
				w = int(tex.get_size().x)
		best = maxi(best, w)
	return best


## URL картинки-прогона (резолв src относительно base_url) — общий с _append_image/_widest_image_px.
func _run_url(r: Dictionary) -> String:
	var src := str(r.get("src", "")).strip_edges()
	return PageFetcher.resolve_url(src, _base_url) if src != "" else ""


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
	_populate_label()

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
		# Каждая грань рисуется только со своей стороны (CULL_BACK), а изнанку даёт
		# второй квад, развёрнутый на 180° вокруг Y (_mesh_back). Так панель читается
		# одинаково с обеих сторон, без зеркала, которое давала единая двусторонняя грань.
		mat.cull_mode = BaseMaterial3D.CULL_BACK
		mat.albedo_texture = _viewport.get_texture()
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_mesh.material_override = mat

	# Изнанка: тот же меш и материал, развёрнут на 180° вокруг Y — обращён назад и
	# показывает панель в нормальной (не зеркальной) ориентации.
	if _mesh_back == null:
		_mesh_back = MeshInstance3D.new()
		_mesh_back.rotation = Vector3(0, PI, 0)
		_mesh.add_child(_mesh_back)
	_mesh_back.mesh = _mesh.mesh
	_mesh_back.material_override = _mesh.material_override

	var box := _collision.shape as BoxShape3D
	if box == null:
		box = BoxShape3D.new()
		_collision.shape = box
	box.size = Vector3(w_m, h_m, 0.08)


## После реальной раскладки текста подгоняем панель под факт: сперва ШИРИНУ (пружиним до
## ширины контента — короткий текст не растягивается до текст-капа, но картинка пошире держит
## панель широкой), затем ВЫСОТУ (get_content_height; оценка _estimate_height её занижала,
## отсюда обрезанные снизу панели). Контент выше потолка MAX_HEIGHT_PX уходит в скролл.
func _refit() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(self):
		return
	var old_size := _current_size_m()
	# Ширина: ужимаем до фактической ширины контента, но не уже MIN и не шире верхней границы
	# (текст-кап / самая широкая картинка). get_content_width при включённом переносе вернёт
	# ширину самой длинной строки — для короткого текста это даст узкую панель.
	var upper := _upper_w_px()
	var cw := _label.get_content_width()
	var new_w := clampi(int(ceil(cw)) + CHROME_PX, MIN_W_PX, upper) if cw > 0 else upper
	if new_w != _w_px:
		_w_px = new_w
		_viewport.size = Vector2i(_w_px, _h_px)
		# Дать тексту переразложиться под новую ширину, прежде чем мерить высоту.
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
	_h_px = clampi(content, 80, MAX_HEIGHT_PX)
	_viewport.size = Vector2i(_w_px, _h_px)  # фон/лейбл с PRESET_FULL_RECT тянутся сами
	_build_quad()
	_update_thumb()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var new_size := _current_size_m()
	if old_size.distance_to(new_size) > 0.01:
		size_changed.emit(new_size)


func _current_size_m() -> Vector2:
	return Vector2(float(_w_px) / PIXEL_PER_METER, float(_h_px) / PIXEL_PER_METER)


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
