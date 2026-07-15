extends Node

## Регрессия: кастомный <VRWebVideoScreen> должен строиться из составной сцены, а не
## голого скрипта без Mesh/Collision/PlaybackUI.
## Запуск: HOME=/tmp/knossos-godot godot --headless --path . res://tests/test_video_screen.tscn


func _ready() -> void:
	var node := VrwebBuilder.build_element("VRWebVideoScreen", {
		"player": "main", "size": "3.2:1.8",
	}, {}, "vrwebresource://video.html")
	var ok := node is VrwebVideoScreen \
			and node.has_node("Mesh") \
			and node.has_node("Collision") \
			and node.has_node("Placeholder") \
			and node.has_node("PlaybackUI/Track")
	if not ok:
		push_error("FAIL: VRWebVideoScreen собран без обязательных дочерних узлов")
		if node != null:
			node.free()
		get_tree().quit(1)
		return
	add_child(node) # запускает @onready и _ready — тот самый путь падения из main.gd
	node.queue_free()

	# HtmlLayer toggle: синтетический src-player не должен продолжать жить/играть после того,
	# как единственный HTML-экран снят и manager пересканировал оставшийся мир.
	var root := Node.new()
	add_child(root)
	var manager := VrwebVideoManager.new()
	root.add_child(manager)
	var src_screen = VrwebBuilder.build_element("VRWebVideoScreen", {
		"src": "https://example.test/video.mp4",
	}, {}, "vrwebresource://video.html")
	root.add_child(src_screen)
	manager.scan(root)
	var had_synthetic := manager.get_child_count() > 0
	root.remove_child(src_screen)
	src_screen.queue_free()
	manager.rescan(root)
	var removed_synthetic := manager.get_child_count() == 0
	if not had_synthetic or not removed_synthetic:
		push_error("FAIL: rescan не снял синтетический video player удалённого HtmlLayer")
		root.queue_free()
		get_tree().quit(1)
		return
	root.queue_free()
	get_tree().quit(0)
