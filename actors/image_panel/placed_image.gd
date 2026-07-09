class_name PlacedImage
extends ImagePanel

## Картинка, размещённая в МИРЕ (тег <VRWebImage> / инструмент размещения, клавиша 3).
## В отличие от панели страницы (WorldGenerator ставит её на пол, центр — на уровне глаз),
## якорится ЦЕНТРОМ в своей точке: position узла = центр квада. Текстуру грузит сама через
## ImageLoader текущего мира (группа ImageLoader.GROUP); src может быть realtime-ресурсом
## (vrwebblob://, см. docs/network/realtime-resources.md) или обычным URL.

## Кап ширины по умолчанию, м — размещённая руками картинка без явного width не должна
## заслонять комнату (у панелей страницы ту же роль играет ширина стены). Явный width
## тега уважается как есть.
const PLACED_MAX_WIDTH := 3.0

var src := "":
	set(value):
		if src == value:
			return
		src = value
		if is_inside_tree():
			_request()   # update эфемерного объекта сменил картинку — перезагружаем


func _ready() -> void:
	super()
	# Кап по умолчанию — только когда автор не задал размер сам (want_w из setup).
	if _max_w <= 0.0 and _want_w <= 0.0:
		_max_w = PLACED_MAX_WIDTH
	_request()


func _request() -> void:
	if src == "":
		return
	var loader := get_tree().get_first_node_in_group(ImageLoader.GROUP) as ImageLoader
	if loader != null:
		request_load(src, loader)


## Якорь центром (переопределение): центр квада в origin узла, а не пол+уровень глаз.
func _update_layout() -> void:
	_height_m = _quad.size.y
	_mesh.position = Vector3.ZERO
	_mesh_back.position = Vector3.ZERO
	_shape.size = Vector3(_quad.size.x, _height_m, 0.08)
	_collision.position = Vector3.ZERO
	_label.position = Vector3(0, 0, 0.06)
