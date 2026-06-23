extends Node

## Главный контроллер VRWeb: адресная строка -> загрузка HTML -> парсинг ->
## топология (артефакт без координат) -> геометрия (3D-пространство) -> навигация.
## Связывает сервисы; сам логику трансляции не содержит.

const PLAYER_SCENE := preload("res://actors/player/player.tscn")
const SETTINGS_SCENE := preload("res://scenes/settings.tscn")
const REMOTE_VIEW_SCRIPT := preload("res://scripts/remote_players_view.gd")

@onready var _world: Node3D = $world
@onready var _address: LineEdit = $"UI/PanelContainer/MarginContainer/HBoxContainer/address bar"
@onready var _go: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/go"
@onready var _back_btn: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/back_btn"
@onready var _fwd_btn: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/fwd_btn"
@onready var _settings_btn: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/settings"

var _fetcher: PageFetcher
var _player: Player
var _status: Label
var _cross: Label
var _current_url: String = ""
# База для относительных URL (учитывает <base href>); по умолчанию = _current_url.
var _base_url: String = ""
# «Паспорт» текущей страницы из <head> (title/description/thumbnail/metas) — заполняется в
# _on_fetched и отдаётся вкладке «Мир» настроек (см. _extract_page_meta).
var _page_meta: Dictionary = {}
# Браузерная история: список записей {url, pose} и индекс текущей. Переход назад/вперёд
# двигает _history_index; новая навигация обрезает «вперёд» и добавляет запись.
var _history: Array[Dictionary] = []
var _history_index: int = -1
# Поза игрока (get_pose), которую нужно восстановить после загрузки при переходе по
# истории, вместо дефолтного спавна страницы. null — обычная навигация.
var _pending_restore_pose: Variant = null
var _label_positions: Dictionary = {}
var _loading: bool = false

var _settings_overlay: Control
var _debug_panel: PanelContainer
var _debug_label: Label
var _remote_view: Node3D
var _chat_root: VBoxContainer
var _chat_log: RichTextLabel
var _chat_input: LineEdit
# Чат живёт только в RAM: кольцевой буфер последних CHAT_HISTORY_MAX записей, на диск ничего
# не пишется. Запись = {kind:"user", nick, text} либо {kind:"system", text} (отбивки переходов).
const CHAT_HISTORY_MAX := 50
var _chat_history: Array[Dictionary] = []
# Таймер угасания: в режиме перемещения через 30с после последнего сообщения лог гаснет до 10%.
var _chat_idle_timer: Timer
var _chat_fade_tween: Tween
# Захвачена ли мышь (режим перемещения) — определяет вид чата: поле ввода и угасание.
var _mouse_captured: bool = true


func _ready() -> void:
	_setup_environment()
	_setup_ui_extras()

	_fetcher = PageFetcher.new()
	add_child(_fetcher)
	_fetcher.fetched.connect(_on_fetched)
	_fetcher.failed.connect(_on_failed)

	_player = PLAYER_SCENE.instantiate()
	_player.aim_target_changed.connect(_on_aim_target_changed)
	_player.debug_toggled.connect(_on_debug_toggled)
	_player.debug_probed.connect(_on_debug_probed)
	# Браузинг мира и UI взаимоисключающи: пока мышь захвачена, элементы навбара/чата
	# делаем нефокусируемыми, чтобы их нельзя было активировать с клавиатуры (Tab/Space/Enter).
	_player.mouse_capture_changed.connect(_on_mouse_capture_changed)
	# Enter в браузинге открывает строку чата (быстрый ввод сообщения без клика).
	_player.chat_requested.connect(_on_chat_requested)
	# Esc при уже свободной мыши (возимся с UI) открывает настройки.
	_player.settings_requested.connect(_open_settings)
	_world.add_child(_player)

	_go.pressed.connect(_on_go)
	_back_btn.pressed.connect(_on_back_pressed)
	_fwd_btn.pressed.connect(_on_fwd_pressed)
	_update_nav_buttons()
	_address.text_submitted.connect(func(_t): _on_go())
	# При клике в адресную строку отпускаем мышь, чтобы можно было печатать.
	_address.focus_entered.connect(func(): _player.capture_mouse(false))

	_setup_net()

	_set_status("Введите адрес и go! — WASD ходьба, двойной пробел — полёт, ЛКМ/E — портал, колесо/тачпад — скролл текста, F3 — отладка, Esc — мышь")

	# При запуске всегда отпускаем мышь (Player._ready захватил её): это снова делает UI
	# фокусируемым — без этого ни grab_focus, ни клики по навбару не сработают. В режим
	# перемещения пользователь войдёт сам кликом по 3D.
	_player.capture_mouse(false)
	# Если задана домашняя страница — грузим её при запуске (как ввод адреса в омнибоксе:
	# абсолютный URL, без базы). Иначе ставим фокус в адресную строку, чтобы можно было
	# печатать без лишнего клика.
	var home := Settings.home_page.strip_edges()
	if home != "":
		_address.text = home
		_navigate(home, "", true)
	else:
		_address.grab_focus()


