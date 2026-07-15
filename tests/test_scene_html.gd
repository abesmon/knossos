extends SceneTree

## Юнит-тест SceneHtml — HTML-представления эфемерного слоя (сериализация, разбор, дифф
## в действия протокола) без сети и 3D. Запуск:
##   godot --headless --path . --script res://tests/test_scene_html.gd
## Выход 0 — все проверки прошли, иначе 1.

var _failed := false


func _initialize() -> void:
	_test_roundtrip_no_changes()
	_test_nesting_roundtrip()
	_test_add_new_element()
	_test_update_props_patch()
	_test_remove_with_cascade()
	_test_reparent_by_nesting()
	_test_kind_and_ttl_guards()
	_test_escaping_roundtrip()
	_test_page_anchor_attr()
	_test_duplicate_id_rejected()
	_test_scene_index_ids()
	_test_scene_merge_and_flush()
	_test_scene_roundtrip_no_changes()
	_test_scene_patch_page_attr()
	_test_scene_patch_back_to_base()
	_test_scene_tombstone_page_node()
	_test_scene_add_vrweb_node()
	_test_scene_add_world_kind()
	_test_scene_guards()
	quit(1 if _failed else 0)


# ============================================================================
#  Единый документ сцены (слитый <vrwml> + дельта-оверлей)
# ============================================================================

const PAGE_VRWEB := """
<vrwml>
  <MeshInstance3D id="box" transform="Transform3D(1,0,0, 0,1,0, 0,0,1, 0,0.5,0)" mesh="SubResource:::M1">
    <StaticBody3D />
  </MeshInstance3D>
  <Resource id="M1" type="BoxMesh" size="Vector3(2,1,3)" />
</vrwml>
"""


func _page_index() -> Dictionary:
	return SceneHtml.build_page_index(HtmlParser.parse(PAGE_VRWEB))


## Детерминированные id: авторский атрибут id — как есть, без id — структурный "n<путь>".
func _test_scene_index_ids() -> void:
	var index := _page_index()
	_ok(index["found"], "блок найден")
	_ok(index["nodes"].has("box"), "авторский id взят как есть")
	_ok(index["nodes"].has("n0-0"), "безымянный ребёнок получил структурный id")
	_ok(index["nodes"].has("M1"), "ресурс адресуем своим id")
	_eq(str(index["nodes"]["n0-0"]["parent"]), "box", "родитель ребёнка — box")


## Слияние: патч применён к атрибутам, tombstone скрывает узел, флаг include_world.
func _test_scene_merge_and_flush() -> void:
	var index := _page_index()
	var objects := {
		"vpatch:box": {"id": "vpatch:box", "kind": "vrweb-patch", "parent": "", "author": "a",
			"ts": 1.0, "ttl": 0.0, "props": {"set": {"visible": "false"}}},
		"u1.7": {"id": "u1.7", "kind": "bubble", "parent": "", "author": "a", "ts": 2.0,
			"ttl": 30.0, "props": {"url": "u"}},
	}
	var merged := SceneHtml.serialize_scene(index, objects)
	_ok(merged.find("visible=\"false\"") != -1, "патч слит в атрибуты узла")
	_ok(merged.find("<bubble") != -1, "мировой объект в слитом документе")
	var flush := SceneHtml.serialize_scene(index, objects, false)
	_ok(flush.find("<bubble") == -1, "флаш без мировых объектов")
	# Tombstone: узел и его поддерево скрыты.
	objects["vpatch:box"]["props"] = {"set": {}, "removed": true}
	var without := SceneHtml.serialize_scene(index, objects)
	_ok(without.find("MeshInstance3D") == -1, "затомбстоненный узел скрыт")
	_ok(without.find("StaticBody3D") == -1, "его поддерево скрыто")


