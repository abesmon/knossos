extends Node


func _ready() -> void:
	var asset := VrwebLocalAsset.new()
	asset.source_path = "res://asset_fixtures/local_model.gltf"
	asset.type = "PackedScene"
	var result := VrwebAssetBundler.bundle(asset, "res://asset-dist/world.html")
	var ok: bool = bool(result.get("ok", false)) and result.get("dependencies", []).size() == 2
	if ok:
		var gltf_path := "res://asset-dist/" + str(result.get("url", ""))
		var gltf := FileAccess.get_file_as_string(gltf_path)
		ok = FileAccess.file_exists(gltf_path) \
				and gltf.contains("local_model.") and not gltf.contains("local_model.bin") \
				and not gltf.contains("local_model.png")
	var missing := VrwebLocalAsset.new()
	missing.source_path = "res://missing.png"
	var rejected := VrwebAssetBundler.bundle(missing, "res://asset-dist/world.html")
	ok = ok and not bool(rejected.get("ok", true))
	var wrong_case := VrwebLocalAsset.new()
	wrong_case.source_path = "res://asset_fixtures/Local_model.gltf"
	var case_rejected := VrwebAssetBundler.bundle(wrong_case, "res://asset-dist/world.html")
	ok = ok and not bool(case_rejected.get("ok", true)) \
			and str(case_rejected.get("error", "")).contains("регистром")
	print("CLEAN MAKER ASSETS ", "PASSED" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)
