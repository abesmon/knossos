extends Control

## Overlay-экран настроек. main инстансит его поверх UI (скрытым) и показывает по кнопке
## «⚙». Редактирует значения автолоада Settings; по «Сохранить» пишет их и закрывается.
## Сам мир не трогает — поэтому навигация/состояние не теряются.

signal closed
## «Вернуться домой» на вкладке «Мир»: просим main загрузить домашний инстанс.
signal home_requested
## «Моё пространство» на вкладке «Аккаунт»: просим main перейти в персональное пространство
## домашнего сервера — ОТДЕЛЬНО от домашней страницы (это разные сущности, см.
## docs/personal-spaces.md). Домашняя страница — произвольная закладка старта; пространство —
## хостируемый сервером дом пользователя.
signal space_requested
## Клик по странице в разделе «Кто где сейчас» (presence.v1, docs/presence.md):
## просим main перейти по URL и закрываемся.
signal presence_url_requested(url: String)

## Верх диапазона ползунка порога активации (RMS) — для перевода значения в проценты в подписи.
const THRESH_MAX := 0.15

@onready var _offline: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/Offline
@onready var _mode: OptionButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/ModeRow/Mode
@onready var _denoise: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/Denoise
@onready var _device: OptionButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/MicRow/Device
@onready var _device_refresh: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/MicRow/Refresh
@onready var _test: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/TestRow/Test
@onready var _monitor: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/TestRow/Monitor
@onready var _level: ProgressBar = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/Level
@onready var _thresh_marker: ColorRect = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/Level/Threshold
@onready var _gain_slider: HSlider = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/GainRow/Slider
@onready var _gain_value: Label = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/GainRow/Value
@onready var _thresh_slider: HSlider = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/ThreshRow/Slider
@onready var _thresh_value: Label = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/ThreshRow/Value
@onready var _out_device: OptionButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/OutRow/Device
@onready var _out_refresh: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/OutRow/Refresh
## Ползунки громкости шин: имя шины (как в Settings.AUDIO_BUSES) → HSlider + его Label-значение.
@onready var _vol_sliders := {
	"Master": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/VolMaster/Slider,
	"World": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/VolWorld/Slider,
	"Voice": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/VolVoice/Slider,
}
@onready var _vol_values := {
	"Master": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/VolMaster/Value,
	"World": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/VolWorld/Value,
	"Voice": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Content/VolVoice/Value,
}
@onready var _home: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/GeneralSettings/Content/HomeRow/Home
@onready var _home_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/GeneralSettings/Content/HomeRow/Clear
@onready var _fov_slider: HSlider = $Panel/Margin/VBoxContainer/TabContainer/GeneralSettings/Content/FovRow/Slider
@onready var _fov_value: Label = $Panel/Margin/VBoxContainer/TabContainer/GeneralSettings/Content/FovRow/Value
@onready var _url: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/UrlRow/Url
@onready var _url_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/UrlRow/Clear
@onready var _nick: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/NickRow/Nick
@onready var _nick_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/NickRow/Clear
@onready var _face_preview: TextureRect = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/FaceRow/Preview
@onready var _face_pick: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/FaceRow/Pick
@onready var _face_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/FaceRow/Clear
@onready var _avatar: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/AvatarRow/Avatar
@onready var _avatar_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/AvatarRow/Clear
@onready var _user_id: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/UserIdRow/UserId
@onready var _user_id_copy: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/UserIdRow/Copy
@onready var _user_id_reissue: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Content/UserIdRow/Reissue
@onready var _face_dialog: FileDialog = $FaceDialog
@onready var _cache_size: Label = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/Content/CacheRow/Size
@onready var _cache_open: Button = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/Content/CacheRow/Open
@onready var _cache_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/Content/CacheRow/Clear
@onready var _tabs: TabContainer = $Panel/Margin/VBoxContainer/TabContainer
# Корни вкладок — сами ScrollContainer'ы (прямые дети TabContainer): по ним ищем индекс вкладки
# и переставляем порядок в _setup_tabs. Контент каждой вкладки лежит в дочернем VBox «Content».
@onready var _users_tab: ScrollContainer = $Panel/Margin/VBoxContainer/TabContainer/UsersSettings
@onready var _world_tab: ScrollContainer = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings
@onready var _world_thumb: TextureRect = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/Thumb
@onready var _world_title: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/Title
@onready var _world_url: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/Url
@onready var _world_desc: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/Desc
@onready var _world_meta_label: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/MetaLabel
@onready var _world_meta: RichTextLabel = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/Meta
@onready var _world_make_home: Button = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/MakeHome
@onready var _world_home_status: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/HomeStatus
@onready var _world_go_home: Button = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/Content/GoHome
@onready var _users_list: VBoxContainer = $Panel/Margin/VBoxContainer/TabContainer/UsersSettings/Content/List
@onready var _users_empty: Label = $Panel/Margin/VBoxContainer/TabContainer/UsersSettings/Content/Empty
# Вкладка «Аккаунт» — домашний сервер и федеративная идентичность (см. docs/home-server.md).
@onready var _account_tab: ScrollContainer = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings
@onready var _hs_server: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/ServerRow/Server
@onready var _hs_server_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/ServerRow/Clear
@onready var _hs_server_status: Label = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/ServerStatus
@onready var _hs_account_status: Label = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/AccountStatus
@onready var _hs_cert_status: Label = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/CertStatus
@onready var _hs_login_box: VBoxContainer = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/LoginBox
@onready var _hs_nick: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/LoginBox/NickRow/Nick
@onready var _hs_pass: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/LoginBox/PassRow/Pass
@onready var _hs_login: Button = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/LoginBox/AuthButtons/Login
@onready var _hs_register: Button = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/LoginBox/AuthButtons/Register
@onready var _hs_authed_box: HBoxContainer = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/AuthedBox
@onready var _hs_logout: Button = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/AuthedBox/Logout
@onready var _hs_refresh: Button = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/AuthedBox/Refresh
# «Моё пространство» — создаётся в коде (нет в .tscn), кладётся в AuthedBox. Вход в
# персональное пространство домашнего сервера, независимый от домашней страницы.
var _hs_space: Button
# Раздел «Кто где сейчас» (presence.v1, docs/presence.md) — создаётся в коде, кладётся в
# конец Content вкладки «Аккаунт». Виден, когда сервер анонсирует presence.v1 (логин не
# обязателен — публичные серверы отвечают и анониму).
var _presence_box: VBoxContainer
var _presence_refresh: Button
var _presence_list: VBoxContainer
var _presence_status: Label
# Поколение запроса presence: ответ устаревшего (нажали «Обновить» повторно/переоткрыли
# экран) молча отбрасывается, чтобы не перетереть более свежий список.
var _presence_gen := 0
@onready var _hs_error: Label = $Panel/Margin/VBoxContainer/TabContainer/AccountSettings/Content/AuthError
@onready var _save: Button = $Panel/Margin/VBoxContainer/Buttons/Save
@onready var _cancel: Button = $Panel/Margin/VBoxContainer/Buttons/Cancel