func _on_go() -> void:
	var url := _address.text.strip_edges()
	if url == "" or _loading:
		return
	# Ввод в адресной строке — это абсолютный адрес (как омнибокс браузера),
	# а не путь относительно текущей страницы. Поэтому base пустой: иначе домен
	# «abesmon.syrupmg.ru» приклеится к текущему пути. Относительный резолв нужен
	# только для внутристраничных ссылок (см. _activate_transition).
	_navigate(url, "", true)
	_player.capture_mouse(true)


## При входе в браузинг мира (мышь захвачена) запрещаем фокус UI, чтобы клавиатура их не
## достала; при выходе — снова разрешаем кликать и печатать в навбаре/чате.
func _on_mouse_capture_changed(captured: bool) -> void:
	_set_ui_focusable(not captured)
	_mouse_captured = captured
	# В режиме перемещения поле ввода не нужно (печатать всё равно нельзя — оно открывается
	# по Enter через _on_chat_requested), показываем только лог; в UI-режиме — лог + поле.
	if _chat_input != null:
		_chat_input.visible = not captured
	# Смена режима будит чат: полная видимость и заново заведённый таймер угасания
	# (он стартует лишь в режиме перемещения, см. _chat_wake).
	_chat_wake()


## Enter в браузинге мира — открываем строку чата: освобождаем мышь (делает UI фокусируемым)
## и ставим фокус в поле ввода. Отправка по Enter (или пустой Enter) вернёт в браузинг через
## _on_chat_submitted. Работает только когда чат показан (онлайн).
func _on_chat_requested() -> void:
	if _chat_input == null or _chat_root == null or not _chat_root.visible:
		return
	_player.capture_mouse(false)
	_chat_input.grab_focus()


## Разрешает/запрещает фокусировку интерактивных элементов навбара и чата. FOCUS_NONE убирает
## их из обхода по Tab и не даёт активировать с клавиатуры; мышиный клик кнопкам не нужен —
## он всё равно сработает (а при захваченной мыши кликнуть по ним и так нельзя).
func _set_ui_focusable(focusable: bool) -> void:
	var mode := Control.FOCUS_ALL if focusable else Control.FOCUS_NONE
	for c: Control in [_address, _go, _back_btn, _fwd_btn, _settings_btn, _chat_input]:
		if c != null:
			c.focus_mode = mode
	# Логу чата хватает фокуса по клику (выделение + Ctrl/Cmd+C); в режиме перемещения
	# фокус снимаем, чтобы клавиатура его не доставала (как и прочий UI выше).
	if _chat_log != null:
		_chat_log.focus_mode = Control.FOCUS_CLICK if focusable else Control.FOCUS_NONE


func _navigate(url: String, base: String, push_history: bool) -> void:
	_loading = true
	_set_status("Загрузка %s …" % url)
	if push_history:
		# Уходим со страницы по новой ссылке: запоминаем позу в текущей записи, обрезаем
		# ветку «вперёд» (как браузер) и добавляем новую запись. URL запишется финальным
		# (после возможного редиректа) в _on_fetched.
		_capture_current_pose()
		_history.resize(_history_index + 1)
		_history.append({"url": url, "pose": null})
		_history_index = _history.size() - 1
	_update_nav_buttons()
	_fetcher.fetch(url, base)


