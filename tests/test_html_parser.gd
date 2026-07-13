extends SceneTree

## Хедлесс-проверка базовой нормализации HTML-парсера.
## Запуск: godot --headless --path . --script res://tests/test_html_parser.gd


func _initialize() -> void:
	var ok := true

	var html := "<h1>&#10038; scenemime&apos;s home &#x2736;</h1>"
	var doc := HtmlParser.parse(html)
	var h1 := doc.find_descendant("h1")
	ok = _check(h1 != null, "h1 parsed") and ok
	if h1 != null:
		ok = _check(h1.collect_text() == "✶ scenemime's home ✶", "numeric entities decode to Unicode text") and ok

	var attr_doc := HtmlParser.parse("<a title=\"&#10038; &amp; &#x2736;\">x</a>")
	var script_doc := HtmlParser.parse("<script type=\"application/vrweb+gdscript\">\nextends Node\nvar x = 1 < 2\n</script>")
	var script := script_doc.find_descendant("script")
	ok = _check(script != null and script.collect_text().contains("var x = 1 < 2"),
			"script raw-text сохраняется для inline scripting modules") and ok
	var a := attr_doc.find_descendant("a")
	ok = _check(a != null, "a parsed") and ok
	if a != null:
		ok = _check(a.get_attr("title") == "✶ & ✶", "numeric entities decode in attributes") and ok

	print("\n=== ", ("ALL PASSED" if ok else "FAILURES ABOVE"), " ===")
	quit(0 if ok else 1)


func _check(cond: bool, label: String) -> bool:
	print(("  [ok]  " if cond else "  [FAIL] "), label)
	return cond