# Строка статуса связи под полем адреса сигналинга (вкладка «Сеть»): «светофор» + развёрнутый
# текст (адрес, число пиров, последняя ошибка). Создаётся в коде (нет в .tscn), см.
# _build_net_status_row / _refresh_net_status.
var _net_status_dot: Panel
var _net_status_dot_style: StyleBoxFlat
var _net_status_text: Label

## Мягкий хинт под выбором микрофона (только macOS): смена входа на лету ограничена драйвером
## CoreAudio — показываем после первой смены устройства. Создаётся в рантайме (см. _ready).
var _mic_hint: Label = null

## Текущий инстанс (его URL) и его «паспорт» из <head> страницы (title/description/thumbnail/
## metas) — заполняет main при открытии настроек (см. open). Пусто — мы не в мире, вкладка
## «Мир» скрыта (как «Пользователи»).
var _instance_url: String = ""
var _page_meta: Dictionary = {}
## Лоадер превью для вкладки «Мир». Создаётся лениво; _thumb_url — URL текущего запрошенного
## превью (отбрасываем колбэки, пришедшие после смены инстанса).
var _thumb_loader: ImageLoader = null
var _thumb_url: String = ""


func _ready() -> void:
	hide()
	_setup_tabs()
	_save.pressed.connect(_on_save)
	_cancel.pressed.connect(_close)
	# Режим микрофона (PTT / голосовая активация) — применяем живьём, как усиление/порог.
	_mode.add_item("Push-to-talk (зажать V)", 0)
	_mode.add_item("Голосовая активация (V — mute)", 1)
	_mode.item_selected.connect(_on_mode_selected)
	# Вкладка «Мир»: сделать инстанс домашним и вернуться домой.
	_world_make_home.pressed.connect(_on_make_home)
	_world_go_home.pressed.connect(_on_go_home)
	_face_pick.pressed.connect(_face_dialog.popup_centered_ratio)
	_face_dialog.file_selected.connect(_on_face_selected)
	# Обзор камеры — применяем живьём (видно сразу, если экран открыт поверх мира).
	_fov_slider.value_changed.connect(_on_fov_changed)
	# Строка статуса связи под полем адреса сигналинга + подписка на смену состояния.
	_build_net_status_row()
	NetworkManager.net_status_changed.connect(_refresh_net_status.unbind(1))
	# Число пиров/потерянных p2p меняет только текст (не state) — обновляем и по этим сигналам.
	NetworkManager.p2p_peer_connected.connect(_refresh_net_status.unbind(1))
	NetworkManager.p2p_peer_disconnected.connect(_refresh_net_status.unbind(1))
	NetworkManager.peer_joined.connect(_refresh_net_status.unbind(2))
	NetworkManager.peer_left.connect(_refresh_net_status.unbind(1))
	# Очистка полей: пустые на сохранении превратятся в дефолты (placeholder подсказывает).
	_home_clear.pressed.connect(_home.clear)
	_url_clear.pressed.connect(_url.clear)
	_nick_clear.pressed.connect(_nick.clear)
	_face_clear.pressed.connect(_on_face_clear)
	_avatar_clear.pressed.connect(_avatar.clear)
	_user_id_copy.pressed.connect(_on_user_id_copy)
	_user_id_reissue.pressed.connect(_on_user_id_reissue)
	# Микрофон: выбор устройства применяем сразу (живьём), чтобы проверка шла на нём.
	_device.item_selected.connect(_on_device_selected)
	_device_refresh.pressed.connect(_populate_devices)
	# Вход не отдаёт звук после смены устройства (баг драйвера CoreAudio на macOS, -10863) —
	# просим перезапуск. См. docs/godot-coreaudio-input-rate-bug.md.
	VoiceManager.input_device_failed.connect(_on_input_device_failed)
	_setup_mic_hint()
	_test.toggled.connect(_on_test_toggled)
	_monitor.toggled.connect(_on_monitor_toggled)
	# Вывод и громкости применяем сразу (живьём), чтобы изменения было слышно до сохранения.
	_out_device.item_selected.connect(_on_out_device_selected)
	_out_refresh.pressed.connect(_populate_out_devices)
	for bus_name in _vol_sliders:
		_vol_sliders[bus_name].value_changed.connect(_on_volume_changed.bind(bus_name))
	# Усиление и порог активации микрофона — применяем живьём (слышно/видно при проверке).
	_gain_slider.value_changed.connect(_on_gain_changed)
	_thresh_slider.value_changed.connect(_on_thresh_changed)
	_cache_open.pressed.connect(_on_cache_open)
	_cache_clear.pressed.connect(_on_cache_clear)
	# Раздел «Пользователи» — живой список пиров и рангов. Любое изменение состава/таблицы/
	# авторитета/онлайна перестраивает его (хэндлеры no-op, пока экран скрыт). unbind отбрасывает
	# аргументы сигналов — нам нужен только факт изменения.
	NetworkManager.peer_joined.connect(_users_dirty.unbind(2))
	NetworkManager.peer_left.connect(_users_dirty.unbind(1))
	NetworkManager.peer_ghosted.connect(_users_dirty.unbind(3))
	NetworkManager.ghost_expired.connect(_users_dirty.unbind(1))
	NetworkManager.peer_reclaimed.connect(_users_dirty.unbind(2))
	NetworkManager.p2p_peer_connected.connect(_users_dirty.unbind(1))
	NetworkManager.p2p_peer_disconnected.connect(_users_dirty.unbind(1))
	NetworkManager.identity_received.connect(_users_dirty.unbind(4))
	NetworkManager.identity_verified.connect(_users_dirty.unbind(2))
	NetworkManager.ranks_changed.connect(_users_dirty)
	NetworkManager.authority_changed.connect(_users_dirty.unbind(2))
	NetworkManager.connection_changed.connect(_users_dirty.unbind(1))
	# Вкладка «Аккаунт»: логин/регистрация/логаут на домашнем сервере, смена его адреса.
	_hs_server_clear.pressed.connect(_hs_server.clear)
	_hs_login.pressed.connect(_on_hs_auth.bind(false))
	_hs_register.pressed.connect(_on_hs_auth.bind(true))
	_hs_logout.pressed.connect(_on_hs_logout)
	_hs_refresh.pressed.connect(_on_hs_refresh)
	# «Моё пространство» — вход в персональное пространство домашнего сервера, независимо от
	# домашней страницы (см. space_requested). Кнопки нет в .tscn — создаём и кладём в AuthedBox.
	_hs_space = Button.new()
	_hs_space.text = "Моё пространство"
	_hs_space.tooltip_text = "Перейти в персональное пространство на домашнем сервере"
	_hs_space.pressed.connect(_on_go_space)
	_hs_authed_box.add_child(_hs_space)
	_build_presence_section()
	HomeServer.state_changed.connect(_account_dirty)


