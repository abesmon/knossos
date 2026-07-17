extends Node

var _failed := false


func _ready() -> void:
	_test_declarations()
	_test_integrity()
	_test_export()
	await _test_fetch()
	if not OS.get_environment("VRWEB_SCRIPT_TEST_BASE").is_empty():
		await _test_http_fetch(OS.get_environment("VRWEB_SCRIPT_TEST_BASE"))
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _test_declarations() -> void:
	var html := """
<script type="application/vrweb+luau" id="first">document.log.info("one")</script>
<script type="application/vrweb+luau" id="second" src="external_tiny.luau"></script>
"""
	var result := VrwebScriptDeclaration.collect(HtmlParser.parse(html),
			"vrwebresource://external_script.html")
	_eq(result.errors.is_empty(), true, "valid inline and linked declarations collect")
	_eq(result.scripts.size(), 2, "document order is retained")
	if result.scripts.size() == 2:
		_eq(result.scripts[0].kind, "inline", "inline kind is explicit")
		_eq(result.scripts[1].kind, "linked", "linked kind is explicit")
	var invalid := VrwebScriptDeclaration.collect(HtmlParser.parse(
			'<script type="application/vrweb+luau" id="same" src="x.luau">return 1</script>'), "")
	_eq(invalid.errors.size(), 1, "src and inline body are mutually exclusive")
	var data_url := VrwebScriptDeclaration.collect(HtmlParser.parse(
			'<script type="application/vrweb+luau" id="data" src="DATA:text/plain,x"></script>'), "")
	_eq(data_url.errors.size(), 1, "data script URLs are rejected case-insensitively")


func _test_integrity() -> void:
	var bytes := "return 42".to_utf8_buffer()
	var sri := VrwebScriptIntegrity.sri_sha256(bytes)
	_eq(VrwebScriptIntegrity.verify({}, bytes).ok, true,
			"missing integrity intentionally skips validation")
	_eq(VrwebScriptIntegrity.verify({"integrity": sri}, bytes).code, "verified",
			"present integrity is verified")
	_eq(VrwebScriptIntegrity.verify({"integrity": "sha384-unsupported " + sri}, bytes).ok,
			true, "a matching supported token is accepted among SRI tokens")
	_eq(VrwebScriptIntegrity.verify({"integrity": sri}, "changed".to_utf8_buffer()).ok,
			false, "integrity mismatch is a hard failure")


func _test_export() -> void:
	var root := Node3D.new()
	root.set_meta(VrwebExporter.META_PAGE_SCRIPTS, [
		{"id": "inline.export", "source": "return 42"},
		{"id": "linked.export", "src": "behavior.luau", "integrity": "sha256-demo"},
	])
	var target := Node3D.new()
	target.set_meta(VrwebExporter.META_ELEMENT_ID, "target")
	root.add_child(target)
	var report := VrwebExporter.export_scene_report(root)
	_eq(report.ok, true, "Maker exports portable page script declarations")
	_eq(str(report.html).contains('type="application/vrweb+luau" id="inline.export"'),
			true, "Maker emits inline Luau")
	_eq(str(report.html).contains('src="behavior.luau" integrity="sha256-demo"'), true,
			"Maker emits linked Luau and optional integrity")
	_eq(str(report.html).contains('id="target"'), true, "Maker exports queryable element ids")
	root.free()


