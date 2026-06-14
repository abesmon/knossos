extends Node

## Глобальные настройки приложения (autoload «Settings»).
## Хранит онлайн-режим, адрес сигнального сервера и ник; персистит в user://settings.cfg.
## Экран настроек (scenes/settings) редактирует эти значения и зовёт save();
## NetworkManager и main слушают сигнал changed.

signal changed

const PATH := "user://settings.cfg"

var online_enabled: bool = false
var signaling_url: String = "ws://localhost:8080"
var nick: String = ""


func _ready() -> void:
	load_settings()
	if nick.strip_edges() == "":
		nick = "Guest-%04d" % (randi() % 10000)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	online_enabled = cfg.get_value("net", "online_enabled", online_enabled)
	signaling_url = cfg.get_value("net", "signaling_url", signaling_url)
	nick = cfg.get_value("net", "nick", nick)


## Сохраняет текущие значения на диск и оповещает подписчиков.
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "online_enabled", online_enabled)
	cfg.set_value("net", "signaling_url", signaling_url)
	cfg.set_value("net", "nick", nick)
	cfg.save(PATH)
	changed.emit()
