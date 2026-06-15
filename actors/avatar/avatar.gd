class_name Avatar
extends Node3D

## Корень аватара — ПРОСТО хранилище состояния + распределитель. Никакой логики анимации он
## не содержит: получает шину параметров (AvatarParameters) и раздаёт её «аппликаторам» —
## дочерним узлам, которые на сигнал/в _process читают состояние и что-то делают (гонят
## значения в AnimationTree, крутят кость, наклоняют квад…). Так аватар можно собрать вообще
## без кастомного кода: модель + AnimationTree + готовый AvatarAnimationTreeApplier, у
## которого в инспекторе прописана таблица «параметр → путь в дереве». Это модель VRChat:
## состояние просто копируется в аниматор, а вся анимация живёт в дереве блендов.
##
## Аппликатор — любой узел с методом bind_params(params). «Утиный» интерфейс: корень не знает
## их классов, просто раздаёт шину. Кастомный скрипт-аппликатор по-прежнему возможен (для
## не-скелетных трюков), но это лишь один из путей, а не единственный. См. docs/avatars.md.

## Высота над корнем (м), на которой хост ставит неймплейт/бабл (у разных аватаров разный рост).
@export var nameplate_height := 2.1

var _params: AvatarParameters


## Привязать аватар к шине: раздать её всем дочерним аппликаторам.
func bind(params: AvatarParameters) -> void:
	_params = params
	for node in _appliers():
		node.bind_params(params)


## Текущая шина (аппликатор может взять её и читать любые параметры напрямую).
func get_params() -> AvatarParameters:
	return _params


## Ник + лицо игрока — раздаём аппликаторам, умеющим apply_identity (например, накладке лица).
func apply_identity(nick: String, face: Texture2D) -> void:
	for node in find_children("*", "", true, false):
		if node.has_method("apply_identity"):
			node.apply_identity(nick, face)


## Все дочерние узлы-аппликаторы (есть метод bind_params).
func _appliers() -> Array:
	var out: Array = []
	for node in find_children("*", "", true, false):
		if node.has_method("bind_params"):
			out.append(node)
	return out