func _test_fetch() -> void:
	# Keep this helper asynchronous even when a bundled linked source completes synchronously.
	await get_tree().process_frame
	var doc := HtmlParser.parse(FileAccess.get_file_as_string("res://test_pages/external_script.html"))
	var collected := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://external_script.html")
	_eq(collected.errors.is_empty(), true, "modular demo declarations are valid")
	_eq(collected.scripts.size(), 3, "two linked modules and one inline controller collect")
	if collected.scripts.size() == 3:
		_eq(collected.scripts[0].kind, "linked", "model is linked")
		_eq(collected.scripts[1].kind, "linked", "view is linked")
		_eq(collected.scripts[2].kind, "inline", "controller is inline")
	var fetcher := VrwebScriptFetcher.new()
	add_child(fetcher)
	var completion := {"done": false, "result": {}}
	fetcher.fetch_all(collected.scripts, func(value): completion.result = value; completion.done = true)
	var frames := 0
	while not bool(completion.done) and frames < 10:
		await get_tree().process_frame
		frames += 1
	_eq(completion.done, true, "linked fetch completes")
	if not bool(completion.done):
		fetcher.queue_free()
		return
	var result: Dictionary = completion.result
	_eq(result.errors.is_empty(), true, "linked source fetch succeeds")
	_eq(result.scripts.size(), 3, "linked sources and inline controller are materialized")
	if result.scripts.size() == 3:
		_eq(str(result.scripts[0].source).contains("document.query"), true,
				"fetcher returns source, never bytecode")
		var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
		var built := VrwebBuilder.build(doc, "vrwebresource://external_script.html", policy)
		var page_root := built.get("root") as Node
		add_child(page_root)
		var targets := {}
		var index := SceneHtml.build_page_index(doc)
		for node_id in index.get("nodes", {}):
			var record: Dictionary = index.nodes[node_id]
			var node = (built.nodes as Dictionary).get(record.elem)
			if node != null:
				targets[node_id] = node
		var runtime := VrwebLuauRuntime.new()
		add_child(runtime)
		var script_errors := []
		runtime.script_failed.connect(func(id, phase, message):
			script_errors.append({"id": id, "phase": phase, "message": message}))
		runtime.setup(page_root, targets, "vrwebresource://external_script.html", null, policy)
		_eq(runtime.activate(result.scripts).ok, true,
				"three modular declarations execute through the page runtime")
		_eq((targets.get("external-label") as Label3D).text,
				"2 LINKED FILES + 1 INLINE SCRIPT",
				"linked view mutates its VRWML target by id")
		await get_tree().process_frame
		_eq((targets.get("view-status") as Label3D).text.contains("apply-speed(1.0)"), true,
				"linked model calls the linked view endpoint after activation")
		var spinner := targets.get("external-spinner") as MeshInstance3D
		runtime._process(0.25)
		_eq(not spinner.position.is_equal_approx(Vector3.ZERO), true,
				"linked view animates from its private received speed")
		var button := targets.get("external-button") as StaticBody3D
		var bridge = button.get_meta(VrwebScriptInputBridge.META, null)
		_eq(bridge is VrwebScriptInputBridge and bridge.dispatch(Vector3.ZERO), true,
				"inline controller invokes the linked model")
		await get_tree().process_frame
		await get_tree().process_frame
		_eq((targets.get("model-status") as Label3D).text.contains("private speed = 2.0x"),
				true, "linked model updates its private state")
		_eq((targets.get("view-status") as Label3D).text.contains("apply-speed(2.0)"), true,
				"model forwards the new value to the linked view")
		_eq(script_errors.is_empty(), true,
				"cross-realm endpoint chain completes without script errors")
		runtime.close()
		runtime.queue_free()
		page_root.queue_free()
	var forbidden := {"done": false, "result": {}}
	fetcher.fetch_all([{"id": "remote.local", "profile": VrwebScriptDeclaration.PROFILE,
		"kind": "linked", "source": "", "src": "vrweblocal:///etc/passwd",
		"integrity": "", "base_url": "https://example.test/page"}],
		func(value): forbidden.result = value; forbidden.done = true)
	_eq(forbidden.done, true, "forbidden local URL finishes synchronously")
	_eq((forbidden.result as Dictionary).errors[0].code, "forbidden_url",
			"remote pages cannot read or execute local linked scripts")
	fetcher.queue_free()


func _test_http_fetch(base_url: String) -> void:
	var source := 'document.session.http = "ok"\n'
	var declaration := {"id": "http.redirect", "profile": VrwebScriptDeclaration.PROFILE,
		"kind": "linked", "source": "", "src": "redirect.luau",
		"integrity": VrwebScriptIntegrity.sri_sha256(source.to_utf8_buffer()),
		"base_url": base_url + "/page.html"}
	var fetcher := VrwebScriptFetcher.new()
	add_child(fetcher)
	var completion := {"done": false, "result": {}}
	fetcher.fetch_all([declaration],
		func(value): completion.result = value; completion.done = true)
	var deadline := Time.get_ticks_msec() + 5000
	while not bool(completion.done) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_eq(completion.done, true, "HTTP linked fetch completes")
	if bool(completion.done):
		var result: Dictionary = completion.result
		_eq(result.errors.is_empty(), true, "HTTP redirect and SRI are accepted")
		_eq(result.scripts.size(), 1, "HTTP linked source is returned")
		if result.scripts.size() == 1:
			var page := Node3D.new()
			add_child(page)
			var runtime := VrwebLuauRuntime.new()
			add_child(runtime)
			runtime.setup(page, {}, base_url + "/page.html", null,
					VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
			_eq(runtime.activate(result.scripts).ok, true,
					"HTTP linked source executes in Luau realm")
			_eq(runtime.session_of("http.redirect").get("http"), "ok",
					"executed HTTP source updates document.session")
			runtime.close()
			runtime.queue_free()
			page.queue_free()
	fetcher.queue_free()


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
