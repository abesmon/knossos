extends Node

## Headless-тест базы переносимых инструментов (docs/space/portable-tools.md):
##  - document.scene (эфемерный слой скриптам, офлайн standalone-коммит);
##  - document.player.aim (прицел с target id) и фазы use/use_end;
##  - document.files.pick (инжектированный провайдер, байты → BlobStore);
##  - handle.call поверхность grabbable (holder/held_hand/set_enabled/release);
##  - item-runtime: kind="vrweb-item" → VrwebItemHost → собственный realm, namespace grab_id.
## Запуск: godot --headless tests/test_portable_base.tscn

const PLAYER_SCENE := preload("res://actors/player/player.tscn")

const PAGE := """
<html><body>
<vrwml mode="exclusive">
  <Resource id="StatueMesh" type="BoxMesh" size="Vector3(0.4,0.4,0.4)"/>
  <VRWebGrabbable id="statue" transform="Transform3D(1,0,0, 0,1,0, 0,0,1, 0,2.6,-2)">
    <MeshInstance3D mesh="SubResource:::StatueMesh"/>
  </VRWebGrabbable>
  <Label3D id="log-label" text="idle" position="Vector3(0,3,0)"/>
</vrwml>
</body></html>
"""

const SCRIPT_SOURCE := """
local statue = document.query("#statue")
local label = document.query("#log-label")
assert(statue ~= nil and label ~= nil, "targets missing")
assert(document.features.require("vrweb/scene-objects/1"))
assert(document.features.require("vrweb/aim/1"))
assert(document.features.require("vrweb/files/1"))
assert(document.features.require("vrweb/grabbable/1"))

-- Прицел в момент активации наведён на статую (луч уже сколлайдился).
local aim = document.player.aim()
assert(aim.hit == true, "aim must hit")
assert(aim.target == "statue", "aim target id, got " .. tostring(aim.target))
assert(aim.distance > 0.5 and aim.distance < 3.5, "aim distance sane")

-- Эфемерный слой: добавить узел; ack придёт после commit realm.
local placed = document.scene.add({ kind = "vrweb-node", parent = "", ttl = 0,
  props = { tag = "Label3D", attrs = { text = "placed", position = "Vector3(0,2.2,0)" } } },
  function(event)
    assert(event.ok == true, "scene add ack")
    label.set("text", "scene-ok:" .. tostring(event.id))
  end)
assert(placed ~= nil, "scene.add returns id")

statue.on("use", function(e)
  assert(statue.call("holder", {}) == e.user_id, "holder matches use payload")
  assert(statue.call("held_hand", {}) == "right", "hand is right")
  assert(statue.call("is_enabled", {}) == true, "enabled by default")
  document.files.pick("any", function(pick)
    assert(pick.ok == true, "pick ok")
    -- Файл приходит непрозрачным handle: байты и публикация — раздельные операции.
    assert(pick.file ~= nil, "pick file handle")
    assert(pick.file.bytes() ~= nil, "file bytes readable")
    local url = pick.file.publish("binary")
    assert(string.sub(tostring(url), 1, 12) == "vrwebblob://", "published blob url")
    label.set("text", "picked:" .. tostring(pick.size))
  end)
end, "")

statue.on("use_end", function(_e)
  assert(statue.call("set_enabled", {false}) == true, "set_enabled")
  assert(statue.call("release", {}) == true, "programmatic release")
  label.set("text", "use-end")
end, "")
"""

var _failed := false
var _script_errors: Array = []


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  OK  ", what)
	else:
		_failed = true
		printerr("FAIL  ", what)