## Показать экран, заполнив поля текущими значениями. instance_url/page_meta — текущий инстанс
## и его «паспорт» из <head> (см. main._extract_page_meta); пусто — мы не в мире, вкладка «Мир»
## скрыта.
func open(instance_url: String = "", page_meta: Dictionary = {}) -> void:
	_instance_url = instance_url
	_page_meta = page_meta
	_offline.button_pressed = not Settings.online_enabled
	_mode.select(_mode_to_index(Settings.voice_mode))
	_denoise.button_pressed = Settings.voice_denoise
	_home.text = Settings.home_page
	_fov_slider.set_value_no_signal(Settings.fov)
	_update_fov_label(Settings.fov)
	# Поле сигналинга: пусто = авторежим (анонс домашнего сервера / дефолт сборки) —
	# фактический адрес показываем плейсхолдером.
	_url.text = Settings.signaling_url
	_url.placeholder_text = "%s (по умолчанию)" % Settings.effective_signaling_url() \
		if Settings.effective_signaling_url() != "" else "адрес сигнального сервера"
	_refresh_net_status()
	_hs_server.text = Settings.home_server_url
	if BuildConfig.home_server_url != "":
		_hs_server.placeholder_text = "%s (по умолчанию)" % BuildConfig.home_server_url
	_hs_error.text = ""
	_hs_pass.text = ""
	_refresh_account()
	_refresh_presence()
	_nick.text = Settings.nick
	_avatar.text = Settings.avatar_uri
	_user_id.text = Settings.user_id
	_face_preview.texture = Settings.face_texture()
	_populate_devices()
	_populate_out_devices()
	for bus_name in _vol_sliders:
		# set_value_no_signal — чтобы заполнение не дёргало живое применение/перезапись.
		_vol_sliders[bus_name].set_value_no_signal(Settings.bus_volumes.get(bus_name, 1.0))
		_update_volume_label(bus_name, Settings.bus_volumes.get(bus_name, 1.0))
	_gain_slider.set_value_no_signal(Settings.mic_gain)
	_update_gain_label(Settings.mic_gain)
	_thresh_slider.set_value_no_signal(Settings.vad_threshold)
	_update_thresh_label(Settings.vad_threshold)
	_test.button_pressed = false
	_monitor.button_pressed = false
	_level.value = 0.0
	_update_cache_size()
	_update_users_availability()
	_refresh_users()
	_update_world_availability()
	_refresh_world()
	show()
	# Чат-лог добавляется в UI позже настроек, поэтому по умолчанию рисуется поверх них.
	# Поднимаем оверлей на передний план среди сиблингов, чтобы настройки перекрывали всё.
	move_to_front()
	_nick.grab_focus()


## Собирает строку статуса связи под полем адреса сигналинга: круглый «светофор» + текст.
## Кладётся сразу после UrlRow во вкладке «Сеть» (см. docs/multiplayer.md).
func _build_net_status_row() -> void:
	var url_row := _url.get_parent()   # NetSettings/UrlRow
	var net := url_row.get_parent()    # NetSettings VBoxContainer
	var row := HBoxContainer.new()
	row.name = "StatusRow"
	row.add_theme_constant_override("separation", 8)
	_net_status_dot = Panel.new()
	_net_status_dot.custom_minimum_size = Vector2(12, 12)
	_net_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_net_status_dot_style = StyleBoxFlat.new()
	_net_status_dot_style.set_corner_radius_all(6)
	_net_status_dot.add_theme_stylebox_override("panel", _net_status_dot_style)
	row.add_child(_net_status_dot)
	_net_status_text = Label.new()
	_net_status_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_status_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_net_status_text.custom_minimum_size = Vector2(320, 0)
	row.add_child(_net_status_text)
	net.add_child(row)
	net.move_child(row, url_row.get_index() + 1)


## Перекрашивает «светофор» и переписывает развёрнутый текст статуса из
## NetworkManager.connection_status(). Зовётся при открытии и по сетевым сигналам.
func _refresh_net_status() -> void:
	if _net_status_dot == null:
		return
	var st := NetworkManager.connection_status()
	_net_status_dot_style.bg_color = st.get("color", Color.GRAY)
	var txt := str(st.get("label", ""))
	var detail := str(st.get("detail", ""))
	if detail != "":
		txt += "\n" + detail
	_net_status_text.text = txt


## Обновляет подпись с текущим размером дискового кэша (аватары + видео).
func _update_cache_size() -> void:
	_cache_size.text = "Размер кэша: %s" % Cache.format_size(Cache.total_size())


## «Открыть папку» — показывает каталог кэша в системном файловом менеджере (Finder/Проводник).
func _on_cache_open() -> void:
	Cache.open_dir()


## «Очистить кэш» — удаляет скачанные аватары и видео, обновляет подпись с размером.
func _on_cache_clear() -> void:
	Cache.clear()
	_update_cache_size()


# --- Порядок вкладок ---

