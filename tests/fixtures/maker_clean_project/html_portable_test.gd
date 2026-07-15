extends Node


func _ready() -> void:
	var root := VrwebPortableHtmlSceneCodec.build_from_path("res://editable.html")
	var ok := root != null and bool(root.get_meta(VrwebHtmlDocument.META_IMPORTED, false)) \
			and root.get_child_count() == 4 \
			and str(root.get_meta(VrwebHtmlDocument.META_PREFIX, "")).contains("<main>") \
			and str(root.get_meta(VrwebHtmlDocument.META_SUFFIX, "")).contains("<footer>")
	var sprite := root.get_child(2) as Sprite3D
	ok = ok and sprite != null \
			and (sprite.get_meta(VrwebExtResource.META_BINDINGS, {}).get("texture") \
			is VrwebExtResource)
	var mesh := root.get_child(0) as MeshInstance3D
	mesh.position = Vector3(4, 0, 0)
	var saved := VrwebHtmlSceneSaver.save_root(root, "res://roundtrip.html")
	var output := FileAccess.get_file_as_string("res://roundtrip.html")
	ok = ok and bool(saved.get("ok", false)) \
			and output.begins_with(str(root.get_meta(VrwebHtmlDocument.META_PREFIX, ""))) \
			and output.ends_with(str(root.get_meta(VrwebHtmlDocument.META_SUFFIX, ""))) \
			and output.contains("4, 0, 0")
	var reparsed := VrwebPortableHtmlSceneCodec.build_from_path("res://roundtrip.html")
	ok = ok and reparsed != null and bool(reparsed.get_meta(VrwebHtmlDocument.META_IMPORTED, false))
	var unsupported_block := HtmlParser.parse(
			"<vrwml><Camera3D><Node3D name=\"Preserved\"/></Camera3D></vrwml>") \
			.find_descendant("vrwml")
	var unsupported := VrwebMarkupMaterializer.build(unsupported_block,
			VrwebCompatibility.PROFILE_STRICT)
	ok = ok and bool(unsupported.get("ok", false)) \
			and not bool(unsupported.get("complete", true)) \
			and str(unsupported.get("warnings", [])).contains("Camera3D") \
			and (unsupported.get("root") as Node).get_child_count() == 1 \
			and (unsupported.get("root") as Node).get_child(0).name == "Preserved"
	if unsupported.get("root") is Node:
		(unsupported.root as Node).free()
	root.free()
	if reparsed != null:
		reparsed.free()
	print("CLEAN PORTABLE HTML ", "PASSED" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)