func _ready() -> void:
	await get_tree().create_timer(40.0).timeout
	if is_inside_tree():
		printerr("PORTABLE BASE TEST: WATCHDOG"); get_tree().quit(2)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	Settings.online_enabled = false

	var world := Node3D.new()
	world.name = "world"
	add_child(world)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(60, 1, 60)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)

	var player: Player = PLAYER_SCENE.instantiate()
	world.add_child(player)
	player.global_position = Vector3(0, 1.0, 0)
	for i in 12:
		await get_tree().physics_frame
	player.velocity = Vector3.ZERO
	player.set_physics_process(false)

	var manager := GrabManager.new()
	manager.name = "GrabManager"
	world.add_child(manager)
	manager.setup(player, null)

	# Фейковый OS-пикер: отдаёт байты сразу (то, что в проде делает main через FileDialog).
	var fake_bytes := "portable-tools".to_utf8_buffer()
	var picker := func(_kind: String, done: Callable) -> void:
		done.call(true, "fake.bin", fake_bytes)

	var view := EphemeralView.new()
	view.name = "EphemeralView"
	world.add_child(view)
	view.setup(func(_transition): return, {
		"base_url": "vrwebresource://portable_base_test.html",
		"content_policy": VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL),
		"player": player, "file_picker": picker,
	})

	# --- Страница со статуей и скриптом ---
	var doc := HtmlParser.parse(PAGE)
	var built := VrwebBuilder.build(doc, "vrwebresource://portable_base_test.html")
	world.add_child(built["root"])
	await get_tree().process_frame
	await get_tree().process_frame

	var statue: Grabbable = null
	for g in get_tree().get_nodes_in_group(Grabbable.GROUP):
		if g.grab_id == "statue":
			statue = g
	_check(statue != null, "статуя материализована")
	if statue == null:
		get_tree().quit(1)
		return
	# Луч должен сколлайдиться до активации скрипта (top-level читает aim).
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(bool(player.aim_info().get("hit", false)), "Player.aim_info попадает в статую")

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
	var label: Label3D = targets.get("log-label")
	_check(label != null, "target #log-label разрешён")

	var runtime := VrwebLuauRuntime.new()
	runtime.file_picker = picker
	add_child(runtime)
	runtime.script_failed.connect(func(sid, phase, message):
		_script_errors.append("%s/%s: %s" % [sid, phase, message]))
	runtime.setup(world, targets, "vrwebresource://portable_base_test.html", player,
			VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var activated := runtime.activate([{
		"id": "portable.base", "profile": "vrweb-luau/1", "kind": "inline",
		"source": SCRIPT_SOURCE, "hash": SCRIPT_SOURCE.sha256_text(),
	}])
	_check(activated.ok, "скрипт активирован (aim/capabilities top-level): %s"
			% str(activated.get("errors", [])))

	# --- document.scene: ack + материализация вьюхой ---
	await get_tree().process_frame
	await get_tree().process_frame
	_check(str(label.text).begins_with("scene-ok:"), "scene.add подтверждён ack (%s)" % label.text)
	var placed_id := str(label.text).trim_prefix("scene-ok:")
	var placed_node: Node = view.get_node_or_null(NodePath(""))
	var placed_label: Label3D = null
	for child in view.get_children():
		if child is Label3D and (child as Label3D).text == "placed":
			placed_label = child
	_check(placed_label != null, "vrweb-node из скрипта материализован вьюхой")

	# --- grab → use (files.pick) → use_end (set_enabled + release) ---
	manager.request_grab(statue)
	await get_tree().process_frame
	_check(manager.local_held() == statue, "статуя взята")
	manager.use_held()
	await get_tree().process_frame
	_check(str(label.text) == "picked:%d" % fake_bytes.size(),
			"use → files.pick → блоб (%s)" % label.text)
	var hex := BlobProtocol.hash_bytes(fake_bytes)
	_check(BlobStore.has_hex(hex), "байты пикера легли в BlobStore")
	manager.use_held_end()
	await get_tree().process_frame
	_check(str(label.text) == "use-end", "use_end доехал до скрипта")
	_check(manager.local_held() == null, "программный release отпустил предмет")
	_check(not manager.can_local_grab(statue), "set_enabled(false) блокирует захват")

	# --- удаление объекта слоя ---
	NetworkManager.request_scene_action({"op": SceneChanges.OP_REMOVE, "id": placed_id})
	await get_tree().process_frame
	_check(placed_label == null or not is_instance_valid(placed_label),
			"scene.remove снял узел")

	# --- item-runtime: переносимый предмет со своим realm ---
	var item_id := NetworkManager.new_object_id()
	NetworkManager.request_scene_action({"op": SceneChanges.OP_ADD, "id": item_id,
		"kind": "vrweb-item", "parent": "", "ttl": 0.0,
		"props": {"src": "vrwebresource://items/color_cube.html", "position": [3.0, 1.0, 0.0]}})
	# Локальный fetch item-документа + два скриптовых кадра на активацию.
	for i in 10:
		await get_tree().process_frame
	var host: VrwebItemHost = null
	for child in view.get_children():
		if child is VrwebItemHost:
			host = child
	_check(host != null, "vrweb-item материализован (VrwebItemHost)")
	var cube: Grabbable = null
	for g in get_tree().get_nodes_in_group(Grabbable.GROUP):
		if g.grab_id.begins_with("item-" + item_id + "."):
			cube = g
	_check(cube != null, "grabbable предмета в мире, grab_id namespaced (%s)"
			% (cube.grab_id if cube != null else "нет"))
	var item_runtime: VrwebLuauRuntime = null
	if host != null:
		for child in host.get_children():
			if child is VrwebLuauRuntime:
				item_runtime = child
	_check(item_runtime != null and not item_runtime.active_hashes().is_empty(),
			"realm предмета активен (%s)" % str(item_runtime.active_hashes().keys() \
					if item_runtime != null else []))

	# Кубик кликается: grab → use меняет цвет материала предмета.
	if cube != null:
		manager.request_grab(cube)
		await get_tree().process_frame
		_check(manager.local_held() == cube, "предмет item'а взят в руку")
		var mesh: MeshInstance3D = null
		for node in cube.find_children("*", "MeshInstance3D", true, false):
			mesh = node
		var material: StandardMaterial3D = mesh.get("surface_material_override/0") if mesh != null else null
		var before: Color = material.albedo_color if material != null else Color.BLACK
		manager.use_held()
		await get_tree().process_frame
		_check(material != null and material.albedo_color != before,
				"use предмета исполняется его realm'ом (цвет сменился)")
		manager.release_held()
		await get_tree().process_frame

	# remove item → хост, сцена и realm сняты.
	NetworkManager.request_scene_action({"op": SceneChanges.OP_REMOVE, "id": item_id})
	await get_tree().process_frame
	await get_tree().process_frame
	_check(host == null or not is_instance_valid(host), "remove item снимает VrwebItemHost")
	var cube_alive := cube != null and is_instance_valid(cube)
	_check(not cube_alive, "grabbable предмета удалён вместе с item")

	await _test_instance_isolation(manager)
	await _test_scene_outside_room()
	_check(_script_errors.is_empty(), "callbacks без ошибок: %s" % str(_script_errors))
	get_tree().quit(1 if _failed else 0)


## Регрессия: действия слоя вне комнаты. Раньше standalone-ветка включалась ТОЛЬКО в offline
## mode, поэтому у пользователя с включённым онлайном, но не в комнате (локальная/одиночная
## страница), add молча терялся — пропадали и штрихи, и размещённые картинки.
func _test_scene_outside_room() -> void:
	var was_online := Settings.online_enabled
	Settings.online_enabled = true
	_check(not NetworkManager.in_room(), "предусловие: онлайн включён, но комнаты нет")

	var id := NetworkManager.new_object_id()
	NetworkManager.request_scene_action({"op": SceneChanges.OP_ADD, "id": id,
		"kind": "vrweb-node", "parent": "", "ttl": 0.0,
		"props": {"tag": "Label3D", "attrs": {"text": "outside-room"}}})
	await get_tree().process_frame
	_check(not NetworkManager.scene_object(id).is_empty(),
			"add вне комнаты закоммичен локально (онлайн включён)")

	NetworkManager.request_scene_action({"op": SceneChanges.OP_REMOVE, "id": id})
	await get_tree().process_frame
	_check(NetworkManager.scene_object(id).is_empty(), "remove вне комнаты тоже работает")
	Settings.online_enabled = was_online


## Гарантия модовой модели (docs/space/tool-authoring.md): два экземпляра ОДНОГО предмета в
## комнате независимы — namespace по id объекта слоя разводит и grabbable-адреса, и
## wire-адреса document.state. Работа с одним экземпляром не трогает второй.
func _test_instance_isolation(manager: GrabManager) -> void:
	var ids: Array[String] = []
	for i in 2:
		var id := NetworkManager.new_object_id()
		ids.append(id)
		NetworkManager.request_scene_action({"op": SceneChanges.OP_ADD, "id": id,
			"kind": "vrweb-item", "parent": "", "ttl": 0.0,
			"props": {"src": "vrwebresource://items/counter.html",
				"position": [float(i) * 2.0, 1.0, 4.0]}})
	for i in 14:
		await get_tree().process_frame

	var instances: Array[Grabbable] = []
	for id in ids:
		for g in get_tree().get_nodes_in_group(Grabbable.GROUP):
			if g is Grabbable and (g as Grabbable).grab_id.begins_with("item-%s." % id):
				instances.append(g)
	_check(instances.size() == 2, "два экземпляра одного item материализованы (%d)"
			% instances.size())
	if instances.size() != 2:
		return

	# Считаем ТОЛЬКО на первом экземпляре.
	manager.request_grab(instances[0])
	await get_tree().process_frame
	for i in 3:
		manager.use_held()
		await get_tree().process_frame
	manager.release_held()
	await get_tree().process_frame

	var first := NetworkManager.replicated_state("item-%s.counter/box" % ids[0],
			"item-%s.counter/cnt" % ids[0])
	var second := NetworkManager.replicated_state("item-%s.counter/box" % ids[1],
			"item-%s.counter/cnt" % ids[1])
	_check(int(first.get("n", -1)) == 3, "state первого экземпляра посчитан (%s)" % str(first))
	_check(int(second.get("n", -1)) == 0, "state второго экземпляра не тронут (%s)" % str(second))

	for id in ids:
		NetworkManager.request_scene_action({"op": SceneChanges.OP_REMOVE, "id": id})
	await get_tree().process_frame
