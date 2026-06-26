extends Node

## Отладочная сцена геометрии (вид сверху): адрес -> HTML -> топология -> SpaceLayout ->
## 2D-раскладка комнат на сетке. Площадка для алгоритма ФОРМ комнат (пентамино + примыкание).
## SpaceLayout — тот же единый генератор пространства, что строит и реальное 3D-пространство
## (WorldGenerator). Здесь та же раскладка показана видом сверху. См. docs/geometry-lab.md.

@onready var _address: LineEdit = $"UI/PanelContainer/MarginContainer/HBoxContainer/address bar"
@onready var _go: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/go"

var _fetcher: PageFetcher
var _lab: SpaceLayout
var _view: GeometryTopView
var _details: RichTextLabel
var _status: Label

var _space: Dictionary = {}
var _layout: Dictionary = {}
var _seed: int = 0
var _loading := false


func _ready() -> void:
	_lab = SpaceLayout.new()
	_build_ui()

	_fetcher = PageFetcher.new()
	add_child(_fetcher)
	_fetcher.fetched.connect(_on_fetched)
	_fetcher.failed.connect(_on_failed)

	_go.pressed.connect(_on_go)
	_address.text_submitted.connect(func(_t): _on_go())
	_view.room_selected.connect(_on_room_selected)

	_set_status("Введите адрес и go! — ЛКМ-драг: панорама, колесо: зум, ⟳: новый seed")


func _build_ui() -> void:
	var ui: Control = $UI

	_view = GeometryTopView.new()
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.offset_top = 47.0
	ui.add_child(_view)

	# Зум + перегенерация в левом нижнем углу.
	var bar := VBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_left = 8.0
	bar.offset_top = -168.0
	bar.offset_bottom = -40.0
	bar.add_theme_constant_override("separation", 4)
	ui.add_child(bar)
	for spec in [["＋", func(): _view.zoom_by(1.25)],
			["－", func(): _view.zoom_by(0.8)],
			["⊡", func(): _view.fit_view()],
			["⟳", func(): _reseed()]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(36, 28)
		b.tooltip_text = "+/− зум, ⊡ вписать, ⟳ новый seed (та же топология, новая раскладка)"
		b.pressed.connect(spec[1])
		bar.add_child(b)

	# Панель параметров алгоритма (слева под навбаром).
	var params := PanelContainer.new()
	params.set_anchors_preset(Control.PRESET_TOP_LEFT)
	params.offset_left = 8.0
	params.offset_top = 55.0
	params.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(params)
	var pmargin := MarginContainer.new()
	for m in ["left", "top", "right", "bottom"]:
		pmargin.add_theme_constant_override("margin_" + m, 8)
	params.add_child(pmargin)
	var pbox := VBoxContainer.new()
	pbox.custom_minimum_size = Vector2(220, 0)
	pbox.add_theme_constant_override("separation", 2)
	pmargin.add_child(pbox)
	_add_slider(pbox, "Закрытие алковов", _lab.alcove_fill_chance, 0.0, 1.0, 0.05, false,
		func(v): _lab.alcove_fill_chance = v)
	_add_slider(pbox, "Подтягивание к родителю", _lab.pull_to_parent_chance, 0.0, 1.0, 0.05, false,
		func(v): _lab.pull_to_parent_chance = v)
	_add_slider(pbox, "Маршрут: избыточность", _lab.route_base_excess, 1.0, 3.0, 0.1, true,
		func(v): _lab.route_base_excess = v)
	_add_slider(pbox, "Маршрут: тупик ×", _lab.route_deadend_mult, 1.0, 4.0, 0.1, true,
		func(v): _lab.route_deadend_mult = v)
	_add_slider(pbox, "Маршрут: пентамино ×", _lab.route_pentomino_mult, 0.0, 1.5, 0.1, true,
		func(v): _lab.route_pentomino_mult = v)

	ui.move_child($"UI/PanelContainer", -1)

	var side := PanelContainer.new()
	side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	side.offset_left = -340.0
	side.offset_top = 47.0
	side.offset_bottom = -32.0
	side.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(side)

	var margin := MarginContainer.new()
	for m in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + m, 8)
	side.add_child(margin)

	var scroll := ScrollContainer.new()
	margin.add_child(scroll)
	_details = RichTextLabel.new()
	_details.bbcode_enabled = true
	_details.fit_content = true
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.custom_minimum_size = Vector2(320, 0)
	_details.text = "[i]Кликните комнату, чтобы увидеть её параметры.[/i]"
	scroll.add_child(_details)

	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = 8
	_status.offset_bottom = -8
	_status.offset_top = -32
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_status)


