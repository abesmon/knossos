extends Node

## Регрессия builder/scene для <VRWebStateSwitch>.


func _ready() -> void:
	var node := VrwebBuilder.build_element("VRWebStateSwitch", {
		"id": "demo-light",
	}, {}, "vrwebresource://state_switch.html")
	var ok: bool = node is VrwebStateSwitch and node.id == "demo-light" \
			and node.has_node("Button/Label") and node.has_node("Collision") \
			and node.has_node("Lamp/Light") and node.has_node("Status")
	if not ok:
		push_error("FAIL: VRWebStateSwitch собран без обязательных узлов")
		if node != null: node.free()
		get_tree().quit(1)
		return
	add_child(node)
	node.queue_free()

	var html := FileAccess.get_file_as_string("res://test_pages/state_switch.html")
	var built := VrwebBuilder.build(HtmlParser.parse(html), "vrwebresource://state_switch.html")
	var page_root: Node = built.get("root")
	var page_switch := _find_switch(page_root)
	if not bool(built.get("found", false)) or page_switch == null or page_switch.id != "demo-light":
		push_error("FAIL: state_switch.html не строит demo-light")
		if page_root != null: page_root.free()
		get_tree().quit(1)
		return
	page_root.free()
	get_tree().quit(0)


func _find_switch(node: Node) -> VrwebStateSwitch:
	if node is VrwebStateSwitch:
		return node
	if node != null:
		for child in node.get_children():
			var found := _find_switch(child)
			if found != null: return found
	return null
