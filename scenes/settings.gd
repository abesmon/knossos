extends Control

## Overlay-экран настроек. main инстансит его поверх UI (скрытым) и показывает по кнопке
## «⚙». Редактирует значения автолоада Settings; по «Сохранить» пишет их и закрывается.
## Сам мир не трогает — поэтому навигация/состояние не теряются.

signal closed
## «Вернуться домой» на вкладке «Мир»: просим main загрузить домашний инстанс.
signal home_requested

## Верх диапазона ползунка порога активации (RMS) — для перевода значения в проценты в подписи.
const THRESH_MAX := 0.15

@onready var _online: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Online
@onready var _voice: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Voice
@onready var _denoise: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Denoise
@onready var _device: OptionButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/MicRow/Device
@onready var _device_refresh: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/MicRow/Refresh
@onready var _test: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/TestRow/Test
@onready var _monitor: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/TestRow/Monitor
@onready var _level: ProgressBar = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Level
@onready var _thresh_marker: ColorRect = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Level/Threshold
@onready var _gain_slider: HSlider = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/GainRow/Slider
@onready var _gain_value: Label = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/GainRow/Value
@onready var _thresh_slider: HSlider = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/ThreshRow/Slider
@onready var _thresh_value: Label = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/ThreshRow/Value
@onready var _out_device: OptionButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/OutRow/Device
@onready var _out_refresh: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/OutRow/Refresh
## Ползунки громкости шин: имя шины (как в Settings.AUDIO_BUSES) → HSlider + его Label-значение.
@onready var _vol_sliders := {
	"Master": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/VolMaster/Slider,
	"World": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/VolWorld/Slider,
	"Voice": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/VolVoice/Slider,
}
@onready var _vol_values := {
	"Master": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/VolMaster/Value,
	"World": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/VolWorld/Value,
	"Voice": $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/VolVoice/Value,
}
@onready var _home: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/GeneralSettings/HomeRow/Home
@onready var _home_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/GeneralSettings/HomeRow/Clear
@onready var _url: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UrlRow/Url
@onready var _url_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UrlRow/Clear
@onready var _nick: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/NickRow/Nick
@onready var _nick_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/NickRow/Clear
@onready var _face_preview: TextureRect = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/FaceRow/Preview
@onready var _face_pick: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/FaceRow/Pick
@onready var _face_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/FaceRow/Clear
@onready var _avatar: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/AvatarRow/Avatar
@onready var _avatar_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/AvatarRow/Clear
@onready var _user_id: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UserIdRow/UserId
@onready var _user_id_copy: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UserIdRow/Copy
@onready var _user_id_reissue: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UserIdRow/Reissue
@onready var _face_dialog: FileDialog = $FaceDialog
@onready var _cache_size: Label = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/CacheRow/Size
@onready var _cache_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/CacheRow/Clear
@onready var _tabs: TabContainer = $Panel/Margin/VBoxContainer/TabContainer
@onready var _users_root: VBoxContainer = $Panel/Margin/VBoxContainer/TabContainer/UsersSettings
@onready var _world_root: VBoxContainer = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings
@onready var _world_thumb: TextureRect = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/InfoScroll/Info/Thumb
@onready var _world_title: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/InfoScroll/Info/Title
@onready var _world_url: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/InfoScroll/Info/Url
@onready var _world_desc: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/InfoScroll/Info/Desc
@onready var _world_meta_label: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/InfoScroll/Info/MetaLabel
@onready var _world_meta: RichTextLabel = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/InfoScroll/Info/Meta
@onready var _world_make_home: Button = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/MakeHome
@onready var _world_home_status: Label = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/HomeStatus
@onready var _world_go_home: Button = $Panel/Margin/VBoxContainer/TabContainer/WorldSettings/GoHome
@onready var _users_list: VBoxContainer = $Panel/Margin/VBoxContainer/TabContainer/UsersSettings/UsersScroll/List
@onready var _users_empty: Label = $Panel/Margin/VBoxContainer/TabContainer/UsersSettings/Empty
@onready var _save: Button = $Panel/Margin/VBoxContainer/Buttons/Save
@onready var _cancel: Button = $Panel/Margin/VBoxContainer/Buttons/Cancel

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
	# Вкладка «Мир»: сделать инстанс домашним и вернуться домой.
	_world_make_home.pressed.connect(_on_make_home)
	_world_go_home.pressed.connect(_on_go_home)
	_face_pick.pressed.connect(_face_dialog.popup_centered_ratio)
	_face_dialog.file_selected.connect(_on_face_selected)
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
	_cache_clear.pressed.connect(_on_cache_clear)
	# Раздел «Пользователи» — живой список пиров и рангов. Любое изменение состава/таблицы/
	# авторитета/онлайна перестраивает его (хэндлеры no-op, пока экран скрыт). unbind отбрасывает
	# аргументы сигналов — нам нужен только факт изменения.
	NetworkManager.peer_joined.connect(_users_dirty.unbind(2))
	NetworkManager.peer_left.connect(_users_dirty.unbind(1))
	NetworkManager.identity_received.connect(_users_dirty.unbind(4))
	NetworkManager.ranks_changed.connect(_users_dirty)
	NetworkManager.authority_changed.connect(_users_dirty.unbind(2))
	NetworkManager.connection_changed.connect(_users_dirty.unbind(1))