## Слитый документ без правок диффается в ноль действий.
func _test_scene_roundtrip_no_changes() -> void:
	var index := _page_index()
	var objects := {
		"u1.8": {"id": "u1.8", "kind": "vrweb-node", "parent": "page:box", "author": "a",
			"ts": 1.0, "ttl": 0.0, "props": {"tag": "OmniLight3D", "attrs": {"light_energy": "2.0"}}},
		"u1.9": {"id": "u1.9", "kind": "bubble", "parent": "", "author": "a", "ts": 2.0,
			"ttl": 30.0, "props": {"url": "u", "position": [1.0, 2.0, 3.0]}},
	}
	var merged := SceneHtml.serialize_scene(index, objects)
	var parsed := SceneHtml.parse_scene(HtmlParser.parse(merged))
	_ok(parsed["ok"], "разбор слитого без ошибок (%s)" % parsed["error"])
	var d := SceneHtml.diff_scene(index, objects, parsed, func(): return "gen.1")
	_ok(d["ok"], "дифф слитого без ошибок (%s)" % d["error"])
	_eq(d["actions"].size(), 0, "слитый round-trip без правок → ноль действий")


## Правка атрибута узла страницы → add vpatch с оверрайдом (только дельта).
func _test_scene_patch_page_attr() -> void:
	var index := _page_index()
	var merged := SceneHtml.serialize_scene(index, {})
	var edited := merged.replace("Vector3(2,1,3)", "Vector3(9,1,3)")
	var parsed := SceneHtml.parse_scene(HtmlParser.parse(edited))
	var d := SceneHtml.diff_scene(index, {}, parsed, func(): return "gen.1")
	_eq(d["actions"].size(), 1, "одно действие")
	var a: Dictionary = d["actions"][0]
	_eq(str(a["op"]), "add", "op=add (патча ещё не было)")
	_eq(str(a["id"]), "vpatch:M1", "детерминированный id патча")
	_eq(str(a["kind"]), "vrweb-patch", "kind=vrweb-patch")
	_eq(str(a["props"]["set"]["size"]), "Vector3(9,1,3)", "оверрайд только изменённого атрибута")


## Возврат патченного атрибута к базе → патч снимается (remove), а не пустеет.
func _test_scene_patch_back_to_base() -> void:
	var index := _page_index()
	var objects := {
		"vpatch:M1": {"id": "vpatch:M1", "kind": "vrweb-patch", "parent": "", "author": "a",
			"ts": 1.0, "ttl": 0.0, "props": {"set": {"size": "Vector3(9,1,3)"}}},
	}
	# Правим слитый вид обратно к базовому значению.
	var edited := SceneHtml.serialize_scene(index, objects).replace("Vector3(9,1,3)", "Vector3(2,1,3)")
	var parsed := SceneHtml.parse_scene(HtmlParser.parse(edited))
	var d := SceneHtml.diff_scene(index, objects, parsed, func(): return "gen.1")
	_eq(d["actions"].size(), 1, "одно действие")
	_eq(str(d["actions"][0]["op"]), "remove", "оверрайдов не осталось → патч снимается")
	_eq(str(d["actions"][0]["id"]), "vpatch:M1", "снимается именно патч")


## Удаление узла страницы из слитого вида → tombstone-патч; поддерево отдельно не тромбстонится.
func _test_scene_tombstone_page_node() -> void:
	var index := _page_index()
	var merged := SceneHtml.serialize_scene(index, {})
	# Убираем узел box целиком (вместе с ребёнком): от "<MeshInstance3D" до "</MeshInstance3D>".
	var start := merged.find("<MeshInstance3D")
	var end := merged.find("</MeshInstance3D>") + "</MeshInstance3D>".length()
	var edited := merged.substr(0, start) + merged.substr(end)
	var parsed := SceneHtml.parse_scene(HtmlParser.parse(edited))
	var d := SceneHtml.diff_scene(index, {}, parsed, func(): return "gen.1")
	_eq(d["actions"].size(), 1, "один tombstone (ребёнок под родительским)")
	var a: Dictionary = d["actions"][0]
	_eq(str(a["id"]), "vpatch:box", "tombstone верхнего узла")
	_ok(a["props"].get("removed", false), "removed=true")


