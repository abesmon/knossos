@tool
class_name UserSettingsAvatarTexture
extends Texture2D
# @tool: иначе в редакторе методы скрипта не исполняются и движок считает виртуали Texture2D
# (_get_width/_get_height…) непереопределёнными — сыплет ошибки при генерации превью.

## Маркер-плейсхолдер пользовательской текстуры. Кладётся в ЛЮБОЙ текстурный слот ЛЮБОГО
## материала аватара (albedo, emission…), в любом месте дерева. Когда аватар получит текстуру
## игрока (identity), UserTextureApplier найдёт все слоты с этим маркером во всех мешах и
## подменит их на неё — так одно «лицо игрока» автоматически попадает во все нужные места
## (лицо, бейдж, баннер…), и аватару не нужно знать, где именно они расположены.
##
## До прихода identity маркер рисует default_texture (дефолтное лицо), чтобы капсула не была
## пустой. Сам маркер делегирует всё рисование default_texture — для рендера это обычная
## текстура.

@export var default_texture: Texture2D:
	set(value):
		default_texture = value
		emit_changed()


func _get_width() -> int:
	return default_texture.get_width() if default_texture != null else 1


func _get_height() -> int:
	return default_texture.get_height() if default_texture != null else 1


func _has_alpha() -> bool:
	return default_texture.has_alpha() if default_texture != null else true


func _get_rid() -> RID:
	return default_texture.get_rid() if default_texture != null else RID()


func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, transpose: bool) -> void:
	if default_texture != null:
		default_texture.draw(to_canvas_item, pos, modulate, transpose)


func _draw_rect(to_canvas_item: RID, rect: Rect2, tile: bool, modulate: Color, transpose: bool) -> void:
	if default_texture != null:
		default_texture.draw_rect(to_canvas_item, rect, tile, modulate, transpose)


func _draw_rect_region(to_canvas_item: RID, rect: Rect2, src_rect: Rect2, modulate: Color, transpose: bool, clip_uv: bool) -> void:
	if default_texture != null:
		default_texture.draw_rect_region(to_canvas_item, rect, src_rect, modulate, transpose, clip_uv)
