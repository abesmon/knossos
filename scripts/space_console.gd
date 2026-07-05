class_name SpaceConsole
extends PanelContainer

## Консоль пространства (клавиша `~`, как DevTools в браузере): показывает HTML-репрезентацию
## текущего пространства. Два редактора — ничего не реконструируется из геометрии
## (см. docs/space-console.md):
##   • страница (процедурный HTML, без <vrweb>) — сериализация ХРАНИМОГО дерева HtmlNode.
##     Read-only ФИЗИЧЕСКИ: процедурную часть править бессмысленно;
##   • СЦЕНА — единый СЛИТЫЙ блок <vrweb>: узлы страницы с применёнными эфемерными патчами +
##     добавленные узлы + мировые объекты (пузыри/штрихи). Пользователь редактирует его как
##     одну сущность, не думая, что запечено в страницу, а что — эфемерная дельта.
## «Сохранить» пересчитывает правку В ДЕЛЬТУ (SceneHtml.diff_scene: vrweb-patch/vrweb-node/
## мировые объекты) и шлёт ТОЛЬКО её авторитету с обратной связью
## (request_scene_action_tracked). На время отправки документ блокируется; отказ НЕ стирает
## правку пользователя — панель обводится красным. «Отменить» возвращает актуальное состояние.

## Ожидание ack от авторитета: не ответил (ушёл/потеря) — считаем правку отклонённой.
const ACK_TIMEOUT_SEC := 5.0
## Подсказка по умолчанию в строке статуса.
const HINT := "Правьте блок <vrweb> — наружу уйдёт только дельта · Ctrl/Cmd+S — сохранить · ~ — закрыть"

var _page_view: CodeEdit       # страница: только чтение (контекст пространства)
var _editor: CodeEdit          # слитый блок <vrweb>: единственная редактируемая область
var _status: Label
var _save_btn: Button
var _cancel_btn: Button
var _flush_btn: Button         # «В страницу»: флаш дельты на сервер (docs/page-persistence.md)
var _get_page_html: Callable   # () -> String — хранимое дерево страницы БЕЗ <vrweb> (main)
var _get_page_index: Callable  # () -> Dictionary — индекс vrweb-узлов страницы (main)
var _get_page_url: Callable    # () -> String — URL текущей страницы (main._current_url)
var _pristine := ""            # последний отрендеренный блок: text == _pristine → правок нет
var _pending := {}             # token -> true: ждём ack; документ заблокирован
var _sent_total := 0           # сколько действий ушло в текущем сохранении
var _failed := 0               # сколько из них отклонено (или не отвечено)
var _flushing := false         # идёт POST флаша — документ заблокирован
var _timeout: Timer
var _style_normal: StyleBoxFlat
var _style_error: StyleBoxFlat
var _crypto := Crypto.new()    # nonce для payload флаша


## Колбэки main: get_page_html — сериализация документа страницы без <vrweb>;
## get_page_index — индекс vrweb-узлов страницы (SceneHtml.build_page_index);
## get_page_url — URL текущей страницы (для payload флаша и same-origin проверки).
func setup(get_page_html: Callable, get_page_index: Callable, get_page_url: Callable) -> void:
	_get_page_html = get_page_html
	_get_page_index = get_page_index
	_get_page_url = get_page_url


func _ready() -> void:
	visible = false
	_build_ui()
	NetworkManager.scene_object_added.connect(func(_id, _o): _on_scene_changed())
	NetworkManager.scene_object_updated.connect(func(_id, _o): _on_scene_changed())
	NetworkManager.scene_object_removed.connect(func(_id): _on_scene_changed())
	NetworkManager.scene_reset.connect(_on_scene_changed)
	NetworkManager.scene_action_acked.connect(_on_acked)

	_timeout = Timer.new()
	_timeout.one_shot = true
	_timeout.wait_time = ACK_TIMEOUT_SEC
	_timeout.timeout.connect(_on_ack_timeout)
	add_child(_timeout)