## «Мир» и «Пользователи» — вторая и третья вкладки. В сцене они объявлены в конце (чтобы не
## ломать редакторские tab_N/title), поэтому переставляем их в рантайме. Заголовки задаём явно
## по имени узла — надёжнее, чем полагаться на индексные tab_N/title после move_child.
func _setup_tabs() -> void:
	_tabs.move_child(_world_tab, 1)
	_tabs.move_child(_users_tab, 2)
	_tabs.move_child(_account_tab, 4)  # после «Сети» — обе про серверы
	var titles := {
		"GeneralSettings": "Основные",
		"WorldSettings": "Мир",
		"UsersSettings": "Пользователи",
		"NetSettings": "Сеть",
		"AccountSettings": "Аккаунт",
		"SecuritySettings": "Безопасность",
		"SoundSettings": "Звук",
		"MiscSettings": "Прочее",
	}
	for i in _tabs.get_tab_count():
		var ctrl := _tabs.get_tab_control(i)
		if ctrl != null and titles.has(ctrl.name):
			_tabs.set_tab_title(i, titles[ctrl.name])


# --- Раздел «Мир» (инфо об инстансе) ---

## Вкладка «Мир» доступна только когда мы в инстансе (загружена страница). Иначе прячем её
## (и, если она была активной, уводим на «Основные») — по аналогии с «Пользователями».
func _update_world_availability() -> void:
	var available := _instance_url != ""
	var idx := _tabs.get_tab_idx_from_control(_world_tab)
	if idx < 0:
		return
	_tabs.set_tab_hidden(idx, not available)
	if not available and _tabs.current_tab == idx:
		_tabs.current_tab = 0


## Заполняет вкладку «Мир» из _page_meta: заголовок, адрес, описание, прочие meta-теги и превью.
func _refresh_world() -> void:
	if _instance_url == "":
		return
	var title := str(_page_meta.get("title", "")).strip_edges()
	_world_title.text = title if title != "" else "(страница без заголовка)"
	_world_url.text = _instance_url
	var desc := str(_page_meta.get("description", "")).strip_edges()
	_world_desc.text = desc
	_world_desc.visible = desc != ""
	_refresh_world_meta()
	_load_thumb(str(_page_meta.get("thumbnail", "")))
	_update_home_status()


## Осмысленные meta-данные страницы (подпись → значение; технические теги отфильтрованы в
## main._extract_page_meta). Скрываем блок и заголовок, если показывать нечего.
func _refresh_world_meta() -> void:
	var metas: Array = _page_meta.get("metas", [])
	_world_meta.clear()
	var shown := 0
	for m in metas:
		var label := str(m.get("label", ""))
		var value := str(m.get("value", ""))
		if label == "" or value == "":
			continue
		_world_meta.append_text("[b]%s[/b]: %s\n" % [_esc_bb(label), _esc_bb(value)])
		shown += 1
	_world_meta.visible = shown > 0
	_world_meta_label.visible = shown > 0


## Экранирует "[" в тексте, чтобы он не воспринимался как BBCode-тег.
func _esc_bb(s: String) -> String:
	return s.replace("[", "[lb]")


## Подгружает превью инстанса (og:image и т.п.) по URL. Лоадер общий с миром (ImageLoader):
## декодирует/кэширует сам. Колбэк проверяет актуальность (мог прийти после смены инстанса).
func _load_thumb(url: String) -> void:
	_thumb_url = url
	_world_thumb.texture = null
	_world_thumb.visible = url != ""
	if url == "":
		return
	if _thumb_loader == null:
		_thumb_loader = ImageLoader.new()
		add_child(_thumb_loader)
	_thumb_loader.request_image(url, func(tex: Texture2D) -> void:
		if _thumb_url != url:
			return
		_world_thumb.texture = tex
		_world_thumb.visible = tex != null
	)


## Обновляет подпись/кнопки в зависимости от того, является ли текущий инстанс домашним и
## задан ли вообще домашний инстанс.
func _update_home_status() -> void:
	var home := Settings.home_page.strip_edges()
	var is_home := home != "" and home == _instance_url
	_world_make_home.disabled = is_home
	_world_home_status.visible = is_home
	# «Домой» доступна, если задана домашняя страница ИЛИ есть персональное пространство на
	# домашнем сервере (при пустом home_page main грузит его, см. docs/personal-spaces.md).
	var has_space: bool = HomeServer.is_logged_in() and HomeServer.supports("personal-spaces.v1")
	_world_go_home.disabled = home == "" and not has_space
	if home != "":
		_world_go_home.tooltip_text = "Загрузить домашний инстанс"
	elif has_space:
		_world_go_home.tooltip_text = "Перейти в персональное пространство на домашнем сервере"
	else:
		_world_go_home.tooltip_text = "Домашний инстанс не задан"


## «Сделать инстанс домашним»: запоминаем текущий URL как домашнюю страницу и сразу сохраняем
## (как очистка кэша/смена лица — не дожидаясь «Сохранить»). Поле на вкладке «Основные» тоже
## обновляем, чтобы оно не перетёрло значение при следующем «Сохранить».
func _on_make_home() -> void:
	Settings.home_page = _instance_url
	Settings.save()
	_home.text = _instance_url
	_update_home_status()


## «Вернуться домой»: просим main загрузить домашний инстанс и закрываемся.
func _on_go_home() -> void:
	home_requested.emit()
	_close()


## «Моё пространство»: просим main перейти в персональное пространство домашнего сервера и
## закрываемся. Отдельно от «Домой»: пространство доступно даже при заданной домашней странице.
func _on_go_space() -> void:
	space_requested.emit()
	_close()


# --- Раздел «Аккаунт» (домашний сервер, см. docs/home-server.md) ---

## Состояние HomeServer изменилось (discovery/логин/сертификат) — перерисовать, пока видимы.
func _account_dirty() -> void:
	if visible:
		_refresh_account()


