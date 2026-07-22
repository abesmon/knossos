extends Node

var _failed := false


func _ready() -> void:
	_test_declarations()
	_test_realm_attribute()
	_test_integrity()
	_test_export()
	_test_host_contract()
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
			"vrwebresource://examples/external_script.html")
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


## Явный identity page realm: атрибут realm, его согласованность и fallback к id
## первого скрипта (docs/space/scripting.md).
func _test_realm_attribute() -> void:
	var matching := VrwebScriptDeclaration.collect(HtmlParser.parse("""
<script type="application/vrweb+luau" id="a" realm="my.page">return 1</script>
<script type="application/vrweb+luau" id="b" realm="my.page">return 2</script>
"""), "")
	_eq(matching.errors.is_empty(), true, "matching explicit realms collect")
	_eq(matching.realm, "my.page", "collect reports the page realm")
	var mismatch := VrwebScriptDeclaration.collect(HtmlParser.parse("""
<script type="application/vrweb+luau" id="a" realm="one">return 1</script>
<script type="application/vrweb+luau" id="b" realm="two">return 2</script>
"""), "")
	_eq(mismatch.errors.size(), 1, "mismatching explicit realms are rejected")
	_eq(mismatch.scripts.size(), 1, "the first realm wins, the conflicting tag is skipped")
	var implicit := VrwebScriptDeclaration.collect(HtmlParser.parse(
			'<script type="application/vrweb+luau" id="solo">return 1</script>'), "")
	_eq(implicit.realm, "", "without the attribute identity falls back to the first script id")
	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	var page := Node3D.new()
	add_child(page)
	runtime.setup(page, {}, "", null, VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var activation := runtime.activate([
		{"id": "a", "realm": "my.page", "profile": VrwebScriptDeclaration.PROFILE,
			"kind": "inline", "source": "return 1", "src": "", "integrity": "", "base_url": ""},
	])
	_eq(activation.ok, true, "realm-attributed page activates")
	_eq(runtime._page_id, "my.page", "explicit realm becomes the page realm identity")
	runtime.close()
	runtime.queue_free()
	page.queue_free()


## Стандартный контракт host-вызовов: опущенные необязательные аргументы, пара `nil, code`
## при отказе и фазовый код lifecycle (docs/space/scripting-api.md).
func _test_host_contract() -> void:
	var page := Node3D.new()
	add_child(page)
	var label := Label3D.new()
	page.add_child(label)
	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	runtime.setup(page, {"lamp": label}, "vrwebresource://contract.html", null,
			VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var source := """
local results = {}
-- Опущенные необязательные аргументы: create без props, color без alpha, on без hint.
local box = document.create("Node3D")
results.created = box ~= nil
results.color_ok = document.values.color(1, 0, 0) ~= nil
local lamp = document.query("#lamp")
results.on_ok = lamp.on("activate", function() end) == true
-- Контракт ошибок: неуспех приходит парой nil, code.
local missing, missing_code = document.create("HTTPRequest")
results.err_nil = missing == nil
results.err_code = missing_code
local _, selector_code = document.query("lamp")
results.selector_code = selector_code
-- Фазовый контракт: транспортный вызов недоступен в staged top-level.
local _, phase_code = lamp.call("show")
results.phase_code = phase_code
-- Консолидация: player.set, document.shaders, players.local_player.
local _, player_code = document.player.set("position", document.values.vector3(0, 0, 0))
results.player_code = player_code
results.shaders_api = document.shaders ~= nil
	and document.features.has("vrweb/shaders/1")
	and not document.features.has("vrweb/render-shaders/1")
document.players.on_changed(function(event)
	results.me_is_local = event.local_player ~= nil and event.local_player.is_local == true
end)
document.session.results = results
"""
	var activation := runtime.activate([
		{"id": "contract.page", "profile": VrwebScriptDeclaration.PROFILE, "kind": "inline",
			"source": source, "src": "", "integrity": "", "base_url": ""},
	])
	_eq(activation.ok, true, "contract page activates (%s)" % str(activation))
	var results: Dictionary = runtime.session_of("contract.page").get("results", {})
	_eq(results.get("created"), true, "create works without the optional props argument")
	_eq(results.get("color_ok"), true, "values.color works without the optional alpha")
	_eq(results.get("on_ok"), true, "handle.on works without the optional hint")
	_eq(results.get("err_nil"), true, "a failed host call returns nil first")
	_eq(results.get("err_code"), "unsupported", "unknown create class reports code unsupported")
	_eq(results.get("selector_code"), "invalid_args", "bad selector reports invalid_args")
	_eq(results.get("phase_code"), "lifecycle", "staged transport call reports lifecycle")
	_eq(results.get("player_code"), "unsupported", "player.set without a player reports unsupported")
	_eq(results.get("shaders_api"), true, "document.shaders replaces document.render.shaders")
	_eq(results.get("me_is_local"), true, "players event carries local_player")
	runtime.close()
	runtime.queue_free()
	page.queue_free()


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
	var doc := HtmlParser.parse(FileAccess.get_file_as_string("res://addons/vrweb_tools/examples/external_script.html"))
	var collected := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://examples/external_script.html")
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
		_eq(str(result.scripts[0].source).contains("SpeedModel"), true,
				"fetcher returns source, never bytecode")
		var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
		var built := VrwebBuilder.build(doc, "vrwebresource://examples/external_script.html", policy)
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
		runtime.setup(page_root, targets, "vrwebresource://examples/external_script.html", null, policy)
		var activation := runtime.activate(result.scripts)
		_eq(activation.ok, true,
				"three modular declarations execute through the page runtime (%s)" % str(activation))
		_eq((targets.get("external-label") as Label3D).text,
				"2 LINKED FILES + 1 INLINE SCRIPT",
				"linked view mutates its VRWML target by id")
		_eq((targets.get("view-status") as Label3D).text.contains(
				"SpinnerView uses SpeedModel: 1.0x"), true,
				"second linked file uses the class declared by the first")
		var spinner := targets.get("external-spinner") as MeshInstance3D
		runtime._process(0.25)
		_eq(not spinner.position.is_equal_approx(Vector3.ZERO), true,
				"linked view animates from its private received speed")
		var button := targets.get("external-button") as StaticBody3D
		var bridge = button.get_meta(VrwebScriptInputBridge.META, null)
		_eq(bridge is VrwebScriptInputBridge and bridge.dispatch(Vector3.ZERO), true,
				"inline controller uses both linked classes")
		_eq((targets.get("model-status") as Label3D).text.contains(
				"SpeedModel instance = 2.0x"), true,
				"inline controller updates the linked SpeedModel instance")
		_eq((targets.get("view-status") as Label3D).text.contains(
				"SpinnerView uses SpeedModel: 2.0x"), true,
				"linked SpinnerView reads the same model instance")
		_eq(script_errors.is_empty(), true,
				"shared page realm composition completes without script errors")
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
