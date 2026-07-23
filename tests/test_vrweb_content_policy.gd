extends Node

var _failed := false


func _ready() -> void:
	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var doc := HtmlParser.parse("""
<vrwml mode="exclusive">
  <Node3D name="FromDocument" position="Vector3(1,2,3)"/>
  <Resource id="Box" type="BoxMesh" size="Vector3(1,1,1)"/>
</vrwml>
""")
	var built := VrwebBuilder.build(doc, "https://example.test/world", policy)
	_eq(built.root != null, true, "allow-all policy preserves document materialization")
	_eq(built.root.get_node_or_null("FromDocument") != null, true,
			"document declaration remains allowed")

	var view := EphemeralView.new()
	add_child(view)
	view.setup(Callable(), {"content_policy": policy, "base_url": "https://example.test/world"})
	var live_object := {
		"id": "peer.1", "kind": SceneHtml.KIND_NODE, "bindings": {"creator": "peer-user"}, "parent": "",
		"props": {"tag": "Node3D", "attrs": {"name": "FromPeer", "visible": "true"}},
	}
	view.call("_on_added", "peer.1", live_object)
	var live_node: Node = view.get_node_or_null("FromPeer")
	_eq(live_node != null, true, "allow-all policy preserves live peer materialization")

	var audit := policy.snapshot()
	_eq(int(audit.classes.get("Node3D", 0)) >= 2, true,
			"audit records declarations from both paths")
	_eq(int(audit.resources.get("BoxMesh", 0)), 1, "audit records document resources")
	_eq(int(audit.properties.get("Node3D.position", 0)), 1,
			"audit records declared attributes")
	_eq(int(audit.sources.get(VrwebContentPolicy.SOURCE_DOCUMENT, 0)) > 0, true,
			"audit identifies document source")
	_eq(int(audit.sources.get(VrwebContentPolicy.SOURCE_LIVE_PEER, 0)) > 0, true,
			"audit identifies live peer source")
	_eq(int(audit.operations.get(SceneHtml.KIND_NODE, 0)), 1,
			"audit records live peer operation kind")

	var empty_enforce := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ENFORCE)
	var decision := empty_enforce.evaluate_element("UnknownFutureNode", {"future": "value"})
	_eq(VrwebContentPolicy.allowed(decision), true,
			"enforce mode without configured rules remains allow-all")

	if built.root != null:
		built.root.free()
	view.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
