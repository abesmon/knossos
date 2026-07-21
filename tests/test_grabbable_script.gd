extends Node

## Интеграция grabbable + скриптинг: прогоняет НАСТОЯЩИЙ скрипт demo-страницы grabbable.html
## через VrwebLuauRuntime — ловит разрыв между тегом, script targets и событиями grab/use,
## включая регрессии в самой странице (напр. handle.on без опционального 3-го аргумента hint).
## Запуск: godot --headless tests/test_grabbable_script.tscn

var _failed := false


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  OK  ", what)
	else:
		_failed = true
		printerr("FAIL  ", what)


func _ready() -> void:
	await get_tree().create_timer(30.0).timeout
	if is_inside_tree():
		printerr("GRABBABLE SCRIPT TEST: WATCHDOG"); get_tree().quit(2)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	Settings.online_enabled = false
	var html := FileAccess.get_file_as_string("res://test_pages/grabbable.html")
	var doc := HtmlParser.parse(html)

	var world := Node3D.new()
	add_child(world)

	# Порядок как в main._rebuild_world: менеджер создаётся ДО добавления vrweb-узлов, чтобы
	# Grabbable._ready нашёл его в группе и сам зарегистрировался.
	var manager := GrabManager.new()
	manager.name = "GrabManager"
	world.add_child(manager)
	manager.setup(null, null)

	var built := VrwebBuilder.build(doc, "vrwebresource://grabbable.html")
	world.add_child(built["root"])
	await get_tree().process_frame

	# Собираем script targets ровно как main._build_script_targets: id узла → построенный узел
	# + суб-ресурсы страницы по их id.
	var index := SceneHtml.build_page_index(doc)
	var node_map: Dictionary = built.get("nodes", {})
	var targets := {}
	for nid in index.get("nodes", {}):
		var elem = index["nodes"][nid]["elem"]
		if node_map.has(elem):
			targets[nid] = node_map[elem]
	for rid in built.get("resources", {}):
		if not targets.has(rid):
			targets[rid] = built["resources"][rid]

	_check(targets.has("demo-ball"), "target #demo-ball разрешён (grabbable в индексе)")
	_check(targets.has("BallMaterial"), "target #BallMaterial разрешён (суб-ресурс)")
	_check(targets.has("status-label"), "target #status-label разрешён (в WorldUiCanvas)")
	var ball_node: Grabbable = targets.get("demo-ball")
	var material: StandardMaterial3D = targets.get("BallMaterial")
	_check(ball_node != null and ball_node.grab_id == "demo-ball", "target — сам Grabbable")

	# Активируем НАСТОЯЩИЙ скрипт страницы (как это делает главный runtime) — тест ловит
	# регрессии в самом demo (напр. короткая форма handle.on должна активироваться).
	var collected := VrwebScriptDeclaration.collect(doc, "vrwebresource://grabbable.html")
	_check(collected.errors.is_empty() and collected.scripts.size() == 1,
			"скрипт страницы объявлен корректно: %s" % str(collected.errors))

	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	runtime.setup(world, targets, "vrwebresource://grabbable.html", null,
			VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var activated := runtime.activate(collected.scripts)
	_check(activated.ok, "реальный скрипт страницы активирован без ошибок: %s"
			% str(activated.get("errors", [])))

	# Берём мяч и «юзаем» — через настоящий GrabManager (как ЛКМ в игре); проверяем, что
	# on("use") страницы реально сработал и сменил albedo_color материала мяча.
	var before: Color = material.albedo_color
	manager.request_grab(ball_node)
	await get_tree().process_frame
	_check(manager.local_held() == ball_node, "мяч в руке после grab")

	manager.use_held()
	await get_tree().process_frame
	_check(material.albedo_color != before,
			"use сменил albedo_color материала (%s → %s)" % [str(before), str(material.albedo_color)])

	get_tree().quit(1 if _failed else 0)