## Новый PascalCase-элемент внутри узла страницы → add vrweb-node с parent="page:<узел>".
func _test_scene_add_vrweb_node() -> void:
	var index := _page_index()
	var merged := SceneHtml.serialize_scene(index, {})
	var edited := merged.replace("<StaticBody3D id=\"n0-0\" />",
		"<StaticBody3D id=\"n0-0\" /><OmniLight3D light_energy=\"2.0\" />")
	var parsed := SceneHtml.parse_scene(HtmlParser.parse(edited))
	var d := SceneHtml.diff_scene(index, {}, parsed, func(): return "gen.1")
	_eq(d["actions"].size(), 1, "одно действие")
	var a: Dictionary = d["actions"][0]
	_eq(str(a["op"]), "add", "op=add")
	_eq(str(a["kind"]), "vrweb-node", "PascalCase → узел сцены")
	_eq(str(a["parent"]), "page:box", "родитель — якорь узла страницы")
	_eq(str(a["props"]["tag"]), "OmniLight3D", "класс из тега")
	_eq(str(a["props"]["attrs"]["light_energy"]), "2.0", "атрибуты сырыми строками")


## Новый lowercase-элемент → мировой kind (как в блоке <ephemeral>).
func _test_scene_add_world_kind() -> void:
	var index := _page_index()
	var merged := SceneHtml.serialize_scene(index, {})
	var edited := merged.replace("</vrwml>", "  <bubble ttl=\"15\" url=\"u\" position=\"0 1 0\" />\n</vrwml>")
	var parsed := SceneHtml.parse_scene(HtmlParser.parse(edited))
	var d := SceneHtml.diff_scene(index, {}, parsed, func(): return "gen.9")
	_eq(d["actions"].size(), 1, "одно действие")
	var a: Dictionary = d["actions"][0]
	_eq(str(a["kind"]), "bubble", "lowercase → мировой kind")
	_eq(str(a["id"]), "gen.9", "id сгенерирован")
	_eq((a["props"]["position"] as Array).size(), 3, "props типизированы")


## Запреты: перемещение узла страницы, удаление базового атрибута, смена класса.
func _test_scene_guards() -> void:
	var index := _page_index()
	var merged := SceneHtml.serialize_scene(index, {})
	# Удаление базового атрибута.
	var no_attr := merged.replace(" size=\"Vector3(2,1,3)\"", "")
	var d := SceneHtml.diff_scene(index, {}, SceneHtml.parse_scene(HtmlParser.parse(no_attr)), func(): return "g")
	_ok(not d["ok"], "удаление базового атрибута → ошибка")
	# Смена класса узла страницы.
	var re_class := merged.replace("<StaticBody3D id=\"n0-0\" />", "<RigidBody3D id=\"n0-0\" />")
	d = SceneHtml.diff_scene(index, {}, SceneHtml.parse_scene(HtmlParser.parse(re_class)), func(): return "g")
	_ok(not d["ok"], "смена класса узла страницы → ошибка")
	# Правка атрибутов самого блока <vrwml>.
	var re_block := merged.replace("<vrwml>", "<vrwml mode=\"exclusive\">")
	d = SceneHtml.diff_scene(index, {}, SceneHtml.parse_scene(HtmlParser.parse(re_block)), func(): return "g")
	_ok(not d["ok"], "правка атрибутов блока → ошибка")


## Снимок состояния для большинства тестов: пузырь + штрих в корне.
func _objects() -> Dictionary:
	return {
		"u1.1": {"id": "u1.1", "kind": "bubble", "parent": "", "author": "alice", "ts": 100.0,
			"ttl": 30.0, "props": {"url": "https://a.example/x", "position": [1.0, 1.6, 5.0], "label": "Вася"}},
		"u1.2": {"id": "u1.2", "kind": "stroke", "parent": "", "author": "alice", "ts": 101.0,
			"ttl": 0.0, "props": {"points": [0.0, 1.0, 0.0, 0.5, 1.2, 0.1], "color": [1.0, 0.0, 0.0], "width": 0.02}},
	}


