class_name WorldUiSurface
extends StaticBody3D

## Общая база любого плоского UI/медиа в 3D-мире. Это аналог границы World Space Canvas +
## UIShape: Player знает только этот контракт, а конкретная поверхность решает, что делать с
## нормализованными координатами. ImagePanel и видео не обязаны заводить SubViewport;
## панели с кнопками/таблицами наследуются от WorldUiCanvas.

signal size_changed(size: Vector2)

const WORLD_UI_GROUP := "world_ui_surface"
const COLLISION_LAYER := 2

## Наши поверхности обычно читаются с обеих сторон. На изнанке X отражается, чтобы координата
## попадания соответствовала видимому (не зеркальному) содержимому второго квада.
@export var two_sided_input := true
@export var input_enabled := true

var _pointer_inside := false
var _last_pointer_uv := Vector2(0.5, 0.5)


func _ready() -> void:
	collision_layer = COLLISION_LAYER
	collision_mask = 0
	add_to_group(WORLD_UI_GROUP)


## Фактический размер интерактивной плоскости в метрах. Наследник возвращает размер своего
## квада; одна реализация преобразования координат после этого работает для всех поверхностей.
func ui_size() -> Vector2:
	return Vector2.ONE


## Локальный центр интерактивной плоскости. У большинства UI root стоит в центре, но, например,
## ImagePanel с напольным якорем держит root на полу, а квад поднимает на уровень глаз.
func ui_center_local() -> Vector3:
	return Vector3.ZERO


## Наследники сообщают об уточнённом размере через общий hook, чтобы контракт сигнала оставался
## сосредоточен в базовой поверхности.
func notify_size_changed(new_size: Vector2) -> void:
	size_changed.emit(new_size)


## Мировая точка физического луча -> UV интерфейса: (0,0) сверху слева, (1,1) снизу справа.
func world_to_ui_uv(point: Vector3) -> Vector2:
	if not is_inside_tree():
		return Vector2(-1.0, -1.0)
	var size := ui_size()
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector2(-1.0, -1.0)
	var local := to_local(point) - ui_center_local()
	var u := clampf((local.x + size.x * 0.5) / size.x, 0.0, 1.0)
	var v := clampf((size.y * 0.5 - local.y) / size.y, 0.0, 1.0)
	if two_sided_input and local.z < 0.0:
		u = 1.0 - u
	return Vector2(u, v)


## Контракт Player. Эти методы финализируют общую маршрутизацию и вызывают узкие hooks.
func pointer_enter() -> void:
	if not is_inside_tree() or not input_enabled or _pointer_inside:
		return
	_pointer_inside = true
	_on_ui_pointer_enter()


func hover_at(point: Vector3) -> void:
	if not is_inside_tree() or not input_enabled:
		return
	if not _pointer_inside:
		pointer_enter()
	_last_pointer_uv = world_to_ui_uv(point)
	_on_ui_pointer_move(_last_pointer_uv)


func pointer_exit() -> void:
	if not _pointer_inside:
		return
	_pointer_inside = false
	if not is_inside_tree():
		return
	_on_ui_pointer_exit()


func interact_at(point: Vector3) -> void:
	if not is_inside_tree() or not input_enabled:
		return
	_last_pointer_uv = world_to_ui_uv(point)
	_on_ui_accept(_last_pointer_uv)


func scroll_by(direction: float) -> void:
	if is_inside_tree() and input_enabled:
		_on_ui_scroll(direction)


func is_active_at(point: Vector3) -> bool:
	return is_inside_tree() and input_enabled and _ui_is_active(world_to_ui_uv(point))


func aim_hint_at(point: Vector3) -> String:
	return _ui_hint(world_to_ui_uv(point)) if is_inside_tree() and input_enabled else ""


## Hooks: наследники переопределяют только нужное поведение, не весь контракт с Player.
func _on_ui_pointer_enter() -> void:
	pass


func _on_ui_pointer_move(_uv: Vector2) -> void:
	pass


func _on_ui_pointer_exit() -> void:
	pass


func _on_ui_accept(_uv: Vector2) -> void:
	pass


func _on_ui_scroll(_direction: float) -> void:
	pass


func _ui_is_active(_uv: Vector2) -> bool:
	return false


func _ui_hint(_uv: Vector2) -> String:
	return ""
