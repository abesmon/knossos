extends SceneTree

## Хедлесс-проверка пайплайна HTML -> дерево -> топология (без 3D).
## Запуск: godot --headless --path . --script res://tests/test_topology.gd

const SAMPLE := """
<!DOCTYPE html>
<html>
<head><title>Demo</title><style>.x{color:red}</style></head>
<body>
  <header><h1 id="top">Главная</h1></header>
  <main>
    <section style="background-color:#223344">
      <h2>Статьи</h2>
      <p id="mwFw">В центре сюжета история молодого писателя (как позже выяснилось, — <a href="//ru.wikipedia.org/wiki/Интерсекс">интерсекс-человека</a>), который вернулся назад во времени и обманом <a href="//ru.wikipedia.org/wiki/Оплодотворение">оплодотворил</a> свою женскую версию<sup><a href="#top">[6]</a></sup>.</p>
      <img src="cat.png" alt="кот">
      <a href="/about">О нас</a>
    </section>
    <section>
      <h2>Ссылки</h2>
      <ul>
        <li><a href="https://example.com">Внешний</a></li>
        <li><a href="#top">Наверх</a></li>
      </ul>
    </section>
  </main>
  <footer><p>Подвал</p></footer>
</body>
</html>
"""


func _initialize() -> void:
	var doc := HtmlParser.parse(SAMPLE)
	print("=== Parsed tree (depth, tag, text) ===")
	_dump(doc, 0)

	var space := TopologyBuilder.build(doc)
	print("\n=== Topology artifact ===")
	print("root: ", space["root"], "  rooms: ", space["rooms"].size(), "  labels: ", space["labels"])
	for id in space["rooms"].keys():
		var r: Dictionary = space["rooms"][id]
		var obj_types: Array = []
		for o in r["objects"]:
			var fn = o.get("function", null)
			obj_types.append(o["type"] + ("[" + str(fn.get("kind")) + "]" if fn else ""))
		print("  room %d  kind=%s  children=%s  objects=%s  hints=%s" % [
			id, r["kind"], str(r["children"]), str(obj_types), str(r["hints"])])

	print("\n=== text objects: runs ===")
	for id in space["rooms"].keys():
		for o in space["rooms"][id]["objects"]:
			if o["type"] == "text":
				print("  obj %d content keys=%s runs=%s" % [o["id"], str(o["content"].keys()), str(o["content"].get("runs", "—"))])

	print("\n=== JSON roundtrip (serializable check) ===")
	var json := JSON.stringify(space, "  ")
	print("bytes: ", json.length())

	print("\n=== Geometry phase (build into Node3D) ===")
	_holder = Node3D.new()
	get_root().add_child(_holder)
	var noop := func(_t): pass
	_gen = WorldGenerator.generate(space, _holder, int(hash("test")), noop)
	print("nodes built: ", _count_nodes(_holder))
	print("spawn_point: ", _gen.spawn_point)
	print("label_positions: ", _gen.label_positions)
	# Проверки, зависящие от _ready (группы, bbcode), делаем после первого кадра.


var _holder: Node3D
var _gen
var _frame := 0


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 2:
		return false
	var panels := get_nodes_in_group("rich_panel")
	print("\n=== After frame: RichPanels (абзацы с inline-ссылками): ", panels.size(), " ===")
	for rp in panels:
		print("  runs=", rp._runs.size(), " links=", rp._metas.size(),
			" h_px=", rp._h_px, " bbcode=", rp._bbcode.substr(0, 140))
	_holder.queue_free()
	return true


func _count_nodes(n: Node) -> int:
	var total := 1
	for c in n.get_children():
		total += _count_nodes(c)
	return total


func _dump(node: HtmlNode, depth: int) -> void:
	var pad := "  ".repeat(depth)
	if node.is_text():
		print(pad, "#text: ", node.text.substr(0, 40))
	else:
		var attrs := "" if node.attributes.is_empty() else " " + str(node.attributes)
		print(pad, "<", node.tag, ">", attrs)
	for c in node.children:
		_dump(c, depth + 1)
