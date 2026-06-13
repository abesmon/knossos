extends Node

## Отладочная сцена топологии: адрес -> загрузка HTML -> парсинг -> топология,
## и СРАЗУ визуализация артефакта графом (TopologyGraphView), без фазы геометрии.
## Назначение — глазами проверять результат контракции TopologyBuilder
## (см. docs/html-to-3d-topology.md, docs/implementation-phase1.md).

@onready var _address: LineEdit = $"UI/PanelContainer/MarginContainer/HBoxContainer/address bar"
@onready var _go: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/go"

var _fetcher: PageFetcher
var _graph: TopologyGraphView
var _details: RichTextLabel
var _status: Label
var _view_btn: Button
var _space: Dictionary = {}
var _loading := false


func _ready() -> void:
	_build_ui()

	_fetcher = PageFetcher.new()
	add_child(_fetcher)
	_fetcher.fetched.connect(_on_fetched)
	_fetcher.failed.connect(_on_failed)

	_go.pressed.connect(_on_go)
	_address.text_submitted.connect(func(_t): _on_go())
	_graph.node_selected.connect(_on_node_selected)

	_set_status("Введите адрес и go! — ЛКМ-драг: панорама, колесо: зум, клик по узлу: детали")


## Граф рисуем под навбаром во всю площадь; справа — панель деталей выбранного узла.
func _build_ui() -> void:
	var ui: Control = $UI

	_graph = TopologyGraphView.new()
	_graph.set_anchors_preset(Control.PRESET_FULL_RECT)
	_graph.offset_top = 47.0   # под навбаром
	ui.add_child(_graph)

	# Кнопки зума в левом нижнем углу (плюс колесо мыши над графом).
	var zoom_bar := VBoxContainer.new()
	zoom_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	zoom_bar.offset_left = 8.0
	zoom_bar.offset_top = -132.0
	zoom_bar.offset_bottom = -40.0
	zoom_bar.add_theme_constant_override("separation", 4)
	ui.add_child(zoom_bar)
	for spec in [["＋", func(): _graph.zoom_by(1.25)],
			["－", func(): _graph.zoom_by(0.8)],
			["⊡", func(): _graph.fit_view()]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(36, 28)
		b.tooltip_text = "Зум +/− , ⊡ — вписать"
		b.pressed.connect(spec[1])
		zoom_bar.add_child(b)

	# Переключатель режима раскладки (дерево / паук) — слева под навбаром.
	_view_btn = Button.new()
	_view_btn.text = "вид: дерево"
	_view_btn.tooltip_text = "Переключить раскладку: нисходящее дерево ↔ радиальный «паук»"
	_view_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_view_btn.offset_left = 8.0
	_view_btn.offset_top = 55.0
	_view_btn.pressed.connect(_toggle_layout)
	ui.add_child(_view_btn)

	# Навбар (PanelContainer) должен остаться поверх графа.
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
	_details.text = "[i]Кликните узел графа, чтобы увидеть его содержимое.[/i]"
	scroll.add_child(_details)

	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = 8
	_status.offset_bottom = -8
	_status.offset_top = -32
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_status)


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

	var t0 := Time.get_ticks_msec()
	var doc := HtmlParser.parse(html)
	# debug=true: артефакт несёт карту "sources" (id -> исходный HTML-кусок).
	_space = TopologyBuilder.build(doc, true)
	var dt := Time.get_ticks_msec() - t0

	_graph.set_space(_space)
	_details.text = "[i]Кликните узел графа, чтобы увидеть его содержимое.[/i]"

	var room_count: int = _space.get("rooms", {}).size()
	var labels: int = _space.get("labels", {}).size()
	_set_status("%s — %d узлов, %d якорей, %d мс" % [final_url, room_count, labels, dt])


func _on_failed(message: String, url: String) -> void:
	_loading = false
	_set_status("Ошибка: %s (%s)" % [message, url])


func _on_node_selected(room_id: int) -> void:
	_details.text = _format_room(room_id)


func _toggle_layout() -> void:
	var radial := _graph.get_layout() == TopologyGraphView.Layout.TREE
	_graph.set_layout(TopologyGraphView.Layout.RADIAL if radial else TopologyGraphView.Layout.TREE)
	_view_btn.text = "вид: паук" if radial else "вид: дерево"


