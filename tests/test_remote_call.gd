extends Node

## End-to-end regression for typed script remote calls and reactive participant permissions.

class FakePlayer extends Node3D:
	var teleport_count := 0

	func teleport_to(value: Vector3) -> void:
		teleport_count += 1
		global_position = value


var _failed := false


func _ready() -> void:
	var old_my_id = NetworkManager._my_id
	var old_mesh = NetworkManager._mesh
	var old_my_seq = NetworkManager._my_seq
	var old_connected = NetworkManager._connected_peers.duplicate(true)
	var old_peer_seqs = NetworkManager._peer_seqs.duplicate(true)
	var old_ranks = NetworkManager._ranks.duplicate(true)

	# A non-authority participant with a sufficiently privileged assigned rank.
	NetworkManager._my_id = 2
	NetworkManager._mesh = RefCounted.new()
	NetworkManager._my_seq = 2
	NetworkManager._connected_peers = {1: true}
	NetworkManager._peer_seqs = {1: 1}
	NetworkManager._ranks[Settings.user_id] = 5

	var html := FileAccess.get_file_as_string("res://test_pages/remote_call.html")
	var doc := HtmlParser.parse(html)
	var declarations := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://remote_call.html")
	_eq(declarations.errors.is_empty(), true, "remote call demo has a valid declaration")
	_eq(declarations.scripts.size(), 1, "remote call demo has one page script")

	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var built := VrwebBuilder.build(doc, "vrwebresource://remote_call.html", policy)
	var page_root := built.get("root") as Node
	add_child(page_root)
	var targets := _targets(doc, built)
	var unchecked_button := targets.get("unchecked-button") as StaticBody3D
	var authority_button := targets.get("authority-button") as StaticBody3D
	var rank_button := targets.get("rank-button") as StaticBody3D
	var local_label := targets.get("local-info") as Label3D
	var roster_label := targets.get("roster-info") as Label3D
	var unchecked_status := targets.get("unchecked-status") as Label3D
	var authority_status := targets.get("authority-status") as Label3D
	var rank_status := targets.get("rank-status") as Label3D
	_eq(unchecked_button != null and authority_button != null and rank_button != null, true,
			"all three remote call scenarios build as interactive scene objects")

	var player := FakePlayer.new()
	add_child(player)
	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	var script_errors := []
	runtime.script_failed.connect(func(script_id: String, phase: String, message: String):
		script_errors.append({"script_id": script_id, "phase": phase, "message": message}))
	runtime.setup(page_root, targets, "vrwebresource://remote_call.html", player, policy)
	var activated := runtime.activate(declarations.scripts)
	_eq(activated.ok, true, "remote call Luau script activates (%s)" % str(activated))
	if not activated.ok:
		runtime.close()
		page_root.queue_free()
		player.queue_free()
		NetworkManager._my_id = old_my_id
		NetworkManager._mesh = old_mesh
		NetworkManager._my_seq = old_my_seq
		NetworkManager._connected_peers = old_connected
		NetworkManager._peer_seqs = old_peer_seqs
		NetworkManager._ranks = old_ranks
		get_tree().quit(1)
		return
	_eq(script_errors.is_empty(), true, "initial callbacks complete (%s)" % str(script_errors))
	_eq(local_label.text.contains("rank: 5") and local_label.text.contains("authority: нет"),
			true, "local permissions panel renders current rank and authority reactively")
	_eq(roster_label.text.contains("ВСЕ УЧАСТНИКИ ИНСТАНСА"), true,
			"instance roster panel renders its initial snapshot")

	# No-check handler always accepts and applies its custom reaction.
	var bridge = unchecked_button.get_meta(VrwebScriptInputBridge.META, null)
	_eq(bridge is VrwebScriptInputBridge and bridge.dispatch(Vector3.ZERO), true,
			"unchecked button dispatches a targeted call")
	await get_tree().process_frame
	_eq(player.teleport_count, 1, "unchecked endpoint moves the local player")
	_eq(unchecked_status.text.begins_with("ПРИНЯТО"), true,
			"unchecked endpoint renders its custom accepted reaction")
	NetworkManager.script_remote_call_received.emit(2, "demo.remote-call", "move-unchecked",
			2, [Vector3(9, 9, 9)])
	NetworkManager.script_remote_call_received.emit(2, "demo.remote-call", "move-unchecked",
			1, ["not a vector"])
	_eq(player.teleport_count, 1,
			"endpoint ignores mismatched versions and argument types before its callback")
	_eq(NetworkManager.send_script_remote_call(2, "demo.remote-call", "move-unchecked", 1,
			[RefCounted.new()]), false, "transport rejects non-portable wire values")

	# The same caller is rejected by an authority-only handler.
	bridge = authority_button.get_meta(VrwebScriptInputBridge.META, null)
	bridge.dispatch(Vector3.ZERO)
	await get_tree().process_frame
	_eq(player.teleport_count, 1, "authority endpoint rejects a non-authority caller")
	_eq(authority_status.text.begins_with("ОТКЛОНЕНО"), true,
			"authority endpoint renders its custom denied reaction")

	# Rank-gated handler accepts rank 5 and reacts to a live rank downgrade.
	bridge = rank_button.get_meta(VrwebScriptInputBridge.META, null)
	bridge.dispatch(Vector3.ZERO)
	await get_tree().process_frame
	_eq(player.teleport_count, 2, "rank endpoint accepts assigned rank within threshold")
	_eq(rank_status.text.begins_with("ПРИНЯТО"), true,
			"rank endpoint renders its accepted reaction")
	NetworkManager._ranks[Settings.user_id] = 50
	NetworkManager.ranks_changed.emit()
	_eq(local_label.text.contains("rank: 50"), true,
			"permissions panel updates when the rank table changes")
	_eq(roster_label.text.contains("rank 50"), true,
			"instance roster updates from the same reactive participant snapshot")
	bridge.dispatch(Vector3.ZERO)
	await get_tree().process_frame
	_eq(player.teleport_count, 2, "rank endpoint rejects a live downgrade")
	_eq(rank_status.text.begins_with("ОТКЛОНЕНО"), true,
			"rank endpoint renders the new denied result")

	# Authority is computed locally from trusted peer metadata, not supplied by the call.
	NetworkManager._my_id = 1
	NetworkManager._my_seq = 1
	NetworkManager._connected_peers.clear()
	NetworkManager._peer_seqs.clear()
	NetworkManager.authority_changed.emit(1, true)
	_eq(local_label.text.contains("authority: да"), true,
			"permissions panel updates when authority changes")
	bridge = authority_button.get_meta(VrwebScriptInputBridge.META, null)
	bridge.dispatch(Vector3.ZERO)
	await get_tree().process_frame
	_eq(player.teleport_count, 3, "authority endpoint accepts the locally verified authority")
	_eq(script_errors.is_empty(), true, "all remote callbacks complete (%s)" % str(script_errors))

	runtime.close()
	runtime.queue_free()
	page_root.queue_free()
	player.queue_free()
	NetworkManager._my_id = old_my_id
	NetworkManager._mesh = old_mesh
	NetworkManager._my_seq = old_my_seq
	NetworkManager._connected_peers = old_connected
	NetworkManager._peer_seqs = old_peer_seqs
	NetworkManager._ranks = old_ranks
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
