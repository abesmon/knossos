extends SceneTree

## Временный диагностический скрипт: печатает виртуальные стены (боксы развёртки) и упаковку
## объектов по комнатам. Запуск:
##   godot --headless --path . --script res://tests/debug_wall_boxes.gd

const RICH := """
<html><body style="background-color:#1a2030">
  <header><h1>Главная</h1></header>
  <main>
    <section>
      <h2>Раздел про картинки</h2>
      <p>Первый абзац с достаточно длинным текстом, чтобы получить богатую панель в комнате.</p>
      <img src="a.png" alt="картинка А" width="400" height="300">
      <p>Второй абзац.</p>
      <a href="/next">Перейти дальше</a>
      <img src="b.png" alt="картинка Б">
      <ul><li>пункт один</li><li>пункт два</li><li>пункт три</li></ul>
    </section>
    <section>
      <h2>Второй раздел</h2>
      <p>Текст второго раздела.</p>
      <blockquote>цитата</blockquote>
      <pre>code block</pre>
      <table><tr><td>a</td><td>b</td></tr></table>
    </section>
  </main>
</body></html>
"""

var _holder: Node3D
var _gen


func _initialize() -> void:
	var space := TopologyBuilder.build(HtmlParser.parse(RICH), true)
	_holder = Node3D.new()
	get_root().add_child(_holder)
	_gen = WorldGenerator.generate(space, _holder, 12345, func(_t): pass)


func _process(_delta: float) -> bool:
	if _gen == null or not _gen.build_complete:
		return false
	var rooms: Dictionary = _gen._layout.get("rooms", {})
	for id in rooms:
		var room: Dictionary = _gen._rooms[id]
		var objs: Array = room.get("objects", [])
		var routes: Array = _gen._layout["rooms"][id].get("routes", [])
		print("\n=== room %d  kind=%s  cells=%d  objs=%d  routes=%d ===" %
			[id, room.get("kind", "?"), _gen._foot_cells[id].size(), objs.size(), routes.size()])
		for ri in routes.size():
			print("  route %d: %s" % [ri, str(routes[ri])])
		var boxes: Array = _gen._wall_boxes(id)
		print("  БОКСОВ: %d" % boxes.size())
		for b in boxes:
			print("    dir=%s  cells=%d  len=%.1fм  usable=%.1fм  %s" %
				[str(b["dir"]), b["cells"].size(), b["len"], b["len"] - 0.6, str(b["cells"])])
		# Размеры объектов
		for o in objs:
			var sz: Vector2 = _gen._object_size.get(o["id"], Vector2.ZERO)
			print("    obj %d type=%s  %.2f x %.2f м" % [o["id"], o.get("type", "?"), sz.x, sz.y])
		var plan: Dictionary = _gen._plan_objects(id, objs)
		if plan.has("placements"):
			print("  РАЗМЕЩЕНО: %d, высота стен %.1fм" % [plan["placements"].size(), plan["height"]])
			for p in plan["placements"]:
				var lp: Vector3 = p["local_pos"]
				print("    obj %d -> y=%.2f  pos=(%.1f, %.1f, %.1f)" %
					[p["obj"]["id"], lp.y, lp.x, lp.y, lp.z])
		else:
			print("  FALLBACK (нет боксов)")
	quit(0)
	return true
