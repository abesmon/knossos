class_name ScriptingModulePermissionDialog
extends Window

## Preflight неизвестных exact hashes. Диалог возвращает session-решения для каждого модуля;
## варианты «всегда» дополнительно записываются вызывающей стороной в Settings.
signal decisions_submitted(decisions: Dictionary)

var _modules: Array = []
var _choices: Dictionary = {}
var _submitted := false


func _ready() -> void:
	title = "Внешние скрипты"
	min_size = Vector2i(760, 460)
	size = min_size
	transient = true
	exclusive = true
	close_requested.connect(_deny_all)


func present(modules: Array, page_url: String) -> void:
	_modules = modules
	_submitted = false
	for child in get_children():
		child.queue_free()
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)
	var root := VBoxContainer.new()
	root.name = "PermissionContent"
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	# Всё содержимое запроса прокручивается; строка финальных действий остаётся закреплённой
	# снизу и доступна даже при большом числе модулей или маленьком окне.
	var scroll := ScrollContainer.new()
	scroll.name = "PermissionScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var body := VBoxContainer.new()
	body.name = "PermissionBody"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)
	var warning := Label.new()
	warning.text = "Страница запрашивает запуск %d внешних модулей" % modules.size()
	warning.add_theme_color_override("font_color", Color(1.0, 0.72, 0.28))
	body.add_child(warning)
	var page := Label.new()
	page.text = page_url
	page.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	page.tooltip_text = page_url
	body.add_child(page)
	var hint := Label.new()
	hint.text = "Скрипты выполняются с правами приложения. Разрешайте только доверенный код.\nПо умолчанию каждый ресурс запрещён только для этой загрузки."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	var bulk := HBoxContainer.new()
	var allow_once := Button.new()
	allow_once.text = "Разрешить все один раз"
	allow_once.pressed.connect(_set_all.bind(1))
	bulk.add_child(allow_once)
	var allow_always := Button.new()
	allow_always.text = "Всегда разрешать эти версии"
	allow_always.pressed.connect(_set_all.bind(2))
	bulk.add_child(allow_always)
	body.add_child(bulk)
	var rows := VBoxContainer.new()
	rows.name = "PermissionRows"
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(rows)
	_choices.clear()
	for module in modules:
		_add_row(rows, module)
	var actions := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	var deny := Button.new()
	deny.text = "Запретить все"
	deny.pressed.connect(_deny_all)
	actions.add_child(deny)
	var submit := Button.new()
	submit.text = "Продолжить"
	submit.pressed.connect(_submit)
	actions.add_child(submit)
	root.add_child(actions)
	popup_centered()


func _add_row(parent: VBoxContainer, module: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name := Label.new()
	name.text = str(module.get("id", "без имени"))
	info.add_child(name)
	var source := Label.new()
	var url := str(module.get("resolved_url", "inline-код страницы"))
	source.text = url
	source.tooltip_text = url + "\nSHA-256: " + str(module.get("hash", ""))
	source.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	source.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	info.add_child(source)
	var fingerprint_row := HBoxContainer.new()
	var hash := str(module.get("hash", ""))
	var fingerprint := Label.new()
	fingerprint.text = "SHA-256: " + _short_fingerprint(hash)
	fingerprint.tooltip_text = "Полный SHA-256:\n" + hash
	fingerprint.add_theme_color_override("font_color", Color(0.8, 0.84, 0.9))
	fingerprint_row.add_child(fingerprint)
	var copy := Button.new()
	copy.text = "Копировать hash"
	copy.disabled = hash.is_empty()
	copy.tooltip_text = "Скопировать полный SHA-256 для сверки с поставщиком"
	copy.pressed.connect(func(): DisplayServer.clipboard_set(hash))
	fingerprint_row.add_child(copy)
	info.add_child(fingerprint_row)
	row.add_child(info)
	var choice := OptionButton.new()
	choice.add_item("Запретить сейчас", 0)
	choice.add_item("Разрешить один раз", 1)
	choice.add_item("Всегда разрешать эту версию", 2)
	choice.add_item("Всегда запрещать эту версию", 3)
	choice.select(0)
	row.add_child(choice)
	_choices[str(module.get("id", ""))] = choice
	parent.add_child(row)


static func _short_fingerprint(hash: String) -> String:
	if hash.is_empty():
		return "не вычислен"
	if hash.length() <= 27:
		return hash
	return hash.left(12) + "…" + hash.right(12)


func _set_all(index: int) -> void:
	for choice in _choices.values():
		(choice as OptionButton).select(index)


func _submit() -> void:
	if _submitted:
		return
	_submitted = true
	hide()
	var out := {}
	for module in _modules:
		var id := str(module.get("id", ""))
		var selected: int = (_choices[id] as OptionButton).selected
		out[id] = {"allow": selected in [1, 2], "remember": selected in [2, 3]}
	decisions_submitted.emit(out)
	queue_free()


func _deny_all() -> void:
	if _submitted:
		return
	_submitted = true
	hide()
	var out := {}
	for module in _modules:
		out[str(module.get("id", ""))] = {"allow": false, "remember": false}
	decisions_submitted.emit(out)
	queue_free()