## Заполняет статусы вкладки «Аккаунт» и переключает блоки логин/залогинен.
func _refresh_account() -> void:
	var url: String = HomeServer.server_url()
	if url == "":
		_hs_server_status.text = "Домашний сервер не задан — вход недоступен."
	elif HomeServer.busy:
		_hs_server_status.text = "%s — обращение к серверу…" % url
	elif HomeServer.discovery_error != "":
		_hs_server_status.text = "%s — ошибка: %s" % [url, HomeServer.discovery_error]
	elif not HomeServer.discovery.is_empty():
		var srv: Dictionary = HomeServer.discovery.get("server", {})
		var feats: Array = HomeServer.discovery.get("features", [])
		_hs_server_status.text = "%s (%s) — функции: %s" \
			% [srv.get("name", srv.get("domain", "?")), srv.get("domain", "?"), ", ".join(feats)]
	else:
		_hs_server_status.text = url
	# Небезопасный режим идентичности (локалка/тесты) — предупреждаем, что галочки не строгие.
	if HomeServer.insecure_identity():
		_hs_server_status.text += "\n⚠ Небезопасный режим идентичности включён — проверки ослаблены (только для разработки)."
	var logged: bool = HomeServer.is_logged_in()
	_hs_account_status.text = "Вы вошли как %s" % HomeServer.address if logged \
		else "Вы не вошли — для других вы аноним с самозаявленным ID."
	if HomeServer.has_certificate():
		_hs_cert_status.text = "Сертификат идентичности действует до %s (UTC)." \
			% Time.get_datetime_string_from_unix_time(HomeServer.certificate_expires_at(), true)
	else:
		_hs_cert_status.text = "Сертификата идентичности нет."
	_hs_login_box.visible = not logged
	_hs_authed_box.visible = logged
	var busy: bool = HomeServer.busy
	_hs_login.disabled = busy or url == ""
	_hs_register.disabled = busy or url == ""
	_hs_logout.disabled = busy
	_hs_refresh.disabled = busy
	# «Моё пространство» — только когда сервер анонсирует personal-spaces.v1 (иначе идти некуда).
	_hs_space.visible = logged and HomeServer.supports("personal-spaces.v1")
	_hs_space.disabled = busy
	# «Кто где сейчас» — когда сервер анонсирует presence.v1 (логин не обязателен).
	_presence_box.visible = HomeServer.supports("presence.v1")


## Если адрес сервера в поле отличается от сохранённого — применяем и персистим сразу
## (как «Сделать инстанс домашним»): логин должен идти на видимый в поле сервер, а
## HomeServer сам среагирует на смену (Settings.changed → refresh).
func _commit_hs_server_field() -> void:
	var url := _hs_server.text.strip_edges()
	if url != Settings.home_server_url:
		Settings.home_server_url = url
		Settings.save()


## «Войти» / «Зарегистрироваться» (register = true). Ошибка — в строку под кнопками.
func _on_hs_auth(register: bool) -> void:
	_commit_hs_server_field()
	var nickname := _hs_nick.text.strip_edges()
	var password := _hs_pass.text
	if nickname == "" or password == "":
		_hs_error.text = "Введите имя и пароль."
		return
	_hs_error.text = ""
	var err: String
	if register:
		err = await HomeServer.register_account(nickname, password)
	else:
		err = await HomeServer.login(nickname, password)
	_hs_error.text = err
	if err == "":
		_hs_pass.text = ""
		_nick.text = Settings.nick  # логин мог заменить дефолтный Guest-ник на имя аккаунта
	_account_dirty()


func _on_hs_logout() -> void:
	_hs_error.text = ""
	await HomeServer.logout()
	_account_dirty()


## «Обновить»: заново опросить сервер (discovery, валидность токена, продление сертификата).
func _on_hs_refresh() -> void:
	_hs_error.text = ""
	_commit_hs_server_field()
	await HomeServer.refresh()
	_account_dirty()


# --- Раздел «Кто где сейчас» (presence.v1, docs/presence.md) ---

## Собирает раздел presence в конце Content вкладки «Аккаунт»: заголовок с кнопкой
## «Обновить», строка статуса и список страниц-кнопок (заполняет _refresh_presence).
func _build_presence_section() -> void:
	var content := _hs_authed_box.get_parent()  # AccountSettings/Content
	_presence_box = VBoxContainer.new()
	_presence_box.name = "PresenceBox"
	_presence_box.visible = false
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "Кто где сейчас"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_presence_refresh = Button.new()
	_presence_refresh.text = "Обновить"
	_presence_refresh.tooltip_text = "Заново запросить у домашнего сервера, где сейчас люди"
	_presence_refresh.pressed.connect(_refresh_presence)
	header.add_child(_presence_refresh)
	_presence_box.add_child(header)
	_presence_status = Label.new()
	_presence_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_presence_box.add_child(_presence_status)
	_presence_list = VBoxContainer.new()
	_presence_box.add_child(_presence_list)
	content.add_child(_presence_box)


## Запрашивает сводку у домашнего сервера и пересобирает список. Устаревшие ответы
## (запрос перезапущен) отбрасываются по поколению.
func _refresh_presence() -> void:
	if not HomeServer.supports("presence.v1"):
		return
	_presence_gen += 1
	var gen := _presence_gen
	_presence_status.text = "Загрузка…"
	_presence_refresh.disabled = true
	var res: Dictionary = await HomeServer.fetch_presence()
	if gen != _presence_gen:
		return
	_presence_refresh.disabled = false
	for child in _presence_list.get_children():
		child.queue_free()
	if not res["ok"]:
		_presence_status.text = str(res["error"])
		return
	var rooms: Array = res["rooms"]
	var total := int(res.get("total", rooms.size()))
	if rooms.is_empty():
		_presence_status.text = "Сейчас никого нет в сети."
	elif total > rooms.size():
		# Сервер обрезал выдачу (его право по контракту) — не выдаём частичное за полное.
		_presence_status.text = "Показаны %d из %d страниц." % [rooms.size(), total]
	else:
		_presence_status.text = ""
	for room in rooms:
		if typeof(room) != TYPE_DICTIONARY:
			continue
		var url := str(room.get("url", ""))
		if url == "":
			continue
		var count := int(room.get("count", 0))
		var text := "%s — %d чел." % [url, count]
		var tags: Array = room.get("tags", []) if typeof(room.get("tags")) == TYPE_ARRAY else []
		if not tags.is_empty():
			text += "  [%s]" % ", ".join(tags.map(func(t): return str(t)))
		var row := Button.new()
		row.text = text
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.tooltip_text = "Перейти на эту страницу"
		row.pressed.connect(_on_presence_go.bind(url))
		_presence_list.add_child(row)


## Клик по странице из presence-списка: просим main перейти и закрываемся.
func _on_presence_go(url: String) -> void:
	presence_url_requested.emit(url)
	_close()