func _build_ui() -> void:
	# Нижняя половина экрана, во всю ширину (как панель DevTools).
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 0.52
	anchor_bottom = 1.0
	offset_left = 0
	offset_right = 0
	offset_top = 0
	offset_bottom = 0

	# Красная обводка отклонённой правки — сменой стиля панели.
	_style_normal = StyleBoxFlat.new()
	_style_normal.bg_color = Color(0.09, 0.1, 0.12, 0.97)
	_style_normal.set_border_width_all(2)
	_style_normal.border_color = Color(0.25, 0.27, 0.32)
	_style_error = _style_normal.duplicate()
	_style_error.border_color = Color(0.9, 0.2, 0.2)
	add_theme_stylebox_override("panel", _style_normal)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Консоль пространства"
	header.add_child(title)

	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.add_theme_color_override("font_color", Color(0.62, 0.65, 0.7))
	_status.text = HINT
	header.add_child(_status)

	_cancel_btn = Button.new()
	_cancel_btn.text = "Отменить"
	_cancel_btn.pressed.connect(_on_cancel)
	header.add_child(_cancel_btn)

	_save_btn = Button.new()
	_save_btn.text = "Сохранить"
	_save_btn.pressed.connect(_on_save)
	header.add_child(_save_btn)

	# Флаш дельты в страницу (persist-атрибут блока <vrweb>): видна только на страницах,
	# анонсирующих персистенцию. См. docs/page-persistence.md.
	_flush_btn = Button.new()
	_flush_btn.text = "В страницу"
	_flush_btn.tooltip_text = "Сохранить накопленную дельту оверлея в саму страницу на её сервере"
	_flush_btn.pressed.connect(_on_flush)
	header.add_child(_flush_btn)

	# Две области с перетаскиваемым разделителем: страница (read-only) и <ephemeral>.
	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(split)

	_page_view = _make_code_edit()
	_page_view.editable = false
	# Приглушаем read-only текст, чтобы редактируемая область читалась как «рабочая».
	_page_view.add_theme_color_override("font_readonly_color", Color(0.55, 0.58, 0.63))
	split.add_child(_section("Страница (процедурный HTML) — только чтение", _page_view))

	_editor = _make_code_edit()
	# Ctrl/Cmd+S внутри редактора — «Сохранить».
	_editor.gui_input.connect(_on_editor_input)
	split.add_child(_section("Сцена <vrweb> — страница + эфемерные изменения (единый слой)", _editor))


func _make_code_edit() -> CodeEdit:
	var edit := CodeEdit.new()
	edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit.gutters_draw_line_numbers = true
	edit.indent_size = 2
	edit.scroll_smooth = true
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Menlo", "Consolas", "DejaVu Sans Mono", "monospace"])
	edit.add_theme_font_override("font", mono)
	edit.add_theme_font_size_override("font_size", 13)
	return edit


## Секция сплита: подпись + редактор.
func _section(caption: String, edit: CodeEdit) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var label := Label.new()
	label.text = caption
	label.add_theme_color_override("font_color", Color(0.5, 0.53, 0.58))
	label.add_theme_font_size_override("font_size", 11)
	box.add_child(label)
	box.add_child(edit)
	return box


# --- Открытие/закрытие ---

func open() -> void:
	visible = true
	# Консоль перекрывает остальной UI. Чат/навбар/настройки добавляются в дерево позже
	# (см. main._setup_net) и без этого рисовались бы поверх нижней половины экрана.
	# move_to_front делает нас последним ребёнком родителя → рисуемся над сиблингами.
	move_to_front()
	# Несохранённую правку не затираем (после отказа она остаётся до явной «Отменить»).
	if _pending.is_empty() and _editor.text == _pristine:
		_refresh()
	_editor.grab_focus()


func close() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close()
	else:
		open()


## Навигация на другую страницу: старый документ и правки к нему больше не имеют смысла —
## перерисовываем безусловно. Зовёт main из _finish_page.
func on_navigated() -> void:
	_abort_pending()
	_refresh(false)


# --- Рендер документа ---

