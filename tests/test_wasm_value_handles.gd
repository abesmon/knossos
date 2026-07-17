extends SceneTree

var _failed := false


func _initialize() -> void:
	var values: Array = [null, true, 42, 3.5, "hello", PackedByteArray([1, 2, 3]),
		[1, "two"], {"b": 2, "a": 1}, Vector2(1, 2), Vector3(1, 2, 3),
		Vector4(1, 2, 3, 4), Quaternion(0, 0, 0, 1), Color(0.1, 0.2, 0.3, 0.4),
		Basis.IDENTITY, Transform3D(Basis.IDENTITY, Vector3(4, 5, 6))]
	for value in values:
		var encoded := WasmValueCodec.encode_bytes(value)
		_eq(encoded.ok, true, "value encodes: %s" % type_string(typeof(value)))
		if bool(encoded.ok):
			var decoded := WasmValueCodec.decode_bytes(encoded.value)
			_eq(decoded.ok, true, "value decodes: %s" % type_string(typeof(value)))
			_eq(decoded.value, value, "value round-trips: %s" % type_string(typeof(value)))
	_eq(WasmValueCodec.encode(NAN).error, "non_finite_float", "NaN rejected")
	_eq(WasmValueCodec.decode({"t": "unknown"}).error, "unknown_tag", "unknown tag rejected")
	_eq(WasmValueCodec.decode_bytes("{".to_utf8_buffer()).error, "malformed_json",
		"malformed bytes rejected")
	var golden: Array = JSON.parse_string(FileAccess.get_file_as_string(
			"res://spec/value-codec-golden.json"))
	for fixture in golden:
		var decoded_golden := WasmValueCodec.decode(fixture.wire)
		_eq(decoded_golden.ok, true, "host decodes golden %s" % fixture.name)
		if bool(decoded_golden.ok):
			_eq(WasmValueCodec.encode(decoded_golden.value).value, fixture.wire,
					"host emits canonical golden %s" % fixture.name)

	var handles := WasmHandleTable.new()
	var object := Node.new()
	var handle := handles.create(object, "module-a", "page-a", "node")
	_eq(handles.create(object, "module-a", "page-a", "node"), handle,
		"same scoped object reuses stable handle")
	_eq(handles.size(), 1, "handle interning does not grow table")
	_eq(handles.resolve(handle, "module-a", "page-a", "node").value, object,
		"owned handle resolves")
	_eq(handles.resolve(handle, "module-b", "page-a").error, "foreign_owner",
		"foreign module rejected")
	_eq(handles.resolve(handle, "module-a", "page-b").error, "foreign_page",
		"foreign page rejected")
	_eq(handles.resolve(handle + 12345, "module-a", "page-a").ok, false, "forged handle rejected")
	_eq(handles.invalidate(handle), true, "handle invalidated")
	_eq(handles.resolve(handle, "module-a", "page-a").error, "stale_handle",
		"stale generation rejected")
	object.free()

	var page := Node3D.new()
	var component := Node3D.new()
	component.name = "Component"
	var child := Node3D.new()
	child.name = "Child"
	child.position = Vector3(1, 2, 3)
	var sibling := Node3D.new()
	page.add_child(component)
	page.add_child(sibling)
	component.add_child(child)
	get_root().add_child(page)
	var content_policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.AUDIT)
	var authority := SceneAuthority.new("module-a", "page-a", component, handles, content_policy)
	var root_handle := authority.root_handle()
	var wire_root: Variant = authority.wasm_host_call("query", 0,
			JSON.stringify({"op": "root"}).to_utf8_buffer(), [])
	_eq(wire_root is PackedByteArray, true, "WIT host root query returns bytes")
	if wire_root is PackedByteArray:
		_eq(int(JSON.parse_string(wire_root.get_string_from_utf8())), root_handle,
				"WIT host root handle matches authority")
	var wire_set := {"op": "set", "handle": root_handle, "property": "visible",
		"value": WasmValueCodec.encode(false).value}
	_eq(authority.wasm_host_call("mutate", 77,
			JSON.stringify(wire_set).to_utf8_buffer(), []), PackedByteArray(),
			"WIT host accepts bounded mutation")
	var wire_commit: Variant = authority.wasm_host_call("commit", 77, PackedByteArray(), [])
	_eq(wire_commit is PackedByteArray, true, "WIT host commits transaction")
	_eq(component.visible, false, "WIT host transaction changes scoped scene")
	var wire_create := {"op": "create", "token": "lamp", "class": "Node3D",
		"parent": root_handle, "initial": {}}
	_eq(authority.wasm_host_call("mutate", 78,
			JSON.stringify(wire_create).to_utf8_buffer(), []), PackedByteArray(),
			"WIT host accepts guest create token")
	var wire_created: PackedByteArray = authority.wasm_host_call(
			"commit", 78, PackedByteArray(), [])
	var wire_create_result: Dictionary = JSON.parse_string(wire_created.get_string_from_utf8())
	var wire_created_handle := int(wire_create_result.created.get("lamp", 0))
	_eq(wire_created_handle > 0, true,
			"commit maps guest create token to opaque handle")
	var wire_destroy := {"op": "destroy", "handle": wire_created_handle}
	authority.wasm_host_call("mutate", 79,
			JSON.stringify(wire_destroy).to_utf8_buffer(), [])
	authority.wasm_host_call("commit", 79, PackedByteArray(), [])
	_eq(authority.wasm_host_call("query", 0, PackedByteArray([255]), []),
			"wire_invalid_utf8", "WIT host rejects invalid UTF-8")
	_eq(authority.class_name_of(root_handle).value, "Node3D", "root class readable")
	_eq(authority.parent_of(root_handle).value, 0, "parent outside scope hidden")
	var child_handles: Array = authority.children_of(root_handle).value
	_eq(child_handles.size(), 1, "owned child enumerated")
	_eq(WasmValueCodec.decode(authority.get_property(child_handles[0], "position").value).value,
		Vector3(1, 2, 3), "safe property encoded")
	_eq(authority.get_property(child_handles[0], "script").error, "property_not_readable",
			"unsafe property denied")
	for forbidden_path in ["/root", "/root/Player", "/root/ExampleAutoload", "../Sibling"]:
		var path_query := JSON.stringify({"op": "path", "path": forbidden_path}).to_utf8_buffer()
		_eq(authority.wasm_host_call("query", 0, path_query, []), "path_forbidden",
				"NodePath authority denied: %s" % forbidden_path)
	var foreign_owner_handle := handles.create(sibling, "module-b", "page-a", "node")
	_eq(authority.class_name_of(foreign_owner_handle).error, "foreign_owner",
			"foreign module handle denied by Scene API")
	var foreign_page_handle := handles.create(sibling, "module-a", "page-b", "node")
	_eq(authority.class_name_of(foreign_page_handle).error, "foreign_page",
			"foreign page handle denied by Scene API")
	var mutation := authority.begin_mutation()
	mutation.set_property(child_handles[0], "position",
			WasmValueCodec.encode(Vector3(7, 8, 9)).value)
	mutation.set_property(child_handles[0], "visible", WasmValueCodec.encode(false).value)
	_eq(mutation.commit().ok, true, "valid property batch committed")
	_eq(child.position, Vector3(7, 8, 9), "position changed at commit")
	_eq(child.visible, false, "visibility changed at commit")
	_eq(content_policy.snapshot().mutations.has("Node3D.position"), true,
			"Scene mutations pass through shared VrwebContentPolicy boundary")

	var snapshot := {"position": child.position, "visible": child.visible}
	mutation = authority.begin_mutation()
	mutation.set_property(child_handles[0], "position",
			WasmValueCodec.encode(Vector3(2, 2, 2)).value)
	mutation.set_property(child_handles[0], "visible", WasmValueCodec.encode("wrong").value)
	_eq(mutation.commit().error, "property_type_mismatch", "invalid middle command rejects batch")
	_eq({"position": child.position, "visible": child.visible}, snapshot,
		"rejected batch leaves snapshot unchanged")
	mutation = authority.begin_mutation()
	mutation.set_property(child_handles[0], "script", WasmValueCodec.encode(null).value)
	_eq(mutation.commit().error, "property_not_writable", "dangerous property denied")
	mutation = authority.begin_mutation()
	mutation.set_property(child_handles[0], "scene_file_path",
			WasmValueCodec.encode("/tmp/escape").value)
	_eq(mutation.commit().error, "property_not_writable", "filesystem path property denied")
	_eq(WasmValueCodec.encode(child).error, "unsupported_type", "raw object value denied")
	mutation = authority.begin_mutation()
	for index in SceneMutation.MAX_COMMANDS:
		_eq(mutation.set_property(child_handles[0], "visible",
				WasmValueCodec.encode(index % 2 == 0).value).ok, true,
				"bounded command %d accepted" % index)
	_eq(mutation.set_property(child_handles[0], "visible",
			WasmValueCodec.encode(true).value).error, "command_limit",
			"overflow batch rejected before commit")
	mutation.cancel()

	var resource := authority.create_resource("BoxMesh")
	_eq(resource.ok, true, "allowlisted resource created")
	mutation = authority.begin_mutation()
	var create_result := mutation.create_node("MeshInstance3D", root_handle,
			{"position": WasmValueCodec.encode(Vector3(3, 0, 0)).value})
	var committed := mutation.commit()
	_eq(committed.ok, true, "allowlisted node created")
	var mesh_handle := int(committed.value.created[create_result.value])
	mutation = authority.begin_mutation()
	mutation.set_resource(mesh_handle, "mesh", resource.value)
	_eq(mutation.commit().ok, true, "owned resource bound to node")
	var mesh_node: MeshInstance3D = authority._node(mesh_handle).value
	_eq(mesh_node.mesh is BoxMesh, true, "resource binding applied")
	mutation = authority.begin_mutation()
	mutation.reparent(mesh_handle, child_handles[0])
	_eq(mutation.commit().ok, true, "owned node reparented inside scope")
	_eq(mesh_node.get_parent(), child, "reparent target applied")
	mutation = authority.begin_mutation()
	mutation.destroy(root_handle)
	_eq(mutation.commit().error, "node_not_owned", "host-owned root cannot be destroyed")
	mutation = authority.begin_mutation()
	mutation.destroy(mesh_handle)
	_eq(mutation.commit().ok, true, "owned node destroyed")
	_eq(is_instance_valid(mesh_node), false, "destroy frees owned node")
	_eq(authority.create_resource("Script").error, "resource_class_forbidden",
			"forbidden resource class rejected")
	var cycle_a_result := authority.begin_mutation()
	var cycle_a_token := str(cycle_a_result.create_node("Node3D", root_handle).value)
	var cycle_a_commit := cycle_a_result.commit()
	var cycle_a := int(cycle_a_commit.value.created[cycle_a_token])
	var cycle_b_result := authority.begin_mutation()
	var cycle_b_token := str(cycle_b_result.create_node("Node3D", cycle_a).value)
	var cycle_b_commit := cycle_b_result.commit()
	var cycle_b := int(cycle_b_commit.value.created[cycle_b_token])
	mutation = authority.begin_mutation()
	mutation.reparent(cycle_a, cycle_b)
	_eq(mutation.commit().error, "reparent_cycle", "reparent cycle rejected")
	var resources_within_quota := 0
	for index in SceneAuthority.MAX_GUEST_RESOURCES - 1:
		if bool(authority.create_resource("BoxMesh").ok):
			resources_within_quota += 1
	_eq(resources_within_quota, SceneAuthority.MAX_GUEST_RESOURCES - 1,
			"guest resources accepted up to quota")
	_eq(authority.create_resource("BoxMesh").error, "resource_quota",
			"guest resource growth stops at quota")
	_eq(authority.call_method(root_handle, "hide", []).ok, true, "allowlisted method called")
	_eq(component.visible, false, "hide method changed component")
	_eq(authority.call_method(root_handle, "queue_free", []).error, "method_not_allowed",
			"dangerous method denied")
	_eq(authority.call_method(root_handle, "get_node", []).error, "method_not_allowed",
			"unknown object-returning method denied")
	var animation := AnimationPlayer.new()
	var animation_library := AnimationLibrary.new()
	animation_library.add_animation("idle", Animation.new())
	animation.add_animation_library("", animation_library)
	component.add_child(animation)
	var animation_handles: Array = authority.children_of(root_handle).value
	var animation_handle := int(animation_handles[animation_handles.size() - 1])
	_eq(authority.call_method(animation_handle, "play",
			[WasmValueCodec.encode("idle").value]).ok, true,
			"catalog allows bounded AnimationPlayer.play")
	var interaction_area := Area3D.new()
	component.add_child(interaction_area)
	var interaction_handles: Array = authority.children_of(root_handle).value
	var interaction_handle := int(interaction_handles[interaction_handles.size() - 1])
	var interaction_subscription := authority.subscribe_signal(interaction_handle, "mouse_entered")
	_eq(interaction_subscription.ok, true, "catalog allows interaction signal subscription")
	interaction_area.emit_signal("mouse_entered")
	_eq(authority.drain_events()[0].signal, "mouse_entered",
			"interaction signal becomes queued guest event")
	authority.unsubscribe_signal(interaction_subscription.value)
	var subscription := authority.subscribe_signal(root_handle, "renamed")
	_eq(subscription.ok, true, "allowlisted signal subscribed")
	component.emit_signal("renamed")
	var events := authority.drain_events()
	_eq(events.size(), 1, "signal queued instead of direct callback")
	_eq(events[0].signal, "renamed", "queued signal identity preserved")
	_eq(authority.unsubscribe_signal(subscription.value), true, "signal disconnected")
	component.emit_signal("renamed")
	_eq(authority.drain_events(), [], "disconnected signal produces no callback")
	authority._on_signal(int(subscription.value), "renamed")
	_eq(authority.drain_events(), [], "already queued callback ignored after disconnect")
	authority.enable_updates(true)
	for delta in [0.016, 0.017, 0.018]:
		_eq(authority.enqueue_frame(delta), true, "frame event enabled")
	var frame_events := authority.drain_events()
	_eq(frame_events.size(), 3, "multiple frame events queued")
	_eq(frame_events[0].kind, "frame", "frame event identity preserved")
	subscription = authority.subscribe_signal(root_handle, "renamed")
	for index in SceneAuthority.MAX_SIGNAL_EVENTS + 10:
		component.emit_signal("renamed")
	_eq(authority.drain_events().size(), SceneAuthority.MAX_SIGNAL_EVENTS,
		"signal queue bounded")
	_eq(authority.dropped_event_count(), 10, "signal flood counted and dropped")
	var foreign_handle := handles.create(sibling, "module-a", "page-a", "node")
	_eq(authority.class_name_of(foreign_handle).error, "outside_scope",
			"sibling handle cannot cross scope")
	mutation = authority.begin_mutation()
	mutation.reparent(cycle_b, foreign_handle)
	_eq(mutation.commit().error, "outside_scope", "reparent outside owned scope rejected")
	var depth_parent := root_handle
	for depth in SceneAuthority.MAX_DEPTH:
		mutation = authority.begin_mutation()
		var depth_token := str(mutation.create_node("Node3D", depth_parent).value)
		var depth_commit := mutation.commit()
		_eq(depth_commit.ok, true, "node depth %d accepted" % (depth + 1))
		if bool(depth_commit.ok):
			depth_parent = int(depth_commit.value.created[depth_token])
	mutation = authority.begin_mutation()
	mutation.create_node("Node3D", depth_parent)
	_eq(mutation.commit().error, "depth_quota", "node depth quota enforced")
	var remaining_nodes := SceneAuthority.MAX_GUEST_NODES - 2 - SceneAuthority.MAX_DEPTH
	mutation = authority.begin_mutation()
	for index in remaining_nodes:
		mutation.create_node("Node3D", root_handle, {}, "quota-%d" % index)
	_eq(mutation.commit().ok, true, "guest nodes accepted up to quota")
	mutation = authority.begin_mutation()
	mutation.create_node("Node3D", root_handle)
	_eq(mutation.commit().error, "node_quota", "guest node quota enforced")
	var cleanup_node: Node = authority._node(cycle_b).value
	authority.close()
	_eq(authority.class_name_of(root_handle).ok, false, "handles invalid after close")
	_eq(is_instance_valid(cleanup_node), false,
			"nested guest-owned descendants removed during lifecycle cleanup")
	page.free()
	quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
