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
	get_tree().quit(0)