func _on_fetched(html: String, final_url: String) -> void:
	_loading = false
	_current_url = final_url
	_address.text = final_url
	# Запись истории хранит финальный URL (после редиректа) — по нему пойдёт назад/вперёд.
	if _history_index >= 0 and _history_index < _history.size():
		_history[_history_index]["url"] = final_url
	_set_status("Сборка пространства…")

	var t0 := Time.get_ticks_msec()
	var doc := HtmlParser.parse(html)
	# <base href> (стандарт HTML) переопределяет базу для относительных ссылок/ресурсов;
	# без него база = адрес страницы. seed/история/комната по-прежнему по final_url.
	var base_url := _resolve_base_url(doc, final_url)
	_base_url = base_url
	# «Паспорт» страницы из <head> для вкладки «Мир» в настройках (заголовок/описание/превью).
	_page_meta = _extract_page_meta(doc, base_url, final_url)
	# Собственный синтаксис VRWeb: блок <vrweb> описывает 3D-сцену напрямую узлами Godot.
	# mode="exclusive" — HTML игнорируется; "combine" — сцена vrweb добавляется поверх HTML.
	# base_url — база для резолва путей внешних ресурсов (<ExtResource>, <img>, <video>).
	var vrweb := VrwebBuilder.build(doc, base_url)
	# debug=true: топология записывает провенанс (id -> исходный HTML), а WorldGenerator
	# вешает его на узлы — для отладочного инспектора прицела (F3, см. _on_debug_*).
	var space := TopologyBuilder.build(doc, true)
	_rebuild_world(space, final_url, vrweb, base_url)
	# Переход назад/вперёд: возвращаем игрока туда, где он стоял на этой странице, поверх
	# дефолтного спавна из _rebuild_world. Мир детерминирован по URL, поза остаётся валидной.
	if _pending_restore_pose != null:
		_player.restore_pose(_pending_restore_pose)
		_pending_restore_pose = null
	var dt := Time.get_ticks_msec() - t0

	var room_count: int = space.get("rooms", {}).size()
	_set_status("%s — %d пространств, %d мс" % [final_url, room_count, dt])

	# Комната мультиплеера = страница. В онлайне переключаемся на комнату нового URL
	# (NetworkManager рвёт старые p2p-соединения и пересоздаёт mesh).
	_join_current_room()

	# Отбивка в чате — граница между мирами в общей (сквозной) истории. Только онлайн:
	# оффлайн чат скрыт, а собеседников нет.
	if Settings.online_enabled:
		_push_system_chat("Присоединились к миру %s" % final_url)


func _on_failed(message: String, url: String) -> void:
	_loading = false
	_set_status("Ошибка: %s (%s)" % [message, url])


## <base href> переопределяет базовый адрес для относительных URL (стандарт HTML). Сам href
## может быть относительным/protocol-relative — резолвим его относительно адреса страницы.
func _resolve_base_url(doc: HtmlNode, page_url: String) -> String:
	var base := doc.find_descendant("base")
	if base != null:
		var href := base.get_attr("href").strip_edges()
		if href != "":
			return PageFetcher.resolve_url(href, page_url)
	return page_url


## Человекочитаемые meta-теги для вкладки «Мир» — только осмысленные подписи, без технических
## (viewport, charset, theme-color и т.п.). Ключ (lowercase name/property) → подпись. Заголовок,
## описание и превью показываются отдельно, поэтому их здесь нет.
const MEANINGFUL_META := {
	"author": "Автор",
	"article:author": "Автор",
	"og:site_name": "Сайт",
	"application-name": "Приложение",
	"keywords": "Ключевые слова",
	"og:type": "Тип",
	"article:published_time": "Опубликовано",
	"article:section": "Раздел",
}


## Собирает «паспорт» страницы из <head>: заголовок (<title> или og:title), описание
## (description/og:description), превью (og:image/twitter:image, резолвится относительно базы)
## и осмысленные meta-теги (без технических). Отдаётся настройкам в _open_settings.
func _extract_page_meta(doc: HtmlNode, base_url: String, url: String) -> Dictionary:
	var metas: Array = []
	_collect_meta(doc, metas)
	var description := ""
	var og_title := ""
	var thumb := ""
	# Только человекочитаемые теги из белого списка (с подписью), без дублей по подписи.
	var info: Array = []
	var seen_labels := {}
	for m in metas:
		var key: String = m["key"]
		var value: String = m["value"]
		match key.to_lower():
			"description", "og:description", "twitter:description":
				if description == "":
					description = value
			"og:title", "twitter:title":
				if og_title == "":
					og_title = value
			"og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src":
				if thumb == "":
					thumb = value
		var label: String = MEANINGFUL_META.get(key.to_lower(), "")
		if label != "" and not seen_labels.has(label):
			seen_labels[label] = true
			info.append({"label": label, "value": value})
	var title_node := doc.find_descendant("title")
	var title := title_node.collect_text().strip_edges() if title_node != null else ""
	if title == "":
		title = og_title
	if thumb != "":
		thumb = PageFetcher.resolve_url(thumb, base_url)
	return {
		"url": url,
		"title": title,
		"description": description,
		"thumbnail": thumb,
		"metas": info,
	}