## Человекочитаемый BBCode-дамп комнаты: вид, хинты, объекты (с функциями
## переходов и кратким контентом) и якоря, указывающие на эту комнату/объекты.
func _format_room(room_id: int) -> String:
	var rooms: Dictionary = _space.get("rooms", {})
	if not rooms.has(room_id):
		return "[i]Узел %d не найден[/i]" % room_id
	var room: Dictionary = rooms[room_id]
	var kind: String = room.get("kind", "room")
	var hints: Dictionary = room.get("hints", {})
	var objects: Array = room.get("objects", [])
	var children: Array = room.get("children", [])

	var s := "[b]#%d  %s[/b]" % [room_id, kind]
	if room_id == _space.get("root", -1):
		s += "  [color=#7fd8c0](root)[/color]"
	s += "\n"

	s += "\n[b]hints[/b]\n"
	for k in hints:
		s += "  • %s: %s\n" % [k, str(hints[k])]
	if hints.is_empty():
		s += "  [i]—[/i]\n"

	s += "\n[b]children[/b]: %s\n" % (str(children) if not children.is_empty() else "[i]—[/i]")

	s += "\n[b]objects (%d)[/b]\n" % objects.size()
	for o in objects:
		s += _format_object(o)
	if objects.is_empty():
		s += "  [i]—[/i]\n"

	# Якоря, ведущие в эту комнату или её объекты.
	var obj_ids := {}
	for o in objects:
		obj_ids[o.get("id", -1)] = true
	var anchors: Array = []
	for anchor in _space.get("labels", {}):
		var target = _space["labels"][anchor]
		if target == room_id or obj_ids.has(target):
			anchors.append("#%s→%s" % [anchor, str(target)])
	if not anchors.is_empty():
		s += "\n[b]anchors[/b]: %s\n" % ", ".join(anchors)

	# Исходный HTML-кусок, из которого собран этот узел.
	var src := str(_space.get("sources", {}).get(room_id, ""))
	if src != "":
		s += "\n[b]html[/b]\n[bgcolor=#11161f][code]%s[/code][/bgcolor]\n" % _escape(_truncate_block(src, 2000))

	return s


func _format_object(o: Dictionary) -> String:
	var type: String = o.get("type", "?")
	var line := "  [color=#cfe0ff]%s[/color] [color=#8893a8]#%d[/color]" % [type, o.get("id", -1)]
	var fn = o.get("function", null)
	if fn != null:
		line += " [color=#ffd84c]%s[/color]" % _format_function(fn)
	line += "\n"
	var content: Dictionary = o.get("content", {})
	var preview := _content_preview(type, content)
	if preview != "":
		line += "      [color=#9aa6bc]%s[/color]\n" % preview
	return line


func _format_function(fn: Dictionary) -> String:
	match fn.get("kind", ""):
		"navigate":
			return "→ %s" % fn.get("href", "")
		"teleport":
			return "⇲ #%s" % fn.get("target", "")
		"back":
			return "↩ back"
	return str(fn)


func _content_preview(type: String, content: Dictionary) -> String:
	match type:
		"list":
			var items: Array = content.get("items", [])
			var texts: Array = []
			for it in items:
				texts.append(_truncate(str(it.get("text", "")), 32))
			return "[%s]" % ", ".join(texts)
		"image":
			var alt := str(content.get("alt", content.get("src", "")))
			return "🖼 " + _truncate(alt, 60)
		_:
			var text := str(content.get("text", ""))
			return _escape(_truncate(text, 90))


func _truncate(s: String, n: int) -> String:
	s = s.replace("\n", " ").strip_edges()
	return s if s.length() <= n else s.substr(0, n) + "…"


# Обрезает многострочный блок (HTML), сохраняя переносы строк.
func _truncate_block(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n) + "\n…(обрезано)"


# BBCode съедает квадратные скобки — экранируем, чтобы контент не ломал разметку.
func _escape(s: String) -> String:
	return s.replace("[", "[lb]")


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
	print("[Topology] ", text)
