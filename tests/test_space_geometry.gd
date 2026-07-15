extends SceneTree

## Хедлесс-проверка 3D-геометрии из единого генератора пространства (SpaceLayout ->
## WorldGenerator). Строит мир из нескольких страниц и проверяет инварианты:
##   - сборка доходит до build_complete, не падает;
##   - на каждую комнату есть holder Room_*, у него полы (StaticBody3D) и стены;
##   - футпринты комнат не пересекаются между собой (SpaceLayout), у не-корня есть вход;
##   - spawn_point стоит над первой route-клеткой «верхней» комнаты (мин. doc_order), если route есть.
## Запуск: godot --headless --path . --script res://tests/test_space_geometry.gd

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
  <footer><p>подвал страницы</p></footer>
</body></html>
"""

const SMALL := "<html><body><div><p>только текст</p><p>и ещё немного</p></div></body></html>"
const DENSE := """
<html><body>
  <button>A</button><button>B</button><button>C</button><button>D</button>
  <button>E</button><button>F</button><button>G</button><button>H</button>
</body></html>
"""
const DENSE_IMAGES := """
<html><body>
  <img src="a.png" alt="A"><img src="b.png" alt="B"><img src="c.png" alt="C"><img src="d.png" alt="D">
  <img src="e.png" alt="E"><img src="f.png" alt="F">
