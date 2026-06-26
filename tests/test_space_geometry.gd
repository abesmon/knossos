extends SceneTree

## Хедлесс-проверка 3D-геометрии из единого генератора пространства (SpaceLayout ->
## WorldGenerator). Строит мир из нескольких страниц и проверяет инварианты:
##   - сборка доходит до build_complete, не падает;
##   - на каждую комнату есть holder Room_*, у него полы (StaticBody3D) и стены;
##   - футпринты комнат не пересекаются между собой (SpaceLayout), у не-корня есть вход;
##   - spawn_point стоит над какой-то клеткой пола.
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

var _cases := [["RICH", RICH], ["SMALL", SMALL]]
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

	# 4c. Объекты не перекрывают проходы: ни один слот не стоит на клетке-двери и не притянут
	#     к ребру-двери.
	var blocking := 0
	for id in rooms:
		var dcells: Dictionary = _gen._door_cells.get(id, {})
		var dedges: Dictionary = _gen._door_edges.get(id, {})
		var slots: Array = _gen._object_slots(id)
		if slots.is_empty():
			slots = _gen._fallback_slots(id)
		for s in slots:
			var sc: Vector2i = s["cell"]
			var pull: Vector2i = s["pull"]
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
		print("  ✓ %s" % what)
	else:
		_fail += 1
		print("  ✗ %s — %s" % [what, detail])