## serialize -> parse -> diff того же состояния = ноль действий (нет фантомных правок
## от форматирования float).
func _test_roundtrip_no_changes() -> void:
	var objects := _objects()
	var html := SceneHtml.serialize(objects)
	var parsed := SceneHtml.parse_block(HtmlParser.parse(html))
	_ok(parsed["ok"], "round-trip: разбор без ошибок (%s)" % parsed["error"])
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "new.1")
	_ok(d["ok"], "round-trip: дифф без ошибок")
	_eq(d["actions"].size(), 0, "round-trip без правок → ноль действий")


## Вложенность элементов = parent-дерево объектов, и обратно.
func _test_nesting_roundtrip() -> void:
	var objects := _objects()
	objects["u1.3"] = {"id": "u1.3", "kind": "bubble", "parent": "u1.1", "author": "alice",
		"ts": 102.0, "ttl": 20.0, "props": {"url": "u", "label": "child"}}
	var html := SceneHtml.serialize(objects)
	_ok(html.find("</bubble>") != -1, "родитель с ребёнком сериализуется парным тегом")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(html))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "new.1")
	_eq(d["actions"].size(), 0, "вложенность восстановилась — ноль действий")


## Новый элемент без id → add со сгенерированным id; с рукописным id → add с ним.
func _test_add_new_element() -> void:
	var objects := _objects()
	var html := SceneHtml.serialize(objects)
	html = html.replace("</ephemeral>",
		"  <bubble url=\"https://b.example\" position=\"0 1 0\" label=\"нов\" ttl=\"15\" />\n</ephemeral>")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(html))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_eq(d["actions"].size(), 1, "одно действие")
	var a: Dictionary = d["actions"][0]
	_eq(str(a["op"]), "add", "op=add")
	_eq(str(a["id"]), "gen.1", "id сгенерирован")
	_eq(str(a["kind"]), "bubble", "kind из тега")
	_eq(float(a["ttl"]), 15.0, "ttl из атрибута")
	_eq(str(a["props"]["label"]), "нов", "строковый prop")
	_eq((a["props"]["position"] as Array).size(), 3, "vec-prop разобран")


## Правка prop → update с ПАТЧЕМ (только изменённые ключи; удалённый ключ → null).
func _test_update_props_patch() -> void:
	var objects := _objects()
	var html := SceneHtml.serialize(objects)
	html = html.replace("label=\"Вася\"", "").replace("url=\"https://a.example/x\"", "url=\"https://c.example\"")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(html))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_eq(d["actions"].size(), 1, "одно действие")
	var a: Dictionary = d["actions"][0]
	_eq(str(a["op"]), "update", "op=update")
	var patch: Dictionary = a["props"]
	_eq(str(patch.get("url", "")), "https://c.example", "изменённый ключ в патче")
	_ok(patch.has("label") and patch["label"] == null, "удалённый ключ → null")
	_ok(not patch.has("position"), "нетронутый ключ не в патче")


## Удалённый элемент → remove; потомок удалённого НЕ шлёт свой remove (каскад авторитета).
func _test_remove_with_cascade() -> void:
	var objects := _objects()
	objects["u1.3"] = {"id": "u1.3", "kind": "bubble", "parent": "u1.1", "author": "alice",
		"ts": 102.0, "ttl": 20.0, "props": {"url": "u"}}
	# В правке остался только штрих: пузырь u1.1 и его ребёнок u1.3 удалены.
	var edited := "<ephemeral>%s</ephemeral>" % _element_of(objects, "u1.2")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(edited))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_eq(d["actions"].size(), 1, "один remove (ребёнок уедет каскадом)")
	_eq(str(d["actions"][0]["op"]), "remove", "op=remove")
	_eq(str(d["actions"][0]["id"]), "u1.1", "удаляется верхний")