</body></html>
"""

var _cases := [["RICH", RICH], ["SMALL", SMALL], ["DENSE", DENSE], ["DENSE_IMAGES", DENSE_IMAGES]]
var _ci := 0
var _holder: Node3D
var _gen
var _fail := 0


func _initialize() -> void:
	_start_case()


func _process(_delta: float) -> bool:
	if _gen == null:
		return false
	if not _gen.build_complete:
		return false
	_check_case(_cases[_ci][0])
	_holder.queue_free()
	_ci += 1
	if _ci >= _cases.size():
		print("\n==== РЕЗУЛЬТАТ: %s ====" % ("OK" if _fail == 0 else "%d ПРОВАЛОВ" % _fail))
		quit(1 if _fail > 0 else 0)
		return true
	_gen = null
	call_deferred("_start_case")
	return false


func _start_case() -> void:
	var name: String = _cases[_ci][0]
	var html: String = _cases[_ci][1]
	var space := TopologyBuilder.build(HtmlParser.parse(html), true)
	_holder = Node3D.new()
	get_root().add_child(_holder)
	var noop := func(_t): pass
	print("\n========== %s ==========" % name)
	_gen = WorldGenerator.generate(space, _holder, int(hash(name)), noop)


func _check_case(name: String) -> void:
	var layout: Dictionary = _gen._layout
	var rooms: Dictionary = layout.get("rooms", {})
	var root_id: int = layout.get("root", -1)

	# 1. Футпринты не пересекаются.
	var owner := {}
	var overlap := 0
	for id in rooms:
		for c in _gen._foot_cells[id]:
			if owner.has(c):
				overlap += 1
			owner[c] = id
	_expect(name, "футпринты без пересечений", overlap == 0, "пересечений: %d" % overlap)

	# 2. Узлы Room_* и их содержимое.
	var room_holders := 0
	var bodies := 0
	for child in _holder.get_child(0).get_children():   # get_child(0) = контейнер Generated
		if not str(child.name).begins_with("Room_"):
			continue
		room_holders += 1
		bodies += _count_bodies(child)
	_expect(name, "построены все комнаты", room_holders == rooms.size(),
		"holders=%d rooms=%d" % [room_holders, rooms.size()])
	_expect(name, "есть коллизии полов/стен", bodies > 0, "bodies=%d" % bodies)

	# 3. У каждой не-корневой комнаты есть вход (дверь) — иначе изолирована.
	var no_entrance: Array = []
	for id in rooms:
		if id == root_id:
			continue
		if not _gen._room_entrance.has(id) and _gen._door_edges.get(id, {}).is_empty():
			no_entrance.append(id)
	# Изолированными могут оказаться только связи, помеченные unrouted в SpaceLayout.
	var unrouted := 0
	for co in layout.get("corridors", []):
		if co.get("unrouted", false):
			unrouted += 1
	_expect(name, "входы у комнат (вне unrouted)", no_entrance.size() <= unrouted,
		"без входа: %s, unrouted=%d" % [str(no_entrance), unrouted])

	# 4. У коридоров есть стены на открытых краях (не к комнате/коридору), и проходы в комнаты
	#    остаются открытыми (на клетку-комнату стену коридор не ставит).
	var expected_walls := 0
	for cell in _gen._corr_cells:
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cell + d
			if not _gen._corr_cells.has(nb) and not _gen._room_occ.has(nb):
				expected_walls += 1
	var corr_bodies := 0
	for child in _holder.get_child(0).get_children():
		if str(child.name).begins_with("Room_") or not (child is Node3D):
			continue
		corr_bodies += _count_bodies(child)
	# corr_bodies = пол (1) + стены на каждую коридорную клетку.
	var corr_walls: int = corr_bodies - int(_gen._corr_cells.size())
	_expect(name, "стены у дорожек", corr_walls == expected_walls,
		"стен=%d ожидалось=%d" % [corr_walls, expected_walls])

	# 4b. Слоты объектов: внутри футпринта, без дублей по ребру, есть для комнат с объектами.
	var bad_slots := 0
	var empty_with_objs := 0
	var non_virtual_slots := 0
	for id in rooms:
		if rooms[id].get("objects", []).is_empty():
			continue
		var slots: Array = _gen._object_slots(id)
		var from_virtual := not slots.is_empty()
		if slots.is_empty():
			slots = _gen._fallback_slots(id)
		var virtual_edges := {}
		for wall in rooms[id].get("virtual_walls", []):
			var wc: Vector2i = wall["cell"]
			var wd: Vector2i = wall["dir"]
			virtual_edges["%d,%d:%d,%d" % [wc.x, wc.y, wd.x, wd.y]] = true
		var seen := {}
		for s in slots:
			var sc: Vector2i = s["cell"]
			var pull: Vector2i = s["pull"]
			var key := "%d,%d:%d,%d" % [sc.x, sc.y, pull.x, pull.y]
			if not owner.has(sc) or seen.has(key):
				bad_slots += 1
			if from_virtual and not virtual_edges.has(key):
				non_virtual_slots += 1
			seen[key] = true
		if slots.is_empty():
			empty_with_objs += 1
	_expect(name, "слоты в футпринте, без дублей по ребру", bad_slots == 0,
		"плохих слотов: %d" % bad_slots)
	_expect(name, "основные слоты стоят на виртуальных стенах", non_virtual_slots == 0,
		"слотов вне виртуальных стен: %d" % non_virtual_slots)
	_expect(name, "слоты есть у комнат с объектами", empty_with_objs == 0,
		"комнат без слотов: %d" % empty_with_objs)

	# 4c. Новая развёртка: каждый объект имеет placement в валидном wall-box или fallback slot.
	var missing_placements := 0
	var bad_placements := 0
	var below_floor_offset := 0
	for id in rooms:
		var placements: Dictionary = _gen._object_placements.get(id, {})
		var boxes: Array = _gen._wall_boxes.get(id, [])
		for obj in rooms[id].get("objects", []):
			if not placements.has(obj["id"]):
				missing_placements += 1
				continue
			var p: Dictionary = placements[obj["id"]]
			if p.has("box"):
				var bi: int = int(p["box"])
				if bi < 0 or bi >= boxes.size():
					bad_placements += 1
					continue
				if float(p.get("along", -1.0)) < 0.0 or float(p.get("along", 0.0)) > float(boxes[bi].get("length", 0.0)):
					bad_placements += 1
			elif p.has("slot"):
				var slot: Dictionary = p["slot"]
				if not owner.has(slot["cell"]):
					bad_placements += 1
			else:
				bad_placements += 1
			if WorldGenerator.OBJECT_FLOOR_OFFSET + float(p.get("y", 0.0)) < WorldGenerator.OBJECT_FLOOR_OFFSET:
				below_floor_offset += 1
	_expect(name, "объекты имеют placement на развёртке", missing_placements == 0,
		"объектов без placement: %d" % missing_placements)
	_expect(name, "placements валидны", bad_placements == 0,
		"плохих placements: %d" % bad_placements)
	_expect(name, "placements подняты над полом", below_floor_offset == 0,
		"placements ниже offset: %d" % below_floor_offset)
	if name == "DENSE" or name == "DENSE_IMAGES":
		var compact_widths := 0
		var row_counts := {}
		for obj_id in _gen._object_size:
			var sz: Vector2 = _gen._object_size[obj_id]
			if sz.x <= 1.25:
				compact_widths += 1
		for id in rooms:
			for obj_id in _gen._object_placements.get(id, {}):
				var p: Dictionary = _gen._object_placements[id][obj_id]
				if not p.has("box"):
					continue
				var key := "%d:%d:%.2f" % [id, int(p["box"]), float(p["y"])]
				row_counts[key] = int(row_counts.get(key, 0)) + 1
		var max_row := 0
		for key in row_counts:
			max_row = maxi(max_row, int(row_counts[key]))
		_expect(name, "малые объекты имеют компактный футпринт", compact_widths >= 6,
			"компактных объектов: %d" % compact_widths)
		_expect(name, "жадная упаковка кладёт несколько объектов в один ряд", max_row >= 2,
			"максимум объектов в ряду: %d" % max_row)

	# 4d. Объекты не перекрывают проходы: ни один слот не стоит на клетке-двери и не притянут
	#     к ребру-двери.
	var blocking := 0
	for id in rooms:
		var dcells: Dictionary = _gen._door_cells.get(id, {})
		var dedges: Dictionary = _gen._door_edges.get(id, {})
		for obj_id in _gen._object_placements.get(id, {}):
			var p: Dictionary = _gen._object_placements[id][obj_id]
			var cells: Array = []
			var pull: Vector2i = p["pull"]
			if p.has("box"):
				var boxes: Array = _gen._wall_boxes.get(id, [])
				var bi: int = int(p["box"])
				if bi >= 0 and bi < boxes.size():
					cells = boxes[bi].get("cells", [])
			elif p.has("slot"):
				cells = [p["slot"]["cell"]]
			for sc in cells:
				if dcells.has(sc):
					blocking += 1
					continue
				# Стена со стороны притяжения (и ±1 клетка вдоль неё) не должна нести двери —
				# иначе объект встанет в проёме или нависнет над ним.
				var along := Vector2i(pull.y, -pull.x)
				for k in [-1, 0, 1]:
					var wc: Vector2i = sc + along * k
					if dedges.has("%d,%d:%d,%d" % [wc.x, wc.y, pull.x, pull.y]):
						blocking += 1
	_expect(name, "объекты не перекрывают проходы", blocking == 0, "перекрытий: %d" % blocking)

	# 5. Спавн над клеткой пола.
	var sp: Vector3 = _gen.spawn_point
	var cell := Vector2i(int(floor((sp.x - _gen._shift.x) / WorldGenerator.GRID)),
		int(floor((sp.z - _gen._shift.z) / WorldGenerator.GRID)))
	var on_floor: bool = owner.has(cell) or _gen._corr_cells.has(cell)
	_expect(name, "спавн над полом", on_floor, "spawn=%s cell=%s" % [str(sp), str(cell)])
	# Спавн — на первой route-клетке «верхней» комнаты (мин. doc_order среди листьев с
	# наполнением), а не обязательно root: см. WorldGenerator._find_spawn_room_id.
	var target_id: int = _gen._spawn_target_id if _gen._spawn_target_id != -1 else root_id
	var target_routes: Array = rooms.get(target_id, {}).get("routes", [])
	if not target_routes.is_empty() and not target_routes[0].is_empty():
		var route_cell: Vector2i = target_routes[0][0]
		_expect(name, "спавн на первой route-клетке верхней комнаты", cell == route_cell,
			"spawn_cell=%s route_cell=%s target=%d" % [str(cell), str(route_cell), target_id])

	print("  rooms=%d corridors=%d unrouted=%d holders=%d bodies=%d" %
		[rooms.size(), layout.get("corridors", []).size(), unrouted, room_holders, bodies])


func _count_bodies(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c is StaticBody3D:
			n += 1
		n += _count_bodies(c)
	return n


func _expect(case_name: String, what: String, ok: bool, detail: String) -> void:
	if ok:
		print("  ✓ [%s] %s" % [case_name, what])
	else:
		_fail += 1
		print("  ✗ [%s] %s — %s" % [case_name, what, detail])