## Строка «название: значение» + ползунок. mult=false показывает проценты (доля [0..1]),
## mult=true — множитель «×N.N». На изменение зовёт on_set(value) и перестраивает раскладку с
## тем же seed (виден чистый эффект параметра).
func _add_slider(parent: VBoxContainer, title: String, value: float, lo: float, hi: float, step: float, mult: bool, on_set: Callable) -> void:
	var fmt := func(v): return "%s: ×%.1f" % [title, v] if mult else "%s: %d%%" % [title, int(round(v * 100.0))]
	var label := Label.new()
	label.text = fmt.call(value)
	parent.add_child(label)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(0, 18)
	parent.add_child(slider)
	slider.value_changed.connect(func(v):
		label.text = fmt.call(v)
		on_set.call(v)
		_rebuild())


func _on_go() -> void:
	var url := _address.text.strip_edges()
	if url == "" or _loading:
		return
	_loading = true
	_set_status("Загрузка %s …" % url)
	_fetcher.fetch(url, "")


func _on_fetched(html: String, final_url: String) -> void:
	_loading = false
	_address.text = final_url
	var doc := HtmlParser.parse(html)
	_space = TopologyBuilder.build(doc, true)
	_seed = hash(final_url)
	_rebuild()


func _on_failed(message: String, url: String) -> void:
	_loading = false
	_set_status("Ошибка: %s (%s)" % [message, url])


## Перегенерирует раскладку из той же топологии с новым seed — щупать стабильность алгоритма.
func _reseed() -> void:
	if _space.is_empty():
		return
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	_rebuild()


func _rebuild() -> void:
	if _space.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	_layout = _lab.build(_space, _seed)
	var dt := Time.get_ticks_msec() - t0
	_view.set_layout(_layout)
	_details.text = "[i]Кликните комнату, чтобы увидеть её параметры.[/i]"

	var rooms: Dictionary = _layout.get("rooms", {})
	var corridors: int = _layout.get("corridors", []).size()
	var cells := 0
	var virtual_walls := 0
	for id in rooms:
		cells += rooms[id].get("cells", []).size()
		virtual_walls += rooms[id].get("virtual_walls", []).size()
	_set_status("seed=%d — %d комнат, %d клеток, %d коридоров, %d виртуальных стен, %d мс" %
		[_seed, rooms.size(), cells, corridors, virtual_walls, dt])


func _on_room_selected(room_id: int) -> void:
	_details.text = _format_room(room_id)


func _format_room(room_id: int) -> String:
	var rooms: Dictionary = _layout.get("rooms", {})
	if not rooms.has(room_id):
		return "[i]Комната %d не найдена[/i]" % room_id
	var rd: Dictionary = rooms[room_id]
	var dims: Vector2i = rd.get("dims", Vector2i.ZERO)
	var pos: Vector2i = rd.get("pos", Vector2i.ZERO)
	var pieces: Array = rd.get("pieces", [])
	var cells: int = rd.get("cells", []).size()

	var s := "[b]#%d  %s[/b]" % [room_id, rd.get("kind", "room")]
	if room_id == _layout.get("root", -1):
		s += "  [color=#7fd8c0](root)[/color]"
	s += "\n\n"
	s += "[b]потребность[/b]: %d слот(ов)\n" % rd.get("need", 0)
	s += "[b]форма[/b]: %s\n" % rd.get("shape_kind", "")
	s += "[b]деталей[/b]: %d  (клеток: %d)\n" % [pieces.size(), cells]
	s += "[b]виртуальных стен[/b]: %d\n" % rd.get("virtual_walls", []).size()
	s += "[b]прямоугольник[/b]: %d×%d = %d клеток\n" % [dims.x, dims.y, dims.x * dims.y]
	if dims.x * dims.y > 0:
		var fill := 100.0 * float(cells) / float(dims.x * dims.y)
		s += "[b]заполнение[/b]: %d%% (хвост %d клеток)\n" % [int(fill), dims.x * dims.y - cells]
	s += "[b]позиция[/b]: (%d, %d)\n" % [pos.x, pos.y]
	return s


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
	print("[SpaceLayout] ", text)
