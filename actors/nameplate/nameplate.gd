class_name Nameplate
extends Node3D

## «View-bubble» над головой пира: крупно — отображаемое имя (display_name), а под ним, при
## наличии, криптографически подтверждённая идентичность (nick@domain) с иконкой статуса.
## Рендерится как речевой бабл — UI-плашка через SubViewport на billboard-Sprite3D, — но
## обновляется лениво: один кадр (UPDATE_ONCE) на каждое изменение содержимого, а не каждый
## кадр. Иконки статуса общие с 2D-UI (StatusIcons). См. docs/home-server.md.

@onready var _viewport: SubViewport = $Viewport
@onready var _root: PanelContainer = $Viewport/Root
@onready var _name_label: Label = $Viewport/Root/Margin/VBox/Name
@onready var _identity: HBoxContainer = $Viewport/Root/Margin/VBox/Identity
@onready var _icon: TextureRect = $Viewport/Root/Margin/VBox/Identity/Icon
@onready var _address: Label = $Viewport/Root/Margin/VBox/Identity/Address
@onready var _sprite: Sprite3D = $Sprite

## Масштаб бабла в мире: 1px вьюпорта = PIXEL_SIZE метра.
const PIXEL_SIZE := 0.0022

var _display_name := "Guest"
var _address_text := ""
var _status := StatusIcons.Status.NONE
var _name_color := Color.WHITE
var _ready_done := false
# Пересчёт размера вьюпорта откладываем на кадр: минимальный размер контейнеров пересчитывается
# отложенно, поэтому сразу после смены текста он ещё стар (см. _process).
var _dirty := false


func _ready() -> void:
	_sprite.texture = _viewport.get_texture()
	_sprite.pixel_size = PIXEL_SIZE
	_ready_done = true
	set_process(false)
	_refresh()


## Отображаемое имя (display_name — то, что пир заявил о себе). Можно звать до входа в дерево.
func set_display_name(value: String) -> void:
	_display_name = value
	if _ready_done:
		_refresh()


## Подтверждённая идентичность со статусом: address == "" — второй строки нет (аноним/не проверен).
func set_verified_identity(address: String, status: StatusIcons.Status) -> void:
	_address_text = address
	_status = status
	if _ready_done:
		_refresh()


## Подсветка имени (напр. пир говорит — зелёным).
func set_name_color(color: Color) -> void:
	_name_color = color
	if _ready_done:
		_refresh()


func _refresh() -> void:
	_name_label.text = _display_name
	_name_label.add_theme_color_override("font_color", _name_color)
	var has_identity := _address_text.strip_edges() != ""
	_identity.visible = has_identity
	if has_identity:
		_address.text = _address_text
		var tex := StatusIcons.texture(_status)
		_icon.visible = tex != null
		_icon.texture = tex
		_icon.self_modulate = StatusIcons.color(_status)
	# Минимальный размер плашки станет актуальным на следующем кадре — тогда и подгоняем вьюпорт.
	_dirty = true
	set_process(true)


func _process(_delta: float) -> void:
	if not _dirty:
		set_process(false)
		return
	_dirty = false
	var sz := _root.get_combined_minimum_size()
	_viewport.size = Vector2i(maxi(1, ceili(sz.x)), maxi(1, ceili(sz.y)))
	_root.size = sz
	# Один кадр рендера: содержимое статично, гонять вьюпорт постоянно незачем.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	set_process(false)
