extends Control

## Overlay-экран настроек. main инстансит его поверх UI (скрытым) и показывает по кнопке
## «⚙». Редактирует значения автолоада Settings; по «Сохранить» пишет их и закрывается.
## Сам мир не трогает — поэтому навигация/состояние не теряются.

signal closed

## Верх диапазона ползунка порога активации (RMS) — для перевода значения в проценты в подписи.
const THRESH_MAX := 0.15

@onready var _online: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/NetSettings/Online
@onready var _voice: CheckButton = $Panel/Margin/VBoxContainer/TabContainer/SoundSettings/Voice
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
@onready var _cache_size: Label = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/CacheRow/Size
@onready var _cache_clear: Button = $Panel/Margin/VBoxContainer/TabContainer/MiscSettings/CacheRow/Clear
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
	# Вывод и громкости применяем сразу (живьём), чтобы изменения было слышно до сохранения.
	_out_device.item_selected.connect(_on_out_device_selected)
	_out_refresh.pressed.connect(_populate_out_devices)
	for bus_name in _vol_sliders:
		_vol_sliders[bus_name].value_changed.connect(_on_volume_changed.bind(bus_name))
	# Усиление и порог активации микрофона — применяем живьём (слышно/видно при проверке).
	_gain_slider.value_changed.connect(_on_gain_changed)
	_thresh_slider.value_changed.connect(_on_thresh_changed)
	_cache_clear.pressed.connect(_on_cache_clear)


## Показать экран, заполнив поля текущими значениями.
func open() -> void:
	_online.button_pressed = Settings.online_enabled
	_voice.button_pressed = Settings.voice_enabled
	_url.text = Settings.signaling_url
	_nick.text = Settings.nick
	_avatar.text = Settings.avatar_uri
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
	show()
	_nick.grab_focus()


## Обновляет подпись с текущим размером дискового кэша (аватары + видео).
func _update_cache_size() -> void:
	_cache_size.text = "Размер кэша: %s" % Cache.format_size(Cache.total_size())


## «Очистить кэш» — удаляет скачанные аватары и видео, обновляет подпись с размером.
func _on_cache_clear() -> void:
	Cache.clear()
	_update_cache_size()


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