# --- Раздел «Пользователи» (см. docs/ranks.md) ---

## Реакция на любое сетевое изменение: пока экран виден — пересобрать вкладку. Иначе no-op.
func _users_dirty() -> void:
	if not visible:
		return
	_update_users_availability()
	_refresh_users()


## Вкладка «Пользователи» доступна только онлайн и в инстансе. Иначе прячем её (и, если она
## была активной, уводим на «Сеть»).
func _update_users_availability() -> void:
	var available := NetworkManager.is_online() and NetworkManager.in_room()
	var idx := _tabs.get_tab_idx_from_control(_users_tab)
	if idx < 0:
		return
	_tabs.set_tab_hidden(idx, not available)
	if not available and _tabs.current_tab == idx:
		_tabs.current_tab = 0


## Перестроить список: мы + все онлайн-пиры + записи о рангах для офлайн-юзеров. Для
## авторитета у чужих строк — контролы правки ранга. Отметка авторитета — символом «★».
func _refresh_users() -> void:
	for child in _users_list.get_children():
		child.queue_free()
	var ranks := NetworkManager.ranks_snapshot()
	var is_auth := NetworkManager.has_authority()
	var authority_uid := NetworkManager.authority_user_id()
	var shown_uids := {}
	var rows := 0
	# 1) Мы сами — первой строкой (только просмотр). Наш «подтверждённый адрес» — адрес
	# аккаунта, если есть действующий сертификат (пирам мы предъявляем именно его).
	var my_address: String = HomeServer.address if HomeServer.has_certificate() else ""
	_add_user_row(Settings.nick, Settings.user_id, true, true, ranks, is_auth, authority_uid, true, my_address)
	shown_uids[Settings.user_id] = true
	rows += 1
	# 2) Онлайн-пиры (у некоторых user_id может быть ещё не получен из карточки).
	for pid in NetworkManager.peer_ids():
		var uid := NetworkManager.user_id_of(pid)
		if uid != "":
			shown_uids[uid] = true
		_add_user_row(NetworkManager.nick_of(pid), uid, true, NetworkManager.peer_p2p_connected(pid), ranks, is_auth, authority_uid, false, NetworkManager.verified_address_of(pid), NetworkManager.peer_p2p_lost(pid))
		rows += 1
	# 3) «Призраки»: недавно ушли, ждём переподключения (grace-период, см. NetworkManager).
	var ghosts := NetworkManager.ghosts_snapshot()
	for uid in ghosts.keys():
		if shown_uids.has(uid):
			continue
		shown_uids[uid] = true
		_add_ghost_row(str(ghosts[uid].get("nick", "")), uid, ranks)
		rows += 1
	# 4) Ранги без онлайн-пира: запись есть, человека нет.
	for uid in ranks.keys():
		if shown_uids.has(uid):
			continue
		_add_user_row("", uid, false, false, ranks, is_auth, authority_uid, false, "")
		rows += 1
	_users_empty.visible = rows == 0