## Рекурсивно собирает meta-теги поддерева в out как [{key, value}]. key — name или property,
## value — content. Пустые ключ/значение пропускаем.
func _collect_meta(node: HtmlNode, out: Array) -> void:
	for c in node.children:
		if c.tag == "meta":
			var key := c.get_attr("name")
			if key == "":
				key = c.get_attr("property")
			var value := c.get_attr("content")
			if key != "" and value != "":
				out.append({"key": key, "value": value})
		_collect_meta(c, out)


func _rebuild_world(space: Dictionary, url: String, vrweb: Dictionary, base_url: String) -> void:
	# Сносим старое пространство, игрока сохраняем. remove_child СРАЗУ (а не только queue_free):
	# queue_free удаляет из дерева лишь в конце кадра, а video_manager.scan(_world) ниже бежит
	# в этом же кадре — иначе он обошёл бы старое (умирающее) поддерево vrweb и привязал бы уже
	# привязанные экраны/мёртвые плееры (двойной connect texture_ready и freed instance в _process).
	for child in _world.get_children():
		if child == _player:
			continue
		_world.remove_child(child)
		child.queue_free()

	# Лоадер картинок живёт внутри мира: при следующей навигации мир сносится вместе с ним,
	# незавершённые загрузки старой страницы умирают сами.
	var image_loader := ImageLoader.new()
	image_loader.name = "ImageLoader"
	_world.add_child(image_loader)

	# Капсулы других игроков живут в мире: при навигации мир сносится — старые капсулы
	# исчезают (ушёл со страницы = вышел из комнаты), view пересоздаётся для новой.
	_remote_view = REMOTE_VIEW_SCRIPT.new()
	_remote_view.name = "RemotePlayersView"
	_world.add_child(_remote_view)
	_remote_view.setup(_player)

	# Менеджер видео-плееров: связывает <VRWebVideoPlayer>/<VRWebVideoScreen> и синхронизирует
	# воспроизведение по сети. Тоже живёт в мире — при навигации сносится (выход из комнаты).
	var video_manager := VrwebVideoManager.new()
	video_manager.name = "VrwebVideoManager"
	_world.add_child(video_manager)

	# mode="exclusive" — HTML-сцену не строим вовсе, в мире только узлы vrweb.
	var exclusive: bool = vrweb.get("found", false) and vrweb.get("mode", "") == VrwebBuilder.MODE_EXCLUSIVE
	var gen: WorldGenerator = null
	if exclusive:
		_label_positions = {}
	else:
		var seed_value := int(hash(PageFetcher.seed_key(url)))
		gen = WorldGenerator.generate(space, _world, seed_value, _activate_transition, base_url, image_loader)
		_label_positions = gen.label_positions

	# Спавн: приоритет у <VRWebSpawner>, затем спавн HTML-топологии «у первого объекта»,
	# затем (exclusive без спавнера) дефолт у начала координат лицом к сцене.
	var spawn: Dictionary = vrweb.get("spawn", {})
	if spawn.has("point"):
		_player.teleport_to(spawn["point"], spawn.get("look_at"))
	elif gen != null:
		@warning_ignore("incompatible_ternary")
		_player.teleport_to(gen.spawn_point, gen.spawn_look_at if gen.has_spawn_look else null)
	else:
		_player.teleport_to(Vector3(0, 1.6, 5), Vector3(0, 1.6, 0))

	# Узлы vrweb добавляются поверх (combine) либо как единственное содержимое (exclusive).
	if vrweb.get("found", false) and vrweb.get("root") != null:
		_world.add_child(vrweb["root"])

	# Регистрируем видео-плееры и привязываем экраны (после добавления всего в дерево).
	# Сканируем весь мир: экраны бывают и из <vrweb>-тегов, и из обычного HTML-тега <video>
	# (WorldGenerator строит из него такой же VrwebVideoScreen).
	video_manager.scan(_world)

	# Внешние ресурсы (<ExtResource path="<url>">) качаются и вставляются асинхронно —
	# прогрессивная подгрузка, как у картинок <img>. Общая логика с дебаг-превью редактора
	# вынесена в VrwebExtInjector; оба лоадера живут в мире и сносятся при навигации.
	VrwebExtInjector.inject(vrweb.get("ext", {}), image_loader, _world)


