extends Node

var _failed := false


func _ready() -> void:
	var fetcher := ScriptingModuleFetcher.new()
	add_child(fetcher)
	var html := FileAccess.get_file_as_string(
			"res://tests/fixtures/wasm_delivery/declaration_only.html")
	var doc := HtmlParser.parse(html)
	var page_url := "vrweblocal://" + ProjectSettings.globalize_path(
			"res://tests/fixtures/wasm_delivery/declaration_only.html")
	var collected := ScriptingModuleCollector.collect(doc, page_url)
	fetcher.fetch_all(collected.modules, page_url, func(result):
		_eq(result.errors, [], "local same-origin WASM package fetched")
		_eq(result.modules.size(), 1, "one artifact prepared")
		if result.modules.size() == 1:
			var module: Dictionary = result.modules[0]
			_eq(module.hash.length(), 64, "fetched artifact gets SHA-256")
			_eq(ScriptingModuleCache.has(module.hash), true, "fetched artifact stored in cache")
			_eq(module.bytes.size() > 100, true, "fetched package bytes preserved")
			var registry := ScriptingModuleRegistry.new(UnavailableWasmBackend.new())
			var prepared := registry.prepare(result.modules)
			_eq(prepared.ok, false, "missing WASM backend is reported")
			_eq(str(prepared.errors[0]).contains("WASM runtime unavailable"), true,
					"runtime error is explicit")
		finish.call_deferred())


func finish() -> void:
	get_tree().quit(1 if _failed else 0)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