## preserve — сохранить позицию каретки и скролл (после сохранения/живого обновления текст
## переприсваивается, а это иначе бросило бы каретку в начало). При навигации/первом
## открытии не нужно — там документ другой.
func _refresh(preserve := true) -> void:
	_page_view.text = str(_get_page_html.call()) if _get_page_html.is_valid() else ""
	_pristine = SceneHtml.serialize_scene(_page_index(), NetworkManager.scene_objects()) + "\n"
	_apply_editor_text(_pristine, preserve)
	# «В страницу» — только на страницах, анонсирующих персистенцию (persist на блоке <vrweb>).
	if _flush_btn != null:
		_flush_btn.visible = _persist_endpoint() != ""
	_mark_error(false)
	_set_status(HINT)


## Присваивает текст редактору, при необходимости удерживая каретку и скролл на месте
## (позиции клампятся к новому содержимому — после сохранения текст мог переформатироваться).
func _apply_editor_text(text: String, preserve: bool) -> void:
	if not preserve:
		_editor.text = text
		return
	var line := _editor.get_caret_line()
	var col := _editor.get_caret_column()
	var v_scroll := _editor.scroll_vertical
	var h_scroll := _editor.scroll_horizontal
	_editor.text = text
	line = clampi(line, 0, maxi(_editor.get_line_count() - 1, 0))
	# adjust_viewport=false: сами вернём скролл ниже, чтобы каретка его не «дёрнула».
	_editor.set_caret_line(line, false)
	_editor.set_caret_column(clampi(col, 0, _editor.get_line(line).length()), false)
	_editor.scroll_vertical = v_scroll
	_editor.scroll_horizontal = h_scroll


func _page_index() -> Dictionary:
	if _get_page_index.is_valid():
		return _get_page_index.call()
	return {"found": false, "attrs": {}, "top": [], "nodes": {}}


## Эфемерный слой изменился (событие сети / TTL / снимок). Обновляем только «чистый»
## документ; правку пользователя не затираем — подсказываем про «Отменить».
func _on_scene_changed() -> void:
	if not visible or not _pending.is_empty():
		return
	if _editor.text == _pristine:
		_refresh()
	else:
		_set_status("Пространство изменилось — «Отменить» покажет актуальное состояние")


# --- Сохранение ---

func _on_save() -> void:
	if not _pending.is_empty():
		return
	if _editor.text == _pristine:
		_set_status("Изменений нет")
		return
	var root := HtmlParser.parse(_editor.text)
	var stray := _stray_content(root)
	if stray != "":
		_reject("Не сохранено: вне блока <%s> ничего быть не должно (%s)" % [SceneHtml.SCENE_TAG, stray])
		return
	var parsed := SceneHtml.parse_scene(root)
	if not parsed["ok"]:
		_reject("Не сохранено: %s" % parsed["error"])
		return
	# Дельта: правки узлов страницы -> vrweb-patch, новые узлы -> vrweb-node, мировые -> kind.
	var d := SceneHtml.diff_scene(_page_index(), NetworkManager.scene_objects(),
		parsed, NetworkManager.new_object_id)
	if not d["ok"]:
		_reject("Не сохранено: %s" % d["error"])
		return
	var actions: Array = d["actions"]
	if actions.is_empty():
		_refresh()
		_set_status("Изменений нет")
		return
	if not NetworkManager.in_room():
		_reject("Не сохранено: вне комнаты, изменения некуда отправить")
		return
	# Блокируем документ и шлём ТОЛЬКО изменения (не весь документ) — каждое действие
	# отслеживается токеном, исход соберут _on_acked/_on_ack_timeout.
	_sent_total = actions.size()
	_failed = 0
	_lock(true)
	_set_status("Отправка %d изменений…" % _sent_total)
	for a in actions:
		_pending[NetworkManager.request_scene_action_tracked(a)] = true
	_timeout.start()


func _on_acked(token: int, accepted: bool) -> void:
	if not _pending.erase(token):
		return
	if not accepted:
		_failed += 1
	if _pending.is_empty():
		_finish_save()


## Авторитет не ответил (роль могла смениться, пока действие летело): неотвеченные
## действия считаем отклонёнными.
func _on_ack_timeout() -> void:
	if _pending.is_empty():
		return
	_failed += _pending.size()
	_pending.clear()
	_finish_save()