## Единый обработчик переходов от порталов и inline-ссылок RichPanel.
func _activate_transition(transition: Dictionary) -> void:
	match transition.get("kind", ""):
		"navigate":
			# Относительные ссылки резолвятся относительно базы страницы (учитывает <base href>).
			_navigate(transition.get("href", ""), _base_url, true)
		"external":
			# Ссылка с нестандартной схемой (mailto:, tel:, magnet:, app-схема) — это не
			# страница для VRWeb, а намерение для ОС. Отдаём системному обработчику; он сам
			# решит, что запускать (почтовик, телефон, торрент-клиент, стороннее приложение).
			var uri: String = transition.get("uri", "")
			var err := OS.shell_open(uri)
			if err == OK:
				_set_status("Открыто во внешнем приложении: %s" % uri)
			else:
				_set_status("Не удалось открыть %s (ошибка %d)" % [uri, err])
		"teleport":
			var target: String = transition.get("target", "")
			if _label_positions.has(target):
				_player.teleport_to(_label_positions[target] + Vector3(0, 0.5, 2))
				_set_status("Переход к #%s" % target)
			else:
				_set_status("Якорь #%s не найден" % target)
		"back":
			_go_back()


## Кнопка «назад» в navbar: идём по истории и уводим мышь обратно в игру (клик по UI её
## отпустил). capture_mouse сам снимет фокус с кнопки.
func _on_back_pressed() -> void:
	_go_back()
	_player.capture_mouse(true)


func _on_fwd_pressed() -> void:
	_go_forward()
	_player.capture_mouse(true)


func _go_back() -> void:
	if _history_index <= 0:
		_set_status("Назад некуда")
		return
	_capture_current_pose()
	_history_index -= 1
	_load_history_entry()


func _go_forward() -> void:
	if _history_index >= _history.size() - 1:
		_set_status("Вперёд некуда")
		return
	_capture_current_pose()
	_history_index += 1
	_load_history_entry()


## Загружает запись истории под текущим _history_index, попросив восстановить сохранённую
## позу игрока. push_history=false — индекс уже выставлен вызывающим.
func _load_history_entry() -> void:
	var entry: Dictionary = _history[_history_index]
	_pending_restore_pose = entry.get("pose")
	_navigate(entry["url"], "", false)


## Сохраняет текущую позу игрока в активной записи истории — чтобы вернуться сюда позже.
func _capture_current_pose() -> void:
	if _history_index >= 0 and _history_index < _history.size():
		_history[_history_index]["pose"] = _player.get_pose()


## Доступность кнопок назад/вперёд по положению в истории.
func _update_nav_buttons() -> void:
	if _back_btn != null:
		_back_btn.disabled = _history_index <= 0
	if _fwd_btn != null:
		_fwd_btn.disabled = _history_index >= _history.size() - 1


# --- Мультиплеер ---

func _setup_net() -> void:
	var ui: Control = $UI

	# Overlay настроек поверх UI, изначально скрыт.
	_settings_overlay = SETTINGS_SCENE.instantiate()
	ui.add_child(_settings_overlay)
	# Закрытие настроек оставляет мышь свободной (UI-режим) — обратно в перемещение
	# возвращает клик по 3D, а не само закрытие. Поэтому closed здесь ни к чему не цепляем.
	# «Вернуться домой» с вкладки «Мир» — грузим домашний инстанс.
	_settings_overlay.home_requested.connect(_on_home_requested)

	_settings_btn.pressed.connect(_open_settings)
	_settings_btn.focus_entered.connect(func(): _player.capture_mouse(false))

	_build_chat_ui(ui)

	Settings.changed.connect(_on_settings_changed)
	NetworkManager.connection_changed.connect(_on_connection_changed)
	NetworkManager.chat_received.connect(_on_chat_received)

	# Применяем сохранённый режим (online_enabled мог остаться с прошлой сессии).
	_sync_online()


func _open_settings() -> void:
	_player.capture_mouse(false)
	_settings_overlay.open(_current_url, _page_meta)


