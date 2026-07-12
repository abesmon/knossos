extends Node

var _failed := false


func _ready() -> void:
	var fetcher := PageModuleFetcher.new()
	add_child(fetcher)
	var html := FileAccess.get_file_as_string("res://test_pages/external_script.html")
	var doc := HtmlParser.parse(html)
	var collected := PageModuleCollector.collect(doc, "vrwebresource://external_script.html")
	fetcher.fetch_all(collected.modules, "vrwebresource://external_script.html", func(result):
		_eq(result.errors, [], "local same-origin script fetched")
		_eq(result.modules.size(), 1, "one artifact prepared")
		if result.modules.size() == 1:
			var module: Dictionary = result.modules[0]
			_eq(module.hash.length(), 64, "fetched artifact gets SHA-256")
			_eq(PageModuleCache.has(module.hash), true, "fetched artifact stored in cache")
			_eq(module.bytes.get_string_from_utf8().contains("return 73"), true,
					"fetched bytes preserved")
			var registry := PageModuleRegistry.new()
			var prepared := registry.prepare(result.modules, PageModuleRegistry.ScriptMode.ALLOW_ALL)
			_eq(prepared.ok, true, "verified external script compiles")
			var made := registry.instantiate_export("external.tiny", "default")
			_eq(str(made.error), "", "external export instantiates")
			if made.node != null:
				_eq(made.node.call("answer"), 73, "external page-defined method executes")
				made.node.free()
			var built := VrwebBuilder.build(doc, "vrwebresource://external_script.html", registry)
			var root: Node = built.root
			var component := root.get_node_or_null("ExternalComponent") if root != null else null
			_eq(component != null, true, "external VRWebComponent materialized")
			if component != null:
				_eq(component.call("answer"), 73, "external component behavior executes")
				_eq(component.get("marker"), "from-html", "external component attributes applied")
			if root != null:
				root.free()
		finish.call_deferred())


func finish() -> void:
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
