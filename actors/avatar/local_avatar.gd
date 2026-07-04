class_name LocalAvatar
extends AvatarHost

## Видимое тело локального игрока — чтобы он видел себя в зеркале (как в VRChat).
## Это тот самый «будущий локальный mirror», про который написано в AvatarHost и
## AvatarParameterSource: хост аватара, который делит шину параметров с продюсером игрока
## (AvatarParameterSource), поэтому тело анимируется вживую без сетевого роундтрипа.
##
## Тело висит на отдельном слое видимости AVATAR_LAYER: камера первого лица его НЕ рендерит
## (иначе своё тело загораживало бы обзор), а камеры зеркал — рендерят. Так игрок видит себя
## только в отражении, как в VRChat.
##
## Личность (ник/лицо) и сам аватар берутся из Settings (как и то, что уходит другим игрокам),
## так что в зеркале — твой ник, твоё лицо и твоя модель. Следит за Settings.changed.

## Слой видимости тела игрока (1..20). Камера игрока его исключает (см. Player), камеры
## зеркал — включают (VrwebMirror не трогает этот слой). Отдельный от слоя зеркал (20).
const AVATAR_LAYER := 11  # бит (AVATAR_LAYER-1)

var _source: AvatarParameterSource
var _resolver: AvatarResolver
# Какой avatar_uri уже смонтирован — чтобы сохранение настроек без смены модели не
# перемонтировало аватар зря (то самое «моргание» зеркала). Ровно как _avatar_applied в
# RemotePlayersView для чужих капсул.
var _applied_uri := ""


## Задаёт продюсера параметров игрока. Зовётся ДО add_child (до _ready), чтобы _ready успел
## поделить с ним шину параметров.
func setup(source: AvatarParameterSource) -> void:
	_source = source


func _ready() -> void:
	# Делим шину параметров с продюсером: аватар подписывается на ту же AvatarParameters,
	# куда игрок пишет каждый физкадр, — анимация вживую без копирования снапшотов.
	if _source != null:
		params = _source.params

	_resolver = AvatarResolver.new()
	add_child(_resolver)

	# Личность запоминаем до резолва: _mount навесит её на смонтированную модель сам.
	_apply_local_identity()
	# Резолвим аватар из настроек ДО super._ready(). Бандл-аватар резолвится синхронно и
	# монтируется прямо здесь, поэтому авто-монтирование хоста (super._ready, mount только
	# при _avatar == null) уже ничего не делает. Иначе хост сперва смонтировал бы дефолтный
	# avatar_scene, а резолв тут же заменил бы его другой моделью В ТОТ ЖЕ КАДР: материалы
	# выброшенного инстанса (включая уникальную копию от UserTextureApplier) освобождаются
	# до первого рендера, и отложенный апдейт рендера видит null — «Parameter "material" is
	# null». Для внешних (http) аватаров резолв асинхронный: _avatar остаётся null, super
	# смонтирует дефолт как заглушку, а пришедшая модель заменит его уже в другом кадре.
	_resolve_from_settings()
	super._ready()
	_relayer()

	if not Settings.changed.is_connected(_on_settings_changed):
		Settings.changed.connect(_on_settings_changed)


## Смена аватара (наследуется от AvatarHost) + перенос нового тела на слой зеркал.
func set_avatar(scene: PackedScene) -> void:
	super.set_avatar(scene)
	_relayer()


func _on_settings_changed() -> void:
	_apply_local_identity()
	_resolve_from_settings()


func _apply_local_identity() -> void:
	apply_identity(Settings.nick, Settings.face_texture())


## Резолвит аватар из Settings.avatar_uri (как у других игроков) и монтирует его. Для внешних
## URL колбэк приходит асинхронно — тогда же переносим тело на слой зеркал (через set_avatar).
## Модель не сменилась (тот же uri уже смонтирован) — не перемонтируем: иначе каждое сохранение
## настроек «моргало» бы зеркалом. Лицо/ник обновляются отдельно через _apply_local_identity.
func _resolve_from_settings() -> void:
	var uri := Settings.avatar_uri
	if uri == _applied_uri:
		return
	_resolver.resolve(uri, func(scene: PackedScene) -> void:
		if scene != null:
			set_avatar(scene)
			_applied_uri = uri
	)


## Переносит все визуалы смонтированного аватара на слой AVATAR_LAYER, чтобы их рисовали
## только камеры зеркал, но не камера первого лица.
func _relayer() -> void:
	if _avatar != null:
		_set_layers_recursive(_avatar, 1 << (AVATAR_LAYER - 1))


func _set_layers_recursive(node: Node, layers_mask: int) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layers_mask
	for child in node.get_children():
		_set_layers_recursive(child, layers_mask)