## «Вернуться домой» из настроек: грузим домашний инстанс (как ввод адреса в омнибоксе —
## абсолютный URL, без базы) и уводим мышь обратно в перемещение.
func _on_home_requested() -> void:
	var home := Settings.home_page.strip_edges()
	if home == "":
		return
	_address.text = home
	_navigate(home, "", true)
	_player.capture_mouse(true)


func _on_settings_changed() -> void:
	_sync_online()
	# Ник/лицо могли поменяться — разошлём обновлённую карточку уже подключённым пирам.
	NetworkManager.broadcast_identity()


## Приводит сетевое состояние в соответствие настройкам: онлайн — подключаемся и входим
## в комнату текущей страницы; офлайн — рвём соединение.
func _sync_online() -> void:
	if Settings.online_enabled:
		if not NetworkManager.webrtc_available():
			_set_status("WebRTC недоступен: добавьте аддон webrtc-native в addons/webrtc")
		else:
			_join_current_room()
	else:
		NetworkManager.disconnect_from_server()
	_update_chat_visibility()


## Подключиться (если ещё нет) и войти в комнату текущего URL. join_room сам поставит
## вход в очередь, если соединение ещё устанавливается.
func _join_current_room() -> void:
	if not (Settings.online_enabled and NetworkManager.webrtc_available()):
		return
	if not NetworkManager.is_online():
		NetworkManager.connect_to_server()
	if _current_url != "":
		NetworkManager.join_room(PageFetcher.seed_key(_current_url))


func _on_connection_changed(online: bool) -> void:
	_set_status("Онлайн: %s" % Settings.signaling_url if online else "Офлайн")


# --- Чат ---

func _build_chat_ui(ui: Control) -> void:
	_chat_root = VBoxContainer.new()
	_chat_root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_root.offset_left = 8
	_chat_root.offset_right = 420
	_chat_root.offset_top = -260
	_chat_root.offset_bottom = -40   # над строкой статуса
	_chat_root.add_theme_constant_override("separation", 4)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_active = true
	_chat_log.scroll_following = true
	_chat_log.custom_minimum_size = Vector2(400, 170)
	# Текст можно выделять мышью и копировать (Ctrl/Cmd+C). Для этого лог должен принимать
	# события мыши (не IGNORE) — заодно это включает клики по ссылкам ниже.
	_chat_log.selection_enabled = true
	# Ссылки в сообщениях ([url]…[/url], см. _linkify) подчёркиваем и делаем кликабельными;
	# meta_clicked отдаёт href в _on_chat_meta_clicked для перехода/внешнего открытия.
	_chat_log.meta_underlined = true
	_chat_log.meta_clicked.connect(_on_chat_meta_clicked)
	_chat_root.add_child(_chat_log)

	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Сообщение… (Enter)"
	_chat_input.custom_minimum_size = Vector2(400, 0)
	_chat_input.max_length = NetworkManager.MAX_CHAT_CHARS   # не ввести больше лимита
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_input.focus_entered.connect(func(): _player.capture_mouse(false))
	_chat_root.add_child(_chat_input)

	ui.add_child(_chat_root)
	_chat_root.visible = false

	# Таймер бездействия: в режиме перемещения через 30с после последнего сообщения лог
	# плавно угасает до 10% непрозрачности, чтобы не мешать обзору (см. _on_chat_idle_timeout).
	_chat_idle_timer = Timer.new()
	_chat_idle_timer.one_shot = true
	_chat_idle_timer.wait_time = 30.0
	_chat_idle_timer.timeout.connect(_on_chat_idle_timeout)
	add_child(_chat_idle_timer)


func _on_chat_submitted(text: String) -> void:
	text = text.strip_edges().left(NetworkManager.MAX_CHAT_CHARS)
	_chat_input.clear()
	if text != "":
		NetworkManager.send_chat(text)
		_append_chat(Settings.nick, text)   # локальное эхо
	# Enter всегда возвращает в браузинг — даже на пустом сообщении (round-trip с chat_requested).
	_player.capture_mouse(true)


func _on_chat_received(id: int, text: String) -> void:
	_append_chat(NetworkManager.nick_of(id), text)


func _append_chat(nick: String, text: String) -> void:
	_push_chat({"kind": "user", "nick": nick, "text": text})


## Системная строка чата (серым курсивом) — отбивки переходов между мирами и пр.
func _push_system_chat(text: String) -> void:
	_push_chat({"kind": "system", "text": text})


