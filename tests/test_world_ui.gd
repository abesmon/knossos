extends Node

## Проверяет общий контракт world-space UI.
## Запуск: godot --headless --path . res://tests/test_world_ui.tscn

const CANVAS_SCENE := preload("res://actors/world_ui/world_ui_canvas.tscn")
const IMAGE_PANEL_SCENE := preload("res://actors/image_panel/image_panel.tscn")
const RICH_PANEL_SCENE := preload("res://actors/rich_panel/rich_panel.tscn")
const VIDEO_SCREEN_SCENE := preload("res://scenes/vrweb_video_screen.tscn")

var _failed := false


func _ready() -> void:
	var surface := WorldUiSurface.new()
	add_child(surface)
	await get_tree().process_frame
	_check(surface.collision_layer == WorldUiSurface.COLLISION_LAYER,
			"WorldUiSurface задаёт единый collision layer")
	_check(surface.collision_mask == 0,
			"WorldUiSurface не блокирует физику игрока")
	surface.free()

	var canvas := CANVAS_SCENE.instantiate() as WorldUiCanvas
	add_child(canvas)
	await get_tree().process_frame
	canvas.configure_canvas_geometry(Vector2(2.0, 1.0))
	_check(canvas.ui_size().is_equal_approx(Vector2(2.0, 1.0)),
			"WorldUiCanvas хранит размер surface в метрах")
	var box := canvas.get_node("CollisionShape3D").shape as BoxShape3D
	_check(box != null and box.size.is_equal_approx(Vector3(2.0, 1.0, 0.08)),
			"WorldUiCanvas обновляет box collider вместе с mesh")
	_check(canvas.world_to_ui_uv(Vector3(-1.0, 0.0, 0.02)).is_equal_approx(Vector2(0.0, 0.5)),
			"front-hit мапится в UV слева направо")
	_check(canvas.world_to_ui_uv(Vector3(1.0, 0.0, -0.02)).is_equal_approx(Vector2(0.0, 0.5)),
			"back-hit отражает U и попадает в тот же видимый элемент")
	canvas.hover_at(Vector3.ZERO)
	_check(canvas._pointer_inside, "hover_at открывает pointer state")
	canvas.pointer_exit()
	_check(not canvas._pointer_inside, "pointer_exit закрывает pointer state")
	remove_child(canvas)
	canvas.hover_at(Vector3.ZERO)
	canvas.interact_at(Vector3.ZERO)
	_check(canvas.world_to_ui_uv(Vector3.ZERO) == Vector2(-1.0, -1.0) \
			and not canvas.is_active_at(Vector3.ZERO) and not canvas._pointer_inside,
			"снятая при навигации UI-поверхность больше не принимает stale ray input")
	canvas.free()

	var image_node := IMAGE_PANEL_SCENE.instantiate()
	var rich := RICH_PANEL_SCENE.instantiate()
	var video := VIDEO_SCREEN_SCENE.instantiate()
	_check(image_node is WorldUiSurface and not image_node is WorldUiCanvas,
			"ImagePanel наследуется от лёгкой WorldUiSurface")
	_check(rich is WorldUiCanvas,
			"RichPanel наследуется от WorldUiCanvas")
	_check(video is WorldUiSurface and not video is WorldUiCanvas,
			"VrwebVideoScreen наследуется от лёгкой WorldUiSurface")
	var image := image_node as ImagePanel
	image.setup("floor image", null, 1.0, 1.0)
	add_child(image)
	await get_tree().process_frame
	var image_center := (image.get_node("Front") as MeshInstance3D).position
	_check(image.world_to_ui_uv(image.to_global(image_center + Vector3(-0.5, 0.0, 0.02)))
			.is_equal_approx(Vector2(0.0, 0.5)),
			"ImagePanel floor anchor использует центр квада, а не root на полу")
	image.free()
	rich.free()
	video.free()

	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [ok]  ", label)
	else:
		_failed = true
		printerr("  [FAIL] ", label)
