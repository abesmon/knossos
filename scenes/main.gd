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
@onready var _settings_btn: Button = $"UI/PanelContainer/MarginContainer/HBoxContainer/settings"

var _fetcher: PageFetcher
var _player: Player
var _status: Label
var _cross: Label
var _current_url: String = ""
var _history: Array[String] = []
var _label_positions: Dictionary = {}
var _loading: bool = false

var _settings_overlay: Control
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
	_world.add_child(_player)

	_go.pressed.connect(_on_go)
	_address.text_submitted.connect(func(_t): _on_go())
	# При клике в адресную строку отпускаем мышь, чтобы можно было печатать.
	_address.focus_entered.connect(func(): _player.capture_mouse(false))

	_setup_net()

	_set_status("Введите адрес и go! — WASD ходьба, двойной пробел — полёт, ЛКМ/E — портал, колесо/тачпад — скролл текста, Esc — мышь")

	# При запуске сразу ставим фокус в адресную строку, чтобы можно было печатать
	# без лишнего клика (focus_entered отпускает мышь).
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


func _navigate(url: String, base: String, push_history: bool) -> void:
	_loading = true
	_set_status("Загрузка %s …" % url)
	if push_history and _current_url != "":
		_history.append(_current_url)
	_fetcher.fetch(url, base)


func _on_fetched(html: String, final_url: String) -> void:
	_loading = false
	_current_url = final_url
	_address.text = final_url
	_set_status("Сборка пространства…")

	var t0 := Time.get_ticks_msec()
	var doc := HtmlParser.parse(html)
	var space := TopologyBuilder.build(doc)
	_rebuild_world(space, final_url)
	var dt := Time.get_ticks_msec() - t0

	var room_count: int = space.get("rooms", {}).size()
	_set_status("%s — %d пространств, %d мс" % [final_url, room_count, dt])

	# Комната мультиплеера = страница. В онлайне переключаемся на комнату нового URL
	# (NetworkManager рвёт старые p2p-соединения и пересоздаёт mesh).
	_join_current_room()


func _on_failed(message: String, url: String) -> void:
	_loading = false
	_set_status("Ошибка: %s (%s)" % [message, url])


func _rebuild_world(space: Dictionary, url: String) -> void:
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

	var seed_value := int(hash(PageFetcher.seed_key(url)))
	var gen := WorldGenerator.generate(space, _world, seed_value, _activate_transition, url, image_loader)
	_label_positions = gen.label_positions
	# Спавн «у первого объекта страницы, лицом к нему» (WorldGenerator._compute_spawn).
	_player.teleport_to(gen.spawn_point, gen.spawn_look_at if gen.has_spawn_look else null)


## Единый обработчик переходов от порталов и inline-ссылок RichPanel.
func _activate_transition(transition: Dictionary) -> void:
	match transition.get("kind", ""):
		"navigate":
			_navigate(transition.get("href", ""), _current_url, true)
		"teleport":
			var target: String = transition.get("target", "")
			if _label_positions.has(target):
				_player.teleport_to(_label_positions[target] + Vector3(0, 0.5, 2))
				_set_status("Переход к #%s" % target)
			else:
				_set_status("Якорь #%s не найден" % target)
		"back":
			_go_back()


func _go_back() -> void:
	if _history.is_empty():
		_set_status("История пуста")
		return
	var prev: String = _history.pop_back()
	_navigate(prev, "", false)


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
	if text == "":
		return
	NetworkManager.send_chat(text)
	_append_chat(Settings.nick, text)   # локальное эхо
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
	_on_aim_target_changed(false)

	# Строка статуса внизу.
	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = 8
	_status.offset_bottom = -8
	_status.offset_top = -32
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_status)


## Подсветка прицела: над кликабельным/портальным объектом он становится кружком
## (акцентный цвет и крупнее), иначе — нейтральный плюс.
func _on_aim_target_changed(active: bool) -> void:
	if _cross == null:
		return
	if active:
		_cross.text = "○"
		_cross.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		_cross.add_theme_font_size_override("font_size", 28)
	else:
		_cross.text = "+"
		_cross.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		_cross.add_theme_font_size_override("font_size", 18)


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
	print("[VRWeb] ", text)