## Кладёт запись в кольцевой буфер (последние CHAT_HISTORY_MAX, без записи на диск),
## перерисовывает лог и будит чат (видимость + сброс таймера угасания).
func _push_chat(entry: Dictionary) -> void:
	_chat_history.append(entry)
	if _chat_history.size() > CHAT_HISTORY_MAX:
		_chat_history = _chat_history.slice(_chat_history.size() - CHAT_HISTORY_MAX)
	_render_chat()
	_chat_wake()


## Перерисовывает лог из буфера (≤50 строк — дёшево). clear()+append_text заодно обрезает
## старое при переполнении буфера; scroll_following держит прокрутку у низа.
func _render_chat() -> void:
	if _chat_log == null:
		return
	_chat_log.clear()
	for e: Dictionary in _chat_history:
		if e.get("kind", "") == "system":
			_chat_log.append_text("[i][color=#9aa0a6]— %s —[/color][/i]\n" % _esc_bb(e.get("text", "")))
		else:
			_chat_log.append_text("[b]%s[/b]: %s\n" % [_esc_bb(e.get("nick", "")), _linkify(e.get("text", ""))])


## Экранирует "[" в пользовательском тексте, чтобы он не воспринимался как BBCode-тег.
func _esc_bb(s: String) -> String:
	return s.replace("[", "[lb]")


# URL в тексте сообщения: схема (http(s), mailto:, tel:, кастомные app-схемы, deeplink
# scheme://…) либо www.-домен, до первого пробела. Хвостовая пунктуация (.,!? и скобки)
# отрезается отдельно в _linkify, чтобы не утащить её в адрес.
static var _url_re: RegEx = RegEx.create_from_string("(?i)\\b(?:[a-z][a-z0-9+.\\-]*:(?://)?|www\\.)[^\\s]+")


## Оборачивает ссылки в тексте в кликабельный [url=…], остальное экранирует _esc_bb.
## meta каждого [url] — исходный адрес; по нему _on_chat_meta_clicked решает, что делать.
func _linkify(text: String) -> String:
	var out := ""
	var last := 0
	for m: RegExMatch in _url_re.search_all(text):
		out += _esc_bb(text.substr(last, m.get_start() - last))
		var url := m.get_string()
		# Отрезаем хвостовую пунктуацию: "(см. example.com)." не должен включать ")." в адрес.
		var trail := ""
		while url.length() > 0 and url[url.length() - 1] in ".,;:!?)»\"'":
			trail = url[url.length() - 1] + trail
			url = url.substr(0, url.length() - 1)
		if _looks_like_link(url):
			out += "[url=%s][color=#6cb6ff]%s[/color][/url]" % [url, _esc_bb(url)]
			out += _esc_bb(trail)
		else:
			# Ложное срабатывание (напр. "слово:слово") — оставляем как обычный текст.
			out += _esc_bb(m.get_string())
		last = m.get_end()
	out += _esc_bb(text.substr(last))
	return out


## Отсеивает ложные «ссылки» (двоеточие в обычной фразе): настоящий адрес — это www.,
## схема с "//" (deeplink/веб), известная безслэшевая схема (mailto/tel/…) или схема,
## за которой идёт путь/домен с "/" или ".".
func _looks_like_link(s: String) -> bool:
	if s.to_lower().begins_with("www."):
		return true
	var colon := s.find(":")
	if colon <= 0:
		return false
	var rest := s.substr(colon + 1)
	if rest.begins_with("//"):
		return true
	if s.substr(0, colon).to_lower() in ["mailto", "tel", "sms", "magnet", "geo", "maps"]:
		return true
	return rest.contains("/") or rest.contains(".")


## Клик по ссылке в чате: www.→https://, далее общая классификация (навигация VRWeb,
## телепорт к якорю или внешнее намерение для ОС) — та же, что у ссылок страницы.
func _on_chat_meta_clicked(meta: Variant) -> void:
	var url := str(meta).strip_edges()
	if url.to_lower().begins_with("www."):
		url = "https://" + url
	var transition: Variant = TopologyBuilder.classify_href(url)
	if transition == null:
		return
	if transition.get("kind", "") == "navigate":
		# Ссылка из чата — абсолютный адрес (как омнибокс): база пустая, мышь обратно в игру.
		_navigate(transition["href"], "", true)
		_player.capture_mouse(true)
	else:
		_activate_transition(transition)


