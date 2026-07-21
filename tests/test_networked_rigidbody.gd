extends Node

## Creator-facing vertical slice: ordinary VRWML RigidBody3D -> document.physics.bind ->
## simulator binding -> local dynamics/sample authorization -> custom Luau handoff reducer.

var _failed := false


func _ready() -> void:
	Settings.online_enabled = false
	var html := FileAccess.get_file_as_string("res://test_pages/networked_rigidbody.html")
	var doc := HtmlParser.parse(html)
	var declarations := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://networked_rigidbody.html")
	_check(declarations.errors.is_empty() and declarations.scripts.size() == 1,
			"demo declares one valid Luau script: %s" % str(declarations.errors))

	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var built := VrwebBuilder.build(doc, "vrwebresource://networked_rigidbody.html", policy)
	var page_root := built.root as Node
	var grab_manager := GrabManager.new()
	add_child(grab_manager)
	grab_manager.setup(null, null)
	add_child(page_root)
	var targets := _targets(doc, built)
	var default_ball := targets.get("default-ball") as RigidBody3D
	var custom_ball := targets.get("custom-ball") as RigidBody3D
	var throw_ball := targets.get("throw-ball") as Grabbable
	var throw_body := targets.get("throw-ball-body") as RigidBody3D
	_check(default_ball != null and custom_ball != null,
			"demo uses ordinary queryable RigidBody3D tags")
	_check(throw_ball != null and throw_body != null,
			"existing VRWebGrabbable composes with ordinary RigidBody3D")

	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	var errors := []
	runtime.script_failed.connect(func(id, phase, message):
		errors.append({"id": id, "phase": phase, "message": message}))
	runtime.setup(page_root, targets, "vrwebresource://networked_rigidbody.html", null, policy)
	var activated := runtime.activate(declarations.scripts)
	_check(activated.ok, "physics demo script activates: %s / %s" % [str(activated), str(errors)])

	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame
	var object_a := "demo.networked-rigidbody/default_ball"
	var schema_a := "demo.networked-rigidbody/physics_default_ball"
	var object_b := "demo.networked-rigidbody/custom_ball"
	var schema_b := "demo.networked-rigidbody/physics_custom_ball"
	_check(NetworkManager.replicated_bindings(object_a, schema_a).get("simulator") == Settings.user_id,
			"standalone authority auto-claims standard ball")
	_check(not default_ball.freeze, "simulator runs real local RigidBody3D")
	_check(custom_ball.freeze, "unassigned body is a frozen proxy")
	_check(NetworkManager._replicated.authorize_sample(object_a, schema_a, 1,
			{"actor_user_id": Settings.user_id, "is_authority": false}),
			"sample authorization follows simulator binding")

	var default_bridge = default_ball.get_meta(VrwebScriptInputBridge.META, null)
	_check(default_bridge is VrwebScriptInputBridge, "standard ball is an activation target")
	default_bridge.dispatch(default_ball.global_position)
	await get_tree().physics_frame
	_check(default_ball.linear_velocity.length() > 0.1,
			"local simulator receives direct impulse without proxy interpolation")

	var default_sample_count := [0]
	var count_default_sample := func(_sender: int, received_object: String,
			received_schema: String, _sample: Dictionary):
		if received_object == object_a and received_schema == schema_a:
			default_sample_count[0] += 1
	NetworkManager.replicated_sample_received.connect(count_default_sample)
	default_ball.sleeping = true
	for _frame in range(4):
		await get_tree().physics_frame
	_check(default_sample_count[0] == 0,
			"sleep commits a keyframe without continuing the sample stream")
	default_sample_count[0] = 0
	default_ball.sleeping = false
	for _frame in range(8):
		await get_tree().physics_frame
	_check(default_sample_count[0] > 0,
			"wake resumes the author-selected sample stream")
	NetworkManager.replicated_sample_received.disconnect(count_default_sample)

	var custom_bridge = custom_ball.get_meta(VrwebScriptInputBridge.META, null)
	_check(custom_bridge is VrwebScriptInputBridge, "custom ball is an activation target")
	custom_bridge.dispatch(custom_ball.global_position)
	await get_tree().process_frame
	await get_tree().physics_frame
	_check(NetworkManager.replicated_bindings(object_b, schema_b).get("simulator") == Settings.user_id,
			"custom Luau reducer assigns simulator binding")
	_check(int(NetworkManager.replicated_state(object_b, schema_b).get("simulation_epoch", 0)) == 1,
			"custom handoff increments simulation epoch atomically")
	_check(not custom_ball.freeze and custom_ball.linear_velocity.length() > 0.1,
			"accepted handoff switches proxy to local dynamics and applies impulse")

	var grab_state_before := NetworkManager.replicated_state("grab:throw-ball",
			GrabStateSchema.ID)
	grab_manager.request_grab(throw_ball)
	await get_tree().process_frame
	_check(NetworkManager.replicated_bindings("grab:throw-ball",
			GrabStateSchema.ID).get("holder") == Settings.user_id,
			"grab atomically assigns holder")
	_check(NetworkManager.replicated_bindings("grab:throw-ball",
			GrabStateSchema.ID).get("simulator") == Settings.user_id,
			"grab atomically assigns simulator to holder")
	_check(int(NetworkManager.replicated_state("grab:throw-ball", GrabStateSchema.ID)
			.get("simulation_epoch", 0)) > int(grab_state_before.get("simulation_epoch", 0)),
			"grab starts a new simulation epoch")
	_check(throw_body.freeze,
			"held grabbable suspends rigidbody samples and follows the hand presentation")
	grab_manager.release_held()
	await get_tree().process_frame
	_check(str(NetworkManager.replicated_bindings("grab:throw-ball",
			GrabStateSchema.ID).get("holder", "")).is_empty(), "release clears holder")
	_check(NetworkManager.replicated_bindings("grab:throw-ball",
			GrabStateSchema.ID).get("simulator") == Settings.user_id,
			"release leaves simulation on throwing device")
	_check(throw_body.top_level and not throw_body.freeze,
			"released rigidbody returns to direct local free-flight simulation")

	var retiring_adapter := page_root.find_child("VRWebRigidbodySync_default_ball", true, false) \
			as RigidbodySync
	_check(retiring_adapter != null, "refresh fixture finds the live physics adapter")
	runtime.close()
	_check(retiring_adapter.claim() == -1,
			"closed page rejects a deferred claim before its body leaves the tree")
	runtime.queue_free()
	page_root.queue_free()
	grab_manager.queue_free()
	await get_tree().process_frame

	# Точный refresh race: deferred auto-claim старого adapter приходит после того, как
	# связанное тело уже отсоединено, но его Object ещё не уничтожен.
	var refresh_holder := Node3D.new()
	add_child(refresh_holder)
	var detached_body := RigidBody3D.new()
	refresh_holder.add_child(detached_body)
	var refresh_schema := "test.refresh.physics"
	var refresh_object := "test:refresh-body"
	NetworkManager.register_replicated_schema(refresh_schema, RigidbodyStateSchema.definition())
	NetworkManager.register_replicated_object(refresh_object, refresh_schema,
			RigidbodyStateSchema.initial_state(detached_body))
	var detached_adapter := RigidbodySync.new()
	detached_adapter.setup(detached_body, refresh_object, refresh_schema, {"auto_claim": true})
	refresh_holder.add_child(detached_adapter)
	refresh_holder.remove_child(detached_body)
	_check(RigidbodyStateSchema.snapshot(detached_body, 0, 0).is_empty(),
			"snapshot helper rejects a detached body without reading global_transform")
	_check(detached_adapter.claim() == -1,
			"detached but still valid body cannot produce a refresh handoff snapshot")
	await get_tree().process_frame # executes the deferred _maybe_claim from _ready
	detached_adapter.shutdown()
	refresh_holder.queue_free()
	detached_body.free()
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


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  OK  ", label)
	else:
		_failed = true
		push_error("FAIL: " + label)
