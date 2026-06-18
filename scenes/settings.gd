extends Control

## Overlay-экран настроек. main инстансит его поверх UI (скрытым) и показывает по кнопке
## «⚙». Редактирует значения автолоада Settings; по «Сохранить» пишет их и закрывается.
## Сам мир не трогает — поэтому навигация/состояние не теряются.

signal closed

@onready var _online: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Online
@onready var _voice: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Voice
@onready var _device: OptionButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/MicRow/Device
@onready var _device_refresh: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/MicRow/Refresh
@onready var _test: Button = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/TestRow/Test
@onready var _monitor: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/TestRow/Monitor
@onready var _level: ProgressBar = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Level
@onready var _url: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UrlRow/Url
@onready var _url_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/UrlRow/Clear
@onready var _nick: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/NickRow/Nick
@onready var _nick_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/NickRow/Clear
@onready var _face_preview: TextureRect = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/FaceRow/Preview
@onready var _face_pick: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/FaceRow/Pick
@onready var _face_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/FaceRow/Clear
@onready var _avatar: LineEdit = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/AvatarRow/Avatar
@onready var _avatar_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/AvatarRow/Clear
@onready var _face_dialog: FileDialog = $FaceDialog
@onready var _save: Button = $Panel/Margin/VBoxContainer/Buttons/Save
@onready var _cancel: Button = $Panel/Margin/VBoxContainer/Buttons/Cancel


func _ready() -> void:
	hide()
	_save.pressed.connect(_on_save)
	_cancel.pressed.connect(_close)
	_face_pick.pressed.connect(_face_dialog.popup_centered_ratio)
	_face_dialog.file_selected.connect(_on_face_selected)
	# Очистка полей: пустые на сохранении превратятся в дефолты (placeholder подсказывает).
	_url_clear.pressed.connect(_url.clear)
	_nick_clear.pressed.connect(_nick.clear)
	_face_clear.pressed.connect(_on_face_clear)
	_avatar_clear.pressed.connect(_avatar.clear)
	# Микрофон: выбор устройства применяем сразу (живьём), чтобы проверка шла на нём.
	_device.item_selected.connect(_on_device_selected)
	_device_refresh.pressed.connect(_populate_devices)
	_test.toggled.connect(_on_test_toggled)
	_monitor.toggled.connect(_on_monitor_toggled)


## Показать экран, заполнив поля текущими значениями.
func open() -> void:
	_online.button_pressed = Settings.online_enabled
	_voice.button_pressed = Settings.voice_enabled
	_url.text = Settings.signaling_url
	_nick.text = Settings.nick
	_avatar.text = Settings.avatar_uri
	_face_preview.texture = Settings.face_texture()
	_populate_devices()
	_test.button_pressed = false
	_monitor.button_pressed = false
	_level.value = 0.0
	show()
	_nick.grab_focus()


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


func _on_device_selected(idx: int) -> void:
	Settings.input_device = _device.get_item_text(idx)
	VoiceManager.apply_input_device(Settings.input_device)


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


func _on_save() -> void:
	Settings.online_enabled = _online.button_pressed
	Settings.voice_enabled = _voice.button_pressed
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


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()