## Будит чат: полная непрозрачность и (только в режиме перемещения) перезапуск 30-сек таймера,
## по истечении которого лог плавно угаснет до 10% (_on_chat_idle_timeout). В UI-режиме таймер
## не заводится — чат остаётся читаемым, пока мышь свободна.
func _chat_wake() -> void:
	if _chat_fade_tween != null:
		_chat_fade_tween.kill()
		_chat_fade_tween = null
	if _chat_root != null:
		_chat_root.modulate.a = 1.0
	if _chat_idle_timer == null:
		return
	_chat_idle_timer.stop()
	if _mouse_captured and Settings.online_enabled:
		_chat_idle_timer.start()


## 30с без сообщений в режиме перемещения — плавно гасим лог до 10%, чтобы не мешал обзору.
func _on_chat_idle_timeout() -> void:
	if _chat_root == null or not (_mouse_captured and Settings.online_enabled):
		return
	_chat_fade_tween = create_tween()
	_chat_fade_tween.tween_property(_chat_root, "modulate:a", 0.1, 0.6)


func _update_chat_visibility() -> void:
	if _chat_root != null:
		_chat_root.visible = Settings.online_enabled
	# Онлайн-состояние влияет на угасание (оффлайн чат скрыт целиком).
	_chat_wake()


# --- Окружение и UI ---

## Нейтральные небо и свет только для стартового экрана (до загрузки страницы).
## После первой навигации их заменяет процедурная атмосфера из WorldGenerator,
## сгенерированная по данным страницы (см. _rebuild_world).
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(40), 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	_world.add_child(sun)


func _setup_ui_extras() -> void:
	var ui: Control = $UI
	# Прицел по центру экрана. Внешний вид меняется при наведении на активный объект
	# (см. _on_aim_target_changed).
	_cross = Label.new()
	_cross.set_anchors_preset(Control.PRESET_CENTER)
	_cross.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_cross)
	_on_aim_target_changed(false, "")

	# Строка статуса внизу.
	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = 8
	_status.offset_bottom = -8
	_status.offset_top = -32
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_status)

	_build_debug_overlay(ui)


## Оверлей инспектора провенанса (F3): панель в правом верхнем углу с типом топологии и
## исходным HTML узла под прицелом. Текст приходит от Player.debug_probed.
func _build_debug_overlay(ui: Control) -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_debug_panel.offset_left = -468
	_debug_panel.offset_right = -8
	_debug_panel.offset_top = 8
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_panel.visible = false

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	_debug_panel.add_child(margin)

	_debug_label = Label.new()
	_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_label.custom_minimum_size = Vector2(444, 0)
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_debug_label.add_theme_font_size_override("font_size", 13)
	margin.add_child(_debug_label)

	ui.add_child(_debug_panel)


func _on_debug_toggled(on: bool) -> void:
	if _debug_panel != null:
		_debug_panel.visible = on
	if on:
		_set_status("Отладка ON — наведи прицел на объект (F3 — выкл)")
		if _debug_label != null:
			_debug_label.text = "Наведи прицел на объект…"
	else:
		_set_status("Отладка OFF")


func _on_debug_probed(text: String) -> void:
	if _debug_label != null:
		_debug_label.text = text if text != "" else "Наведи прицел на объект…"


## Подсветка прицела: над кликабельным/портальным объектом он становится кружком
## (акцентный цвет и крупнее), иначе — нейтральный плюс. hint — «куда ведёт» объект под
## прицелом: пишем его в строку статуса (превью ссылки, как в углу браузера), а как только
## прицел уходит «в никуда» — очищаем поле.
func _on_aim_target_changed(active: bool, hint: String) -> void:
	if _status != null:
		_status.text = hint
	if _cross == null:
		return
	if active:
		# Яркий magenta + крупнее + тёмная обводка — чтобы прицел над активным объектом
		# был заметен на любом фоне (тёмном тексте, светлой картинке).
		_cross.text = "○"
		_cross.add_theme_color_override("font_color", Color(1.0, 0.15, 0.9))
		_cross.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_cross.add_theme_constant_override("outline_size", 6)
		_cross.add_theme_font_size_override("font_size", 40)
	else:
		_cross.text = "+"
		_cross.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		_cross.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
		_cross.add_theme_constant_override("outline_size", 3)
		_cross.add_theme_font_size_override("font_size", 18)


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
	print("[VRWeb] ", text)
