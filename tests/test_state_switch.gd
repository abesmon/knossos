extends Node

## End-to-end regression for the creator-facing Luau + distributed state lighting demo.

var _failed := false


func _ready() -> void:
	var html := FileAccess.get_file_as_string("res://test_pages/state_switch.html")
	var doc := HtmlParser.parse(html)
	var declarations := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://state_switch.html")
	_eq(declarations.errors.is_empty(), true, "lighting demo has a valid Luau declaration")
	_eq(declarations.scripts.size(), 2, "state and per-frame update coexist in one scene")

	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var built := VrwebBuilder.build(doc, "vrwebresource://state_switch.html", policy)
	var page_root := built.get("root") as Node
	add_child(page_root)
	var targets := _targets(doc, built)
	var button := targets.get("light-button") as StaticBody3D
	var red_lamp := targets.get("red-lamp") as MeshInstance3D
	var green_lamp := targets.get("green-lamp") as MeshInstance3D
	_eq(button != null and button.has_node("Collision"), true,
			"button is an ordinary queryable StaticBody3D")
	_eq(red_lamp != null and green_lamp != null, true,
			"lamps are ordinary queryable scene nodes")
	var local_ball := targets.get("local-ball") as MeshInstance3D
	var local_label := targets.get("local-clock-label") as Label3D
	var local_material := targets.get("LocalBallMaterial") as StandardMaterial3D
	_eq(local_ball != null and local_label != null and local_material != null, true,
			"update demo exposes both nodes and a material resource")

	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	var script_errors := []
	runtime.script_failed.connect(func(script_id: String, phase: String, message: String):
		script_errors.append({"script_id": script_id, "phase": phase, "message": message}))
	runtime.setup(page_root, targets, "vrwebresource://state_switch.html", null, policy)
	var activated := runtime.activate(declarations.scripts)
	_eq(activated.ok, true, "lighting Luau script activates")
	_eq(button.has_meta(VrwebScriptInputBridge.META), true,
			"Luau registers the ordinary body as an activation target")
	_eq(red_lamp.visible and not green_lamp.visible, true,
			"script renders the initial distributed state")
	var initial_color := local_material.albedo_color
	runtime._process(0.25)
	_eq(local_label.text.begins_with("LOCAL SCENE TIME\n0.25"), true,
			"on_update receives the shared local scene time")
	_eq(not local_material.albedo_color.is_equal_approx(initial_color), true,
			"a resource handle updates the material from Luau")
	_eq(not local_ball.position.is_equal_approx(Vector3(-3, 1.55, -4)), true,
			"on_update drives an ordinary scene node")

	# Entering/replacing a room resets objects after scripts may have activated. The bridge must
	# restore its declarations on the same authority transition used by real clients.
	NetworkManager._replicated.reset_session()
	NetworkManager.authority_changed.emit(1, true)
	_eq(NetworkManager.replicated_revision("demo.light-switch/switch",
			"demo.light-switch/light"), 0, "script state survives room reset")

	# Exercise the creator-facing path: input bridge -> Luau callback ->
	# document.state.command -> standalone authority -> Store delta -> Luau subscription.
	var online_before := Settings.online_enabled
	Settings.online_enabled = false
	var command_result := []
	var capture_result := func(request_id: int, accepted: bool, code: String, revision: int):
		command_result.append({"request_id": request_id, "accepted": accepted,
			"code": code, "revision": revision})
	NetworkManager.replicated_command_result.connect(capture_result)
	var bridge = button.get_meta(VrwebScriptInputBridge.META, null)
	_eq(bridge is VrwebScriptInputBridge and bridge.dispatch(Vector3.ZERO), true,
			"input activation reaches the page-defined handler")
	_eq(script_errors.is_empty(), true, "activation callback completes (%s)" % str(script_errors))
	await get_tree().process_frame
	NetworkManager.replicated_command_result.disconnect(capture_result)
	Settings.online_enabled = online_before
	_eq(not command_result.is_empty() and bool(command_result[0].accepted), true,
			"standalone distributed command is accepted (%s)" % str(command_result))
	_eq(not red_lamp.visible and green_lamp.visible, true,
			"activation commits distributed state and updates scene objects")

	runtime.close()
	runtime.queue_free()
	page_root.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _targets(doc: HtmlNode, built: Dictionary) -> Dictionary:
	var result := {}
	var index := SceneHtml.build_page_index(doc)
	for node_id in index.get("nodes", {}):
		var record: Dictionary = index.nodes[node_id]
		var node = (built.nodes as Dictionary).get(record.elem)
		if node != null:
			result[node_id] = node
	for resource_id in built.get("resources", {}):
		if not result.has(resource_id):
			result[resource_id] = built.resources[resource_id]
	return result


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
