extends Control

## Overlay-экран настроек. main инстансит его поверх UI (скрытым) и показывает по кнопке
## «⚙». Редактирует значения автолоада Settings; по «Сохранить» пишет их и закрывается.
## Сам мир не трогает — поэтому навигация/состояние не теряются.

signal closed

@onready var _online: CheckButton = $Panel/Margin/VBox/Online
@onready var _url: LineEdit = $Panel/Margin/VBox/Url
@onready var _nick: LineEdit = $Panel/Margin/VBox/Nick
@onready var _save: Button = $Panel/Margin/VBox/Buttons/Save
@onready var _cancel: Button = $Panel/Margin/VBox/Buttons/Cancel


func _ready() -> void:
	hide()
	_save.pressed.connect(_on_save)
	_cancel.pressed.connect(_close)


## Показать экран, заполнив поля текущими значениями.
func open() -> void:
	_online.button_pressed = Settings.online_enabled
	_url.text = Settings.signaling_url
	_nick.text = Settings.nick
	show()
	_nick.grab_focus()


func _on_save() -> void:
	Settings.online_enabled = _online.button_pressed
	Settings.signaling_url = _url.text.strip_edges()
	var nick := _nick.text.strip_edges()
	if nick != "":
		Settings.nick = nick
	Settings.save()
	_close()


func _close() -> void:
	hide()
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()