## Строка «призрака»: пир только что ушёл, NetworkManager ждёт его переподключения
## (grace-период). Оранжевая иконка no-connection + серый ник; ранг — только просмотр
## (запись в таблице жива, вернётся вместе с пиром).
func _add_ghost_row(nick: String, uid: String, ranks: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var icon := TextureRect.new()
	icon.texture = StatusIcons.texture(StatusIcons.Status.OFFLINE)
	icon.self_modulate = StatusIcons.color(StatusIcons.Status.OFFLINE)
	icon.custom_minimum_size = Vector2(16, 16)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var name_label := Label.new()
	name_label.text = "%s (нет связи)" % (nick if nick != "" else "Гость")
	name_label.tooltip_text = "user_id: %s\nПир отключился — ждём переподключения" % uid
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(name_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var rank_label := Label.new()
	rank_label.text = ("ранг %d" % int(ranks[uid])) if ranks.has(uid) else "—"
	rank_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(rank_label)
	_users_list.add_child(row)


## Одна строка списка. uid == "" — карточка пира ещё не пришла (рангом управлять нельзя).
## p2p_connected отличает «видим ник через сигналинг» от «RPC-канал реально открыт»;
## p2p_lost — канал БЫЛ открыт и оборвался (пир ещё в комнате) — рисуем иконку no-connection.
## is_self — это мы (только просмотр). authority_uid — user_id авторитета (для отметки «★»).
## verified — криптографически подтверждённый адрес nick@domain ("" — аноним/не проверен),
## см. docs/home-server.md.
func _add_user_row(nick: String, uid: String, online: bool, p2p_connected: bool, ranks: Dictionary, is_auth: bool, authority_uid: String, is_self: bool, verified: String, p2p_lost: bool = false) -> void:
	var has_rank := uid != "" and ranks.has(uid)
	var is_authority := uid != "" and uid == authority_uid
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_label := Label.new()
	name_label.text = _user_display_name(nick, uid, online, p2p_connected, is_self, is_authority, p2p_lost)
	var tip := "user_id: %s" % uid if uid != "" else ""
	if verified != "":
		tip = (tip + "\n" if tip != "" else "") \
			+ "✓ %s — личность подтверждена домашним сервером" % verified
	if is_authority:
		tip = (tip + "\n" if tip != "" else "") + "★ — авторитет (раздаёт ранги)"
	elif p2p_lost:
		tip = "WebRTC-канал к пиру оборвался (пир ещё в комнате по сигналингу)"
	elif online and not p2p_connected:
		tip = "Пир виден через сигналинг, но WebRTC/RPC-канал ещё не открылся"
	name_label.tooltip_text = tip
	if not online or p2p_lost:
		name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(name_label)

	# Обрыв связи — та же иконка no-connection, что и над неймплейтом (StatusIcons.OFFLINE).
	if p2p_lost:
		var conn_icon := TextureRect.new()
		conn_icon.texture = StatusIcons.texture(StatusIcons.Status.OFFLINE)
		conn_icon.self_modulate = StatusIcons.color(StatusIcons.Status.OFFLINE)
		conn_icon.custom_minimum_size = Vector2(16, 16)
		conn_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		conn_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		conn_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		conn_icon.tooltip_text = tip
		row.add_child(conn_icon)

	# Подтверждённая идентичность — та же иконка-галочка, что и в неймплейте (StatusIcons).
	if verified != "":
		var icon := TextureRect.new()
		icon.texture = StatusIcons.texture(StatusIcons.Status.VERIFIED)
		icon.self_modulate = StatusIcons.color(StatusIcons.Status.VERIFIED)
		icon.custom_minimum_size = Vector2(16, 16)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon.tooltip_text = tip
		row.add_child(icon)
		var addr_label := Label.new()
		addr_label.text = verified
		addr_label.tooltip_text = tip
		addr_label.add_theme_color_override("font_color", Color(0.72, 0.85, 0.95))
		row.add_child(addr_label)

	# Распорка прижимает ранг/кнопки вправо (раньше это делал EXPAND_FILL на имени).
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	if is_self or not is_auth:
		# Себя и обычные пиры — только просмотр. Нет ранга — не выводим явную инфу (просто «—»).
		var rank_label := Label.new()
		rank_label.text = ("ранг %d" % int(ranks[uid])) if has_rank else "—"
		if not has_rank:
			rank_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(rank_label)
	elif uid != "":
		# Авторитет правит чужой ранг: задать значение и удалить запись.
		var spin := SpinBox.new()
		spin.min_value = 0
		spin.max_value = 1 << 20
		spin.step = 1
		spin.value = ranks.get(uid, 1) if has_rank else 1
		spin.custom_minimum_size = Vector2(90, 0)
		spin.tooltip_text = "Ранг (0 — максимум прав)"
		row.add_child(spin)
		var set_btn := Button.new()
		set_btn.text = "Задать"
		set_btn.pressed.connect(_on_set_rank.bind(uid, spin))
		row.add_child(set_btn)
		var del_btn := Button.new()
		del_btn.text = "Удалить ранг"
		del_btn.disabled = not has_rank
		del_btn.tooltip_text = "Убрать запись о ранге (вернётся к минимальным правам)"
		del_btn.pressed.connect(_on_clear_rank.bind(uid))
		row.add_child(del_btn)
	else:
		# Онлайн-пир без p2p или без полученной карточки — рангом пока управлять нельзя.
		var note := Label.new()
		if p2p_lost:
			note.text = "нет связи"
		else:
			note.text = "P2P подключается" if not p2p_connected else "ID ещё не получен"
		note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(note)

	_users_list.add_child(row)


## Подпись строки: ник для онлайн-пира, короткий user_id для офлайн-записи, «(вы)» для себя,
## «★» для авторитета, «(нет связи)» при обрыве p2p-канала.
func _user_display_name(nick: String, uid: String, online: bool, p2p_connected: bool, is_self: bool, is_authority: bool, p2p_lost: bool = false) -> String:
	var base := ""
	if online:
		var who := nick if nick != "" else "Гость"
		base = "● %s" % who
		if p2p_lost:
			base += " (нет связи)"
		elif not p2p_connected:
			base += " (P2P подключается)"
		elif uid == "":
			base += " (ID ещё не получен)"
	else:
		base = "○ ID %s… (офлайн)" % uid.substr(0, 8)
	if is_self:
		base += " (вы)"
	if is_authority:
		base += " ★"
	return base


## Авторитет задаёт ранг пиру (по user_id и значению спинбокса). Рассылка/перерисовка —
## по сигналу ranks_changed.
func _on_set_rank(uid: String, spin: SpinBox) -> void:
	NetworkManager.set_rank(uid, int(spin.value))


## Авторитет удаляет запись о ранге пользователя.
func _on_clear_rank(uid: String) -> void:
	NetworkManager.clear_rank(uid)


## Индекс пункта селектора режима (0 — PTT, 1 — VAD) по строковому режиму Settings.
func _mode_to_index(mode: String) -> int:
	return 1 if mode == Settings.VOICE_MODE_VAD else 0


## Строковый режим Settings по индексу пункта селектора.
func _index_to_mode(idx: int) -> String:
	return Settings.VOICE_MODE_VAD if idx == 1 else Settings.VOICE_MODE_PTT


## Смена режима микрофона — применяем к VoiceManager живьём (персистится по «Сохранить»).
func _on_mode_selected(idx: int) -> void:
	Settings.voice_mode = _index_to_mode(idx)
	VoiceManager.set_mode(Settings.voice_mode)


## Заполняет список входных устройств и выделяет текущее (по Settings.input_device).
func _populate_devices() -> void:
	_device.clear()
	var selected := 0
	var devices := VoiceManager.input_device_list()
	for i in devices.size():
		_device.add_item(devices[i])
		if devices[i] == Settings.input_device:
			selected = i
	if _device.item_count > 0:
		_device.select(selected)


## Создаёт мягкий хинт под строкой выбора микрофона — только на macOS, где смена входа на лету
## ограничена драйвером CoreAudio (см. docs/godot-coreaudio-input-rate-bug.md). Скрыт, пока
## пользователь не переключит устройство (_on_device_selected).
func _setup_mic_hint() -> void:
	if OS.get_name() != "macOS":
		return
	_mic_hint = Label.new()
	_mic_hint.text = "macOS: смена микрофона на лету ограничена (особенно Bluetooth). Если после " \
		+ "переключения звук искажён или пропал — перезапустите приложение."
	_mic_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mic_hint.add_theme_font_size_override("font_size", 12)
	_mic_hint.modulate = Color(1.0, 1.0, 1.0, 0.6)
	_mic_hint.hide()
	var mic_row: Node = _device.get_parent()
	var sound: Node = mic_row.get_parent()
	sound.add_child(_mic_hint)
	sound.move_child(_mic_hint, mic_row.get_index() + 1)


func _on_device_selected(idx: int) -> void:
	Settings.input_device = _device.get_item_text(idx)
	VoiceManager.apply_input_device(Settings.input_device)
	# Мягкий хинт: смена входа на лету ненадёжна на macOS — показываем после первого переключения.
	if _mic_hint:
		_mic_hint.show()


## Выбранный микрофон не отдаёт звук (вход залип в режиме/частоте старта — баг драйвера CoreAudio
## на macOS, см. docs/godot-coreaudio-input-rate-bug.md). Из рантайма не лечится — просим перезапуск
## с нужным устройством по умолчанию. Диалог создаём лениво (нужен редко).
func _on_input_device_failed(device_name: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Микрофон недоступен"
	dialog.dialog_text = "Не удалось включить «%s».\n\nНа macOS смена микрофона на лету " % device_name \
		+ "ограничена аудиодрайвером (особенно с Bluetooth-гарнитурой). Перезапустите " \
		+ "приложение — выбранное устройство применится при старте."
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


## Заполняет список выходных устройств и выделяет текущее (по Settings.output_device).
func _populate_out_devices() -> void:
	_out_device.clear()
	var selected := 0
	var devices := AudioServer.get_output_device_list()
	for i in devices.size():
		_out_device.add_item(devices[i])
		if devices[i] == Settings.output_device:
			selected = i
	if _out_device.item_count > 0:
		_out_device.select(selected)


func _on_out_device_selected(idx: int) -> void:
	Settings.output_device = _out_device.get_item_text(idx)
	AudioServer.output_device = Settings.output_device


## Движение ползунка громкости: применяем к шине живьём и обновляем подпись «%».
func _on_volume_changed(value: float, bus_name: String) -> void:
	Settings.bus_volumes[bus_name] = value
	Settings.apply_audio()
	_update_volume_label(bus_name, value)


func _update_volume_label(bus_name: String, value: float) -> void:
	_vol_values[bus_name].text = "%d%%" % roundi(value * 100.0)


## Движение ползунка обзора камеры: применяем живьём (Settings.changed слушает Player) и
## обновляем подпись в градусах.
func _on_fov_changed(value: float) -> void:
	Settings.fov = value
	Settings.changed.emit()
	_update_fov_label(value)


func _update_fov_label(value: float) -> void:
	_fov_value.text = "%d°" % roundi(value)


## Движение ползунка усиления микрофона: применяем к VoiceManager живьём (видно по индикатору).
func _on_gain_changed(value: float) -> void:
	Settings.mic_gain = value
	VoiceManager.set_input_gain(value)
	_update_gain_label(value)


func _update_gain_label(value: float) -> void:
	_gain_value.text = "%d%%" % roundi(value * 100.0)


## Движение ползунка порога активации: применяем к VAD живьём.
func _on_thresh_changed(value: float) -> void:
	Settings.vad_threshold = value
	VoiceManager.set_vad_threshold(value)
	_update_thresh_label(value)


func _update_thresh_label(value: float) -> void:
	_thresh_value.text = "%d%%" % roundi(value / THRESH_MAX * 100.0)
	# Метка на индикаторе уровня: позиция = доля порога от шкалы индикатора (та же RMS-шкала).
	var ratio := clampf(value / _level.max_value, 0.0, 1.0)
	_thresh_marker.anchor_left = ratio
	_thresh_marker.anchor_right = ratio


## «Проверить микрофон» — включает мониторинг (уровень + опц. loopback); по выключении глушим.
func _on_test_toggled(pressed: bool) -> void:
	VoiceManager.set_monitoring(pressed, _monitor.button_pressed)
	if not pressed:
		_level.value = 0.0


func _on_monitor_toggled(pressed: bool) -> void:
	# Меняем loopback на лету, не сбрасывая проверку.
	VoiceManager.set_monitoring(_test.button_pressed, pressed)


func _process(_delta: float) -> void:
	# Пока проверка активна — гоним уровень входа в индикатор.
	if visible and _test.button_pressed:
		_level.value = VoiceManager.input_level()


## Останавливает проверку микрофона (отпускает устройство), если она была включена.
func _stop_test() -> void:
	if _test.button_pressed:
		_test.button_pressed = false
	VoiceManager.set_monitoring(false)


## Выбран файл лица: ресайз до 256×256 и сохранение делает Settings; обновляем превью.
func _on_face_selected(path: String) -> void:
	if Settings.set_face_from_file(path):
		_face_preview.texture = Settings.face_texture()


## Сброс лица к дефолту (resources/default_face.png).
func _on_face_clear() -> void:
	Settings.reset_face()
	_face_preview.texture = Settings.face_texture()


## «Копировать» сетевой ID в системный буфер обмена (надёжнее ручного выделения, особенно на iOS).
func _on_user_id_copy() -> void:
	DisplayServer.clipboard_set(Settings.user_id)


## «Переиздать» сетевой ID: сразу генерим новый, персистим и показываем. Действие применяется
## немедленно (как очистка кэша/смена лица), не дожидаясь «Сохранить». Если онлайн — рассылаем
## обновлённую карточку, чтобы пиры обновили привязку peer_id→user_id. Старые ранги, выданные
## прежнему id, при этом теряются (см. docs/ranks.md).
func _on_user_id_reissue() -> void:
	_user_id.text = Settings.regenerate_user_id()
	NetworkManager.broadcast_identity()


func _on_save() -> void:
	Settings.online_enabled = not _offline.button_pressed
	# Режим микрофона уже применён живьём (_on_mode_selected) — здесь только фиксируем на сохранение.
	Settings.voice_mode = _index_to_mode(_mode.selected)
	# Денойз применяем живьём (пересоберёт энкодер), чтобы изменение действовало сразу.
	Settings.voice_denoise = _denoise.button_pressed
	VoiceManager.set_denoise(Settings.voice_denoise)
	# Домашняя страница: пусто — без автозагрузки при запуске.
	Settings.home_page = _home.text.strip_edges()
	# Адрес сигналинга: пусто = авторежим (анонс домашнего сервера / дефолт сборки),
	# см. Settings.effective_signaling_url.
	Settings.signaling_url = _url.text.strip_edges()
	# Домашний сервер: пусто = дефолт сборки (BuildConfig.home_server_url).
	Settings.home_server_url = _hs_server.text.strip_edges()
	var nick := _nick.text.strip_edges()
	Settings.nick = nick if nick != "" else Settings.random_nick()
	# Пустой адрес аватара → дефолт из пака (vrwebavatar://1).
	var avatar := _avatar.text.strip_edges()
	Settings.avatar_uri = avatar if avatar != "" else Settings.DEFAULT_AVATAR_URI
	Settings.save()
	_close()


func _close() -> void:
	_stop_test()
	hide()
	closed.emit()


## Esc закрывает экран. Ловим в _input (а не _unhandled_input), чтобы перехватить событие
## раньше игрока: при открытом оверлее мышь свободна, и иначе Player._unhandled_input принял
## бы тот же Esc за «открыть настройки» и погасил бы его (оверлей бы не закрылся).
func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
