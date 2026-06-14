extends SceneTree

## Хедлесс round-trip экспорта: сцена Godot -> VrwebExporter -> HTML ->
## HtmlParser -> VrwebBuilder -> проверка, что прочиталось то же самое.
## Запуск: godot --headless --path . --script res://tests/test_export.gd

func _initialize() -> void:
	var ok := true

	# --- Собираем тестовую сцену ---
	var root := Node3D.new()

	var mesh := BoxMesh.new()
	mesh.size = Vector3(2, 1, 3)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = Transform3D(Basis.IDENTITY, Vector3(-10, 0.05, 0))
	# Коллизия ребёнком — проверяем иерархию.
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(2, 1, 3)
	shape.shape = box_shape
	body.add_child(shape)
	mi.add_child(body)
	root.add_child(mi)

	var light := OmniLight3D.new()
	light.omni_range = 12.0
	light.transform = Transform3D(Basis.IDENTITY, Vector3(-10, 4, 0))
	root.add_child(light)

	# Ext-привязка свойства: Sprite3D.texture из URL.
	var sprite := Sprite3D.new()
	var ext_tex := VrwebExtResource.new()
	ext_tex.url = "https://godotengine.org/assets/press/icon_color.png"
	ext_tex.type = "Texture2D"
	sprite.set_meta(VrwebExtResource.META_BINDINGS, {"texture": ext_tex})
	root.add_child(sprite)

	# Ext-сцена (<ExtScene>).
	var ext_scene_node := Node3D.new()
	ext_scene_node.transform = Transform3D(Basis.IDENTITY, Vector3(-13, 0.1, 2))
	var ext_scene := VrwebExtResource.new()
	ext_scene.url = "https://example.com/duck.glb"
	ext_scene.type = "PackedScene"
	ext_scene_node.set_meta(VrwebExtResource.META_SCENE, ext_scene)
	root.add_child(ext_scene_node)

	# Спавнер с двумя точками.
	var spawner := VrwebSpawner.new()
	spawner.mode = "random"
	var p1 := Marker3D.new()
	p1.transform = Transform3D(Basis.IDENTITY, Vector3(-7, 1.6, 3))
	var p2 := Marker3D.new()
	p2.transform = Transform3D(Basis.IDENTITY, Vector3(-13, 1.6, -3))
	spawner.add_child(p1)
	spawner.add_child(p2)
	root.add_child(spawner)

	# --- Экспорт ---
	var html := VrwebExporter.export_scene(root, VrwebBuilder.MODE_EXCLUSIVE)
	print("=== EXPORTED HTML ===")
	print(html)
	root.free()

	# --- Чтение обратно ---
	var doc := HtmlParser.parse(html)
	var result := VrwebBuilder.build(doc, "vrwebresource://test.html")

	print("\n=== ROUND-TRIP CHECKS ===")
	ok = _check(result.get("found", false), "found vrweb block") and ok
	ok = _check(result.get("mode", "") == VrwebBuilder.MODE_EXCLUSIVE, "mode == exclusive") and ok

	var built: Node3D = result.get("root")
	ok = _check(built != null, "built root not null") and ok
	if built != null:
		# Дети холдера: MeshInstance3D, OmniLight3D, Sprite3D, ExtScene(Node3D). Спавнер — мета-тег.
		var classes: Array[String] = []
		for c in built.get_children():
			classes.append(c.get_class())
		print("  built children classes: ", classes)
		ok = _check(classes.size() == 4, "4 node children (spawner excluded)") and ok

		var mi2: MeshInstance3D = _first_of(built, "MeshInstance3D")
		ok = _check(mi2 != null and mi2.mesh is BoxMesh, "MeshInstance3D has BoxMesh subresource") and ok
		if mi2 != null and mi2.mesh is BoxMesh:
			ok = _check((mi2.mesh as BoxMesh).size == Vector3(2, 1, 3), "BoxMesh.size round-trip") and ok
			ok = _check(mi2.transform.origin == Vector3(-10, 0.05, 0), "MeshInstance3D.transform round-trip") and ok
			var sb: StaticBody3D = _first_of(mi2, "StaticBody3D")
			ok = _check(sb != null, "StaticBody3D child preserved") and ok
			if sb != null:
				var cs: CollisionShape3D = _first_of(sb, "CollisionShape3D")
				ok = _check(cs != null and cs.shape is BoxShape3D, "CollisionShape3D has BoxShape3D") and ok

		var light2: OmniLight3D = _first_of(built, "OmniLight3D")
		ok = _check(light2 != null and is_equal_approx(light2.omni_range, 12.0), "OmniLight3D.omni_range round-trip") and ok

	# Ext-ресурсы.
	var ext: Dictionary = result.get("ext", {})
	var defs: Dictionary = ext.get("defs", {})
	var targets: Array = ext.get("targets", [])
	print("  ext defs: ", defs)
	print("  ext targets: ", targets.size())
	ok = _check(defs.size() == 2, "2 ext defs (texture + scene)") and ok
	var has_tex := false
	var has_scene_child := false
	for t in targets:
		var d: Dictionary = defs.get(t.get("id", ""), {})
		if d.get("type", "") == "Texture2D" and t.get("prop", "") == "texture":
			has_tex = true
			ok = _check(d.get("url", "").ends_with("icon_color.png"), "texture ext url round-trip") and ok
		if t.get("child", false) and d.get("type", "") == "PackedScene":
			has_scene_child = true
	ok = _check(has_tex, "texture ext target present") and ok
	ok = _check(has_scene_child, "ExtScene child target present") and ok

	# Спавн.
	var spawn: Dictionary = result.get("spawn", {})
	print("  spawn: ", spawn)
	ok = _check(spawn.has("point"), "spawn point present") and ok

	print("\n=== ", ("ALL PASSED" if ok else "FAILURES ABOVE"), " ===")
	quit(0 if ok else 1)


func _check(cond: bool, label: String) -> bool:
	print(("  [ok]  " if cond else "  [FAIL] "), label)
	return cond


func _first_of(node: Node, cls: String) -> Node:
	for c in node.get_children():
		if c.get_class() == cls:
			return c
	return null
