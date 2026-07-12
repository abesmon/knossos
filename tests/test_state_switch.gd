extends Node

## Регрессия self-contained страницы с раздельными state, action и представлением.


func _ready() -> void:
	var html := FileAccess.get_file_as_string("res://test_pages/state_switch.html")
	var built := VrwebBuilder.build(HtmlParser.parse(html), "vrwebresource://state_switch.html")
	var page_root: Node = built.get("root")
	var page_switch := _find_switch(page_root)
	var ok := bool(built.get("found", false)) and page_switch != null \
			and page_switch.object_id == "demo-light" and page_switch.schema_id == "demo.light-switch" \
			and page_switch.get_node_or_null("../Button") is VrwebStateAction \
			and page_switch.has_node("../Button/Collision") \
			and page_switch.has_node("../RedLamp") and page_switch.has_node("../GreenLamp") \
			and page_switch.field_specs.has("enabled") and page_switch.command_specs.has("toggle") \
			and page_switch.bindings.size() == 4
	if not ok:
		push_error("FAIL: state_switch.html не является автономным replicated-компонентом")
		if page_root != null: page_root.free()
		get_tree().quit(1)
		return
	page_root.free()
	get_tree().quit(0)


func _find_switch(node: Node) -> VrwebReplicatedState:
	if node is VrwebReplicatedState:
		return node
	if node != null:
		for child in node.get_children():
			var found := _find_switch(child)
			if found != null: return found
	return null
