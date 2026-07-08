class_name AvatarHost
extends Node3D

## Крепление аватара: владеет шиной параметров и смонтированным аватаром, кормит аватар
## значениями. Источник значений — любой (сеть, локальный продюсер, запись): хост лишь
## прокидывает их в шину, а аватар сам анимируется. Это узел, который делает аватар
## заменяемым независимо от того, кто его «носит» (RemotePlayer, будущий локальный mirror).

## Сцена аватара по умолчанию (первый из бандл-пака res://avatars/). Корень сцены — Avatar.
@export var avatar_scene: PackedScene = preload("res://avatars/avatar_1.tscn")

var params := AvatarParameters.new()

var _avatar: Avatar
var _nick := ""
var _face: Texture2D


func _ready() -> void:
	if _avatar == null and avatar_scene != null:
		_mount(avatar_scene.instantiate())


## Сменить аватар во время жизни (например, выбрать другую модель). Новый аватар сразу
## получает текущие параметры и идентичность.
func set_avatar(scene: PackedScene) -> void:
	if scene == null:
		return
	avatar_scene = scene
	_mount(scene.instantiate())


func _mount(node: Node) -> void:
	var avatar := node as Avatar
	if avatar == null:
		Log.err("avatar", "корень сцены аватара не наследует Avatar")
		node.queue_free()
		return
	if _avatar != null:
		_avatar.queue_free()
	_avatar = avatar
	add_child(avatar)
	avatar.bind(params)
	if _nick != "" or _face != null:
		avatar.apply_identity(_nick, _face)


## Записать один параметр в шину (аватар отреагирует через _apply).
func set_param(pname: StringName, value: Variant) -> void:
	params.set_value(pname, value)


## Применить пачку параметров (например, пришедшую по сети).
func apply_params(values: Dictionary) -> void:
	params.apply(values)


## Передать аватару ник и лицо. Запоминаем, чтобы заново навесить при смене аватара.
## Имя не set_identity — оно занято нативным Node3D.set_identity (сброс трансформа).
func apply_identity(nick: String, face: Texture2D) -> void:
	_nick = nick
	if face != null:
		_face = face
	if _avatar != null:
		_avatar.apply_identity(_nick, _face)


## Высота для неймплейта/бабла — у текущего аватара (разный рост).
func current_nameplate_height() -> float:
	return _avatar.nameplate_height if _avatar != null else 2.1