## Показать экран, заполнив поля текущими значениями. instance_url/page_meta — текущий инстанс
## и его «паспорт» из <head> (см. main._extract_page_meta); пусто — мы не в мире, вкладка «Мир»
## скрыта.
func open(instance_url: String = "", page_meta: Dictionary = {}) -> void:
	_instance_url = instance_url
	_page_meta = page_meta
	_online.button_pressed = Settings.online_enabled
	_voice.button_pressed = Settings.voice_enabled
	_denoise.button_pressed = Settings.voice_denoise
	_home.text = Settings.home_page
	_url.text = Settings.signaling_url
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
	_nick.grab_focus()


## Обновляет подпись с текущим размером дискового кэша (аватары + видео).
func _update_cache_size() -> void:
	_cache_size.text = "Размер кэша: %s" % Cache.format_size(Cache.total_size())


## «Очистить кэш» — удаляет скачанные аватары и видео, обновляет подпись с размером.
func _on_cache_clear() -> void:
	Cache.clear()
	_update_cache_size()


# --- Порядок вкладок ---

## «Мир» и «Пользователи» — вторая и третья вкладки. В сцене они объявлены в конце (чтобы не
## ломать редакторские tab_N/title), поэтому переставляем их в рантайме. Заголовки задаём явно
## по имени узла — надёжнее, чем полагаться на индексные tab_N/title после move_child.
func _setup_tabs() -> void:
	_tabs.move_child(_world_root, 1)
	_tabs.move_child(_users_root, 2)
	var titles := {
		"GeneralSettings": "Основные",
		"WorldSettings": "Мир",
		"UsersSettings": "Пользователи",
		"NetSettings": "Сеть",
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
	var idx := _tabs.get_tab_idx_from_control(_world_root)
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
	_world_go_home.disabled = home == ""
	_world_go_home.tooltip_text = "Домашний инстанс не задан" if home == "" else "Загрузить домашний инстанс"


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
	var idx := _tabs.get_tab_idx_from_control(_users_root)
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
	# 1) Мы сами — первой строкой (только просмотр).
	_add_user_row(Settings.nick, Settings.user_id, true, ranks, is_auth, authority_uid, true)
	shown_uids[Settings.user_id] = true
	rows += 1
	# 2) Онлайн-пиры (у некоторых user_id может быть ещё не получен из карточки).
	for pid in NetworkManager.peer_ids():
		var uid := NetworkManager.user_id_of(pid)
		if uid != "":
			shown_uids[uid] = true
		_add_user_row(NetworkManager.nick_of(pid), uid, true, ranks, is_auth, authority_uid, false)
		rows += 1
	# 3) Ранги без онлайн-пира: запись есть, человека нет.
	for uid in ranks.keys():
		if shown_uids.has(uid):
			continue
		_add_user_row("", uid, false, ranks, is_auth, authority_uid, false)
		rows += 1
	_users_empty.visible = rows == 0


## Одна строка списка. uid == "" — карточка пира ещё не пришла (рангом управлять нельзя).
## is_self — это мы (только просмотр). authority_uid — user_id авторитета (для отметки «★»).
func _add_user_row(nick: String, uid: String, online: bool, ranks: Dictionary, is_auth: bool, authority_uid: String, is_self: bool) -> void:
	var has_rank := uid != "" and ranks.has(uid)
	var is_authority := uid != "" and uid == authority_uid
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text = _user_display_name(nick, uid, online, is_self, is_authority)
	var tip := "user_id: %s" % uid if uid != "" else ""
	if is_authority:
		tip = (tip + "\n" if tip != "" else "") + "★ — авторитет (раздаёт ранги)"
	name_label.tooltip_text = tip
	if not online:
		name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(name_label)

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
		# Онлайн-пир без полученной карточки — рангом пока управлять нельзя.
		var note := Label.new()
		note.text = "ID ещё не получен"
		note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		row.add_child(note)

	_users_list.add_child(row)


## Подпись строки: ник для онлайн-пира, короткий user_id для офлайн-записи, «(вы)» для себя,
## «★» для авторитета.
func _user_display_name(nick: String, uid: String, online: bool, is_self: bool, is_authority: bool) -> String:
	var base := ""
	if online:
		var who := nick if nick != "" else "Гость"
		base = "● %s" % who
		if uid == "":
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
	Settings.online_enabled = _online.button_pressed
	Settings.voice_enabled = _voice.button_pressed
	# Денойз применяем живьём (пересоберёт энкодер), чтобы изменение действовало сразу.
	Settings.voice_denoise = _denoise.button_pressed
	VoiceManager.set_denoise(Settings.voice_denoise)
	# Домашняя страница: пусто — без автозагрузки при запуске.
	Settings.home_page = _home.text.strip_edges()
	# Пустые поля → дефолты.
	var url := _url.text.strip_edges()
	Settings.signaling_url = url if url != "" else Settings.DEFAULT_SIGNALING_URL
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
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()
