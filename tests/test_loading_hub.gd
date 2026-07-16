extends Node3D

const HUB_SCENE := preload("res://scenes/ui/loading_hub.tscn")


func _ready() -> void:
	var world_camera := Camera3D.new()
	world_camera.name = "WorldCamera"
	add_child(world_camera)
	world_camera.make_current()

	var hub: LoadingHub = HUB_SCENE.instantiate()
	var hub_camera: Camera3D = hub.get_node("CameraRig/Camera3D")
	hub.visible = false
	add_child(hub)
	await get_tree().process_frame
	_check(not hub_camera.is_inside_tree() and get_viewport().get_camera_3d() == world_camera,
		"скрытый хаб не перехватывает current-камеру")

	hub.open("Тестовая загрузка")
	await get_tree().process_frame
	_check(hub_camera.is_inside_tree() and hub_camera.current
			and get_viewport().get_camera_3d() == hub_camera,
		"open переключает viewport на камеру хаба")
	_check(hub.get_node("Shell") is MeshInstance3D, "хаб окружён 3D-сферой")
	_check(hub.get_node("ContentAnchor/Status") is Label3D,
		"статус находится на пространственном ContentAnchor")
	_check((hub_camera.cull_mask & (1 << (LocalAvatar.AVATAR_LAYER - 1))) == 0,
		"камера хаба не рендерит тело локального игрока")

	world_camera.make_current()
	hub.open("Повторная загрузка")
	await get_tree().process_frame
	_check(hub_camera.current and get_viewport().get_camera_3d() == hub_camera,
		"open возвращает камеру хаба, даже если видимый хаб перехватил мир")

	hub.close()
	await get_tree().process_frame
	_check(not hub_camera.is_inside_tree() and world_camera.current
			and get_viewport().get_camera_3d() == world_camera,
		"close возвращает камеру пространства")
	print("LOADING HUB TEST: PASSED")
	get_tree().quit()


func _check(ok: bool, message: String) -> void:
	if not ok:
		push_error("FAIL: %s" % message)
		get_tree().quit(1)
