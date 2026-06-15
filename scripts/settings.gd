extends Node

## Глобальные настройки приложения (autoload «Settings»).
## Хранит онлайн-режим, адрес сигнального сервера, ник и текстуру «лица»; персистит в
## user://. Экран настроек (scenes/settings) редактирует значения и зовёт save();
## NetworkManager и main слушают сигнал changed.

signal changed

const PATH := "user://settings.cfg"
const DEFAULT_SIGNALING_URL := "https://signaling.vrweb.home.syrupmg.ru"
## Лицо аватара. Всегда храним в user:// как 256×256 PNG (с альфой) — это и отдаётся по
## сети другим игрокам. При первом запуске копируем сюда дефолт.
const FACE_PATH := "user://face.png"
const DEFAULT_FACE := "res://resources/default_face.png"
const FACE_SIZE := 256
## Идентификатор аватара по умолчанию — первый из бандл-пака. Передаётся другим игрокам в
## карточке идентичности; они резолвят его через AvatarResolver. Схемы: vrwebavatar://N
## (пак приложения) или http(s)://…tscn (внешний). См. actors/avatar/avatar_resolver.gd.
const DEFAULT_AVATAR_URI := "vrwebavatar://1"

var online_enabled: bool = false
var signaling_url: String = DEFAULT_SIGNALING_URL
var nick: String = ""
var avatar_uri: String = DEFAULT_AVATAR_URI


func _ready() -> void:
	load_settings()
	if nick.strip_edges() == "":
		nick = random_nick()
	_ensure_face()


## Случайный ник по умолчанию (когда поле ника очищено).
func random_nick() -> String:
	return "Guest-%04d" % (randi() % 10000)


## Гарантирует, что user://face.png существует — при первом запуске кладёт дефолт.
func _ensure_face() -> void:
	if FileAccess.file_exists(FACE_PATH):
		return
	reset_face()


## Сбрасывает лицо к дефолту (resources/default_face.png), перезаписывая user://face.png.
func reset_face() -> void:
	var tex := load(DEFAULT_FACE) as Texture2D
	if tex != null:
		tex.get_image().save_png(FACE_PATH)


## PNG-байты текущего лица (256×256, с альфой) — то, что уходит другим игрокам по сети.
func face_png() -> PackedByteArray:
	if FileAccess.file_exists(FACE_PATH):
		return FileAccess.get_file_as_bytes(FACE_PATH)
	return PackedByteArray()


## Текстура текущего лица для превью в настройках.
func face_texture() -> Texture2D:
	var img := Image.new()
	if FileAccess.file_exists(FACE_PATH) and img.load(FACE_PATH) == OK:
		return ImageTexture.create_from_image(img)
	return load(DEFAULT_FACE) as Texture2D


## Загружает выбранный пользователем файл как лицо: ресайз до 256×256 (сохраняя альфу)
## и запись в user://face.png. Возвращает успех.
func set_face_from_file(path: String) -> bool:
	var img := Image.new()
	if img.load(path) != OK:
		return false
	img.convert(Image.FORMAT_RGBA8)   # гарантируем канал альфы (прозрачность)
	img.resize(FACE_SIZE, FACE_SIZE, Image.INTERPOLATE_LANCZOS)
	return img.save_png(FACE_PATH) == OK


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	online_enabled = cfg.get_value("net", "online_enabled", online_enabled)
	signaling_url = cfg.get_value("net", "signaling_url", signaling_url)
	nick = cfg.get_value("net", "nick", nick)
	avatar_uri = cfg.get_value("avatar", "uri", avatar_uri)
	if avatar_uri.strip_edges() == "":
		avatar_uri = DEFAULT_AVATAR_URI


## Сохраняет текущие значения на диск и оповещает подписчиков.
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "online_enabled", online_enabled)
	cfg.set_value("net", "signaling_url", signaling_url)
	cfg.set_value("net", "nick", nick)
	cfg.set_value("avatar", "uri", avatar_uri)
	cfg.save(PATH)
	changed.emit()