func _finish_save() -> void:
	_timeout.stop()
	_lock(false)
	if _failed == 0:
		_refresh()
		_set_status("Сохранено: %d изменений" % _sent_total)
	else:
		# Правка пользователя остаётся в редакторе — только обводим красным.
		_mark_error(true)
		_set_status("Авторитет отклонил %d из %d изменений — правка не сохранена" % [_failed, _sent_total])


## Прервать ожидание ack (навигация): исход старой комнаты уже не важен.
func _abort_pending() -> void:
	_timeout.stop()
	_pending.clear()
	_lock(false)


func _on_cancel() -> void:
	if not _pending.is_empty():
		return
	_refresh()
	_set_status("Правки отменены")


# --- Флаш: сохранить дельту оверлея В СТРАНИЦУ (docs/page-persistence.md) ---

## Endpoint персистенции с блока <vrweb> ("" — страница read-only). Принимаем только
## same-origin с самой страницей: чужому origin подписанные дельты не отправляем.
func _persist_endpoint() -> String:
	var attrs: Dictionary = _page_index().get("attrs", {})
	var persist := str(attrs.get("persist", "")).strip_edges()
	if persist == "" or not _get_page_url.is_valid():
		return ""
	if _host_of(persist) == "" or _host_of(persist) != _host_of(str(_get_page_url.call())):
		return ""
	return persist


## Дельта для флаша: постоянные (ttl=0) объекты оверлея vrweb, в порядке родители-раньше-детей.
## vrweb-node, чей id уже есть в базе (запечён прошлым флашем), не отправляем — сервер всё
## равно ответил бы «already persisted».
func _flush_objects() -> Array:
	var page_nodes: Dictionary = _page_index().get("nodes", {})
	var objects := NetworkManager.scene_objects()
	var out: Array = []
	for id in objects:
		var o: Dictionary = objects[id]
		var kind := str(o.get("kind", ""))
		if float(o.get("ttl", 0.0)) != 0.0:
			continue
		if kind == SceneHtml.KIND_PATCH or (kind == SceneHtml.KIND_NODE and not page_nodes.has(id)):
			out.append({"id": str(id), "kind": kind, "parent": str(o.get("parent", "")),
				"props": o.get("props", {})})
	# Родители раньше детей: вложенный vrweb-node сервер монтирует под уже вставленного.
	var depth := func(oid: String) -> int:
		var d := 0
		var cur := str(objects.get(oid, {}).get("parent", ""))
		while objects.has(cur) and d < 64:
			cur = str(objects[cur].get("parent", ""))
			d += 1
		return d
	out.sort_custom(func(a, b) -> bool: return depth.call(a["id"]) < depth.call(b["id"]))
	return out


func _on_flush() -> void:
	if _flushing or not _pending.is_empty():
		return
	if _editor.text != _pristine:
		_set_status("Сначала «Сохранить» (или «Отменить») правки — в страницу уходит сохранённая дельта")
		return
	var endpoint := _persist_endpoint()
	if endpoint == "":
		_set_status("Страница не принимает персистенцию")
		return
	var objects := _flush_objects()
	if objects.is_empty():
		_set_status("Нечего сохранять в страницу — дельта пуста или уже запечена")
		return
	var base_rev := str(_page_index().get("attrs", {}).get("rev", ""))
	# payload подписывается и уходит ВЕРБАТИМ строкой — серверу не нужно воспроизводить
	# нашу сериализацию (тот же приём, что certificate_json). См. docs/page-persistence.md.
	var payload := JSON.stringify({
		"v": 1, "url": str(_get_page_url.call()), "base_rev": base_rev,
		"ts": int(Time.get_unix_time_from_system()),
		"nonce": Marshalls.raw_to_base64(_crypto.generate_random_bytes(16)),
		"objects": objects,
	})
	var body := {"v": 1, "payload": payload}
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	# Авторизация: Bearer своему домашнему серверу (дёшево, так входит владелец) или
	# федеративная пара сертификат + proof-подпись (редактор на чужом сервере).
	var auth: String = HomeServer.auth_header_for(endpoint)
	if auth != "":
		headers.append(auth)
	elif HomeServer.has_certificate():
		var sig: String = HomeServer.sign_flush_payload(payload)
		if sig == "":
			_reject("Не удалось подписать запрос ключом идентичности")
			return
		var cp: Array = HomeServer.certificate_payload()
		body["identity"] = {"certificate_json": cp[0], "signature": cp[1]}
		body["proof_signature"] = sig
	else:
		_reject("Флаш требует идентичности: войдите на домашний сервер (вкладка «Аккаунт»)")
		return

	_flushing = true
	_lock(true)
	_set_status("Сохранение в страницу (%d объектов)…" % objects.size())
	var req := HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	var err := req.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		_finish_flush(false, "Не удалось начать запрос (код %d)" % err)
		return
	var res: Array = await req.request_completed
	req.queue_free()
	_on_flush_completed(int(res[0]), int(res[1]), res[3] as PackedByteArray)


