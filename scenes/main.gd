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

	# При запуске сразу ставим фокус в адресную строку, чтобы можно было печатать
	# без лишнего клика. Сначала отпускаем мышь — это снова делает UI фокусируемым
	# (Player._ready захватил мышь и заблокировал фокус), иначе grab_focus не сработает.
	_player.capture_mouse(false)
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
	# Собственный синтаксис VRWeb: блок <vrweb> описывает 3D-сцену напрямую узлами Godot.
	# mode="exclusive" — HTML игнорируется; "combine" — сцена vrweb добавляется поверх HTML.
	# final_url — база для резолва путей внешних ресурсов (<ExtResource>).
	var vrweb := VrwebBuilder.build(doc, final_url)
	# debug=true: топология записывает провенанс (id -> исходный HTML), а WorldGenerator
	# вешает его на узлы — для отладочного инспектора прицела (F3, см. _on_debug_*).
	var space := TopologyBuilder.build(doc, true)
	_rebuild_world(space, final_url, vrweb)
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


func _on_failed(message: String, url: String) -> void:
	_loading = false
	_set_status("Ошибка: %s (%s)" % [message, url])


func _rebuild_world(space: Dictionary, url: String, vrweb: Dictionary) -> void:
	# Сносим старое пространство, игрока сохраняем.
	for child in _world.get_children():
		if child == _player:
			continue
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
		gen = WorldGenerator.generate(space, _world, seed_value, _activate_transition, url, image_loader)
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
		# Регистрируем видео-плееры и привязываем экраны (после добавления в дерево).
		video_manager.scan(vrweb["root"])

	# Внешние ресурсы (<ExtResource path="<url>">) качаются и вставляются асинхронно —
	# прогрессивная подгрузка, как у картинок <img>. Общая логика с дебаг-превью редактора
	# вынесена в VrwebExtInjector; оба лоадера живут в мире и сносятся при навигации.
	VrwebExtInjector.inject(vrweb.get("ext", {}), image_loader, _world)


## Единый обработчик переходов от порталов и inline-ссылок RichPanel.
func _activate_transition(transition: Dictionary) -> void:
	match transition.get("kind", ""):
		"navigate":
			_navigate(transition.get("href", ""), _current_url, true)
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
	_settings_overlay.closed.connect(_on_settings_closed)

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
	_settings_overlay.open()


func _on_settings_closed() -> void:
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
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	if _chat_log != null:
		_chat_log.append_text("[b]%s[/b]: %s\n" % [_esc_bb(nick), _esc_bb(text)])


## Экранирует "[" в пользовательском тексте, чтобы он не воспринимался как BBCode-тег.
func _esc_bb(s: String) -> String:
	return s.replace("[", "[lb]")


func _update_chat_visibility() -> void:
	if _chat_root != null:
		_chat_root.visible = Settings.online_enabled


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