## Перенос элемента внутрь другого → reparent.
func _test_reparent_by_nesting() -> void:
	var objects := _objects()
	var edited := "<ephemeral><bubble id=\"u1.1\" ttl=\"30\" url=\"https://a.example/x\" position=\"1 1.6 5\" label=\"Вася\">%s</bubble></ephemeral>" \
		% _element_of(objects, "u1.2")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(edited))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_eq(d["actions"].size(), 1, "одно действие")
	_eq(str(d["actions"][0]["op"]), "reparent", "op=reparent")
	_eq(str(d["actions"][0]["parent"]), "u1.1", "новый родитель")


## Смена kind существующего id и правка ttl протоколом не выражаются → ошибка, не тихий пропуск.
func _test_kind_and_ttl_guards() -> void:
	var objects := _objects()
	var kind_edit := SceneHtml.serialize(objects).replace("<bubble", "<portal").replace("</bubble>", "</portal>")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(kind_edit))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_ok(not d["ok"], "смена kind → ошибка")
	var ttl_edit := SceneHtml.serialize(objects).replace("ttl=\"30\"", "ttl=\"99\"")
	parsed = SceneHtml.parse_block(HtmlParser.parse(ttl_edit))
	d = SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_ok(not d["ok"], "правка ttl → ошибка")


## Спецсимволы в строковых props переживают round-trip (экранирование атрибутов).
func _test_escaping_roundtrip() -> void:
	var objects := {
		"u1.9": {"id": "u1.9", "kind": "bubble", "parent": "", "author": "a", "ts": 1.0,
			"ttl": 10.0, "props": {"url": "https://e.example/?a=1&b=\"q\"", "label": "<ёж> & точка"}},
	}
	var parsed := SceneHtml.parse_block(HtmlParser.parse(SceneHtml.serialize(objects)))
	_ok(parsed["ok"], "разбор экранированного без ошибок")
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_eq(d["actions"].size(), 0, "спецсимволы не породили фантомных правок")


## Якорь parent="page:…" не выражается вложенностью — атрибутом, и переживает round-trip.
func _test_page_anchor_attr() -> void:
	var objects := {
		"u1.5": {"id": "u1.5", "kind": "bubble", "parent": "page:h2-3", "author": "a", "ts": 1.0,
			"ttl": 10.0, "props": {"url": "u"}},
	}
	var html := SceneHtml.serialize(objects)
	_ok(html.find("parent=\"page:h2-3\"") != -1, "якорь сериализован атрибутом")
	var parsed := SceneHtml.parse_block(HtmlParser.parse(html))
	var d := SceneHtml.diff(objects, parsed["entries"], func(): return "gen.1")
	_eq(d["actions"].size(), 0, "якорь восстановился — ноль действий")


func _test_duplicate_id_rejected() -> void:
	var html := "<ephemeral><bubble id=\"x\" url=\"u\" /><bubble id=\"x\" url=\"v\" /></ephemeral>"
	var parsed := SceneHtml.parse_block(HtmlParser.parse(html))
	_ok(not parsed["ok"], "дубликат id → отказ разбора")


## Сериализация одного объекта (без обёртки) — для сборки правок в тестах.
func _element_of(objects: Dictionary, id: String) -> String:
	var single := {id: objects[id].duplicate(true)}
	single[id]["parent"] = ""
	var block := SceneHtml.serialize(single)
	return block.replace("<ephemeral>", "").replace("</ephemeral>", "")


# --- Хелперы проверок ---

func _ok(cond: bool, label: String) -> void:
	if cond:
		print("  OK  ", label)
	else:
		_failed = true
		printerr("FAIL  ", label)


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  OK  ", label)
	else:
		_failed = true
		printerr("FAIL  %s: ожидалось %s, получено %s" % [label, expected, actual])