func _on_flush_completed(result: int, code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish_flush(false, "Сетевая ошибка (result %d)" % result)
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if code == 409:
		# Version skew: база изменилась между загрузкой и флашем — дельту надо пересобрать
		# против свежей базы (перезагрузка страницы), см. docs/page-persistence.md.
		_finish_flush(false, "База страницы изменилась — обновите страницу (⟳) и повторите")
		return
	if code != 200 or typeof(data) != TYPE_DICTIONARY:
		var msg := "Сервер отказал (HTTP %d)" % code
		if typeof(data) == TYPE_DICTIONARY and typeof(data.get("error")) == TYPE_DICTIONARY:
			msg = str(data["error"].get("message", msg))
		_finish_flush(false, msg)
		return
	# Принятые объекты помечаем persisted_rev обычным update слоя: UI и будущий GC видят
	# «запечено», а дедуп у пиров на новой базе держится на id и без пометки. Чужие объекты
	# авторитет отклонит по владению — это ок, пометка не обязана пройти у всех.
	var rev := str(data.get("rev", ""))
	var applied := 0
	var results: Dictionary = data.get("results", {})
	for id in results:
		if str(results[id].get("outcome", "")) == "applied":
			applied += 1
			NetworkManager.request_scene_action({"op": SceneChanges.OP_UPDATE, "id": str(id),
				"props": {"persisted_rev": rev}})
	var total := results.size()
	if applied == total and applied > 0:
		_finish_flush(true, "Запечено в страницу: %d объектов (rev %s). Новые посетители получат их из базы" % [applied, rev])
	elif applied > 0:
		_finish_flush(false, "Частично: %d из %d запечено (rev %s) — остальным сервер отказал" % [applied, total, rev])
	else:
		_finish_flush(false, "Сервер не принял ни одного объекта")


func _finish_flush(ok: bool, message: String) -> void:
	_flushing = false
	_lock(false)
	_mark_error(not ok)
	_set_status(message)


## Хост (с портом) из URL — для same-origin проверки persist-endpoint.
static func _host_of(url: String) -> String:
	if not url.contains("://"):
		return ""
	return url.get_slice("://", 1).get_slice("/", 0)


# --- Мелочи ---

func _lock(locked: bool) -> void:
	_editor.editable = not locked
	_save_btn.disabled = locked
	_cancel_btn.disabled = locked
	if _flush_btn != null:
		_flush_btn.disabled = locked


func _mark_error(on: bool) -> void:
	add_theme_stylebox_override("panel", _style_error if on else _style_normal)


func _reject(message: String) -> void:
	_mark_error(true)
	_set_status(message)


func _set_status(text: String) -> void:
	_status.text = text
	_status.tooltip_text = text


func _on_editor_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_S and event.is_command_or_control_pressed():
		_editor.accept_event()
		_on_save()


## Есть ли в разобранном тексте редактора что-то, кроме одного блока <vrweb>
## (страница правится не здесь). Возвращает описание находки или "" (всё чисто).
static func _stray_content(root: HtmlNode) -> String:
	var blocks := 0
	for c in root.children:
		if c.is_text():
			if c.text.strip_edges() != "":
				return "текст «%s»" % c.text.strip_edges().left(40)
		elif c.tag == SceneHtml.SCENE_TAG:
			blocks += 1
		else:
			return "тег <%s>" % c.tag
	if blocks > 1:
		return "блоков <%s> больше одного" % SceneHtml.SCENE_TAG
	return ""
