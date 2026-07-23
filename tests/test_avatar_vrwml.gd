extends Node

## Round-trip встроенных аватаров: .tscn -> standalone VRWML -> VrwebBuilder -> PackedScene.
## Запуск:
##   godot --headless --path . res://tests/test_avatar_vrwml.tscn
## Добавить `-- --write-vrwml`, чтобы обновить generated avatars/avatar_N.vrwml.

var _ok := true


func _ready() -> void:
	var write := OS.get_cmdline_user_args().has("--write-vrwml")
	_test_parameter_transport_contract()
	_test_avatar_policy()
	_test_animation_tree_applier_roundtrip()
	for idx in [1, 2]:
		_test_avatar(idx, write)
	if not write:
		_test_bundled_resolver()
	print("=== ", ("ALL PASSED" if _ok else "FAILURES ABOVE"), " ===")
	get_tree().quit(0 if _ok else 1)


func _test_parameter_transport_contract() -> void:
	var custom := &"FutureNetworkExtension"
	var filtered := AvatarParams.network_snapshot({
		AvatarParams.IS_LOCAL: true,
		AvatarParams.VOICE: 0.75,
		AvatarParams.GROUNDED: false,
		custom: 42,
	})
	_check(not filtered.has(AvatarParams.IS_LOCAL) and not filtered.has(AvatarParams.VOICE),
			"local-context parameters are excluded from network snapshots")
	_check(filtered.get(AvatarParams.GROUNDED) == false,
			"Grounded remains network-owned for now")
	_check(filtered.get(custom) == 42,
			"unknown extension parameters remain forward-compatible")


func _test_avatar_policy() -> void:
	var policy := AvatarVrwmlPolicy.new()
	_check(VrwebContentPolicy.allowed(policy.evaluate_element("Avatar", {})),
			"avatar policy allows public Avatar")
	_check(not VrwebContentPolicy.allowed(policy.evaluate_element("HTTPRequest", {})),
			"avatar policy rejects arbitrary engine class")
	_check(not VrwebContentPolicy.allowed(policy.evaluate_property("Node", "script", "x")),
			"avatar policy rejects Script property")
	_check(policy.has_errors() and policy.summary().contains("avatar.node.HTTPRequest"),
			"avatar policy exposes structured rejection diagnostics")
	var integrated := AvatarVrwmlPolicy.new()
	var built := VrwebBuilder.build(HtmlParser.parse(
			"<vrwml><Avatar><HTTPRequest><Node3D name=\"Preserved\"/></HTTPRequest>" \
			+ "</Avatar></vrwml>"), "test://avatar", integrated)
	_check(integrated.has_errors(), "builder records rejected child instead of silent partial loss")
	var holder := built.get("root") as Node3D
	_check(holder != null and holder.get_child_count() == 1 \
			and holder.get_child(0).get_node_or_null("Preserved") != null,
			"builder preserves supported descendants of a rejected wrapper")
	if holder != null:
		holder.free()


func _test_animation_tree_applier_roundtrip() -> void:
	var avatar := Avatar.new()
	avatar.name = "AnimatedAvatar"
	var tree := AnimationTree.new()
	tree.name = "Animator"
	avatar.add_child(tree)
	var applier := AvatarAnimationTreeApplier.new()
	applier.name = "AnimationBindings"
	applier.animation_tree = tree
	var binding := AvatarParamBinding.new()
	binding.param = AvatarParams.MOVING
	binding.tree_path = "parameters/conditions/moving"
	applier.bindings = [binding]
	avatar.add_child(applier)
	var report := VrwebExporter.export_vrwml_report(avatar)
	var text := str(report.get("vrwml", ""))
	_check(bool(report.get("ok", false)), "AnimationTree applier export succeeds")
	_check(text.contains("<AvatarAnimationTreeApplier"),
			"AnimationTree applier uses public class")
	_check(text.contains("animation_tree_path=\"NodePath(&quot;../Animator&quot;)\""),
			"AnimationTree reference exports as NodePath")
	_check(text.contains("type=\"AvatarParamBinding\""),
			"binding exports as public resource")

	var built := VrwebBuilder.build(HtmlParser.parse(text), "res://tests/animated.vrwml",
			AvatarVrwmlPolicy.new())
	var holder := built.get("root") as Node3D
	_check(holder != null and holder.get_child_count() == 1,
			"animated avatar materializes")
	if holder != null and holder.get_child_count() == 1:
		add_child(holder)
		var rebuilt := holder.get_child(0) as Avatar
		var rebuilt_tree := rebuilt.find_child("Animator", true, false) as AnimationTree
		var rebuilt_applier := rebuilt.find_child("AnimationBindings", true, false) \
				as AvatarAnimationTreeApplier
		_check(rebuilt_applier != null and rebuilt_applier.animation_tree == rebuilt_tree,
				"AnimationTree NodePath resolves after materialization")
		_check(rebuilt_applier != null and rebuilt_applier.bindings.size() == 1,
				"typed bindings array round-trips")
		if rebuilt_applier != null and rebuilt_applier.bindings.size() == 1:
			_check(rebuilt_applier.bindings[0].param == AvatarParams.MOVING \
					and rebuilt_applier.bindings[0].tree_path == "parameters/conditions/moving",
					"binding properties round-trip")
		remove_child(holder)
		holder.free()
	avatar.free()


func _test_avatar(idx: int, write: bool) -> void:
	var source_path := "res://avatars/avatar_%d.tscn" % idx
	var source := load(source_path) as PackedScene
	_check(source != null, "avatar_%d source loads" % idx)
	if source == null:
		return
	var authored := source.instantiate() as Avatar
	var report := VrwebExporter.export_vrwml_report(authored)
	var text := str(report.get("vrwml", ""))
	_check(bool(report.get("ok", false)), "avatar_%d export report ok" % idx)
	_check(text.begins_with("<vrwml>\n  <Avatar"), "avatar_%d exports semantic root" % idx)
	_check(text.contains("<LookPitchApplier"), "avatar_%d exports LookPitchApplier" % idx)
	_check(text.contains("<VoiceScaleApplier"), "avatar_%d exports VoiceScaleApplier" % idx)
	_check(text.contains("<UserTextureApplier"), "avatar_%d exports UserTextureApplier" % idx)
	_check(text.contains("name=\"Face\""), "avatar_%d preserves target names" % idx)
	_check(not text.contains("Script") and not text.contains("source_code"),
			"avatar_%d is data-only" % idx)
	_check(not text.contains("CompressedTexture2D"),
			"avatar_%d uses implementation default face without Godot import artifact" % idx)

	var second := source.instantiate() as Avatar
	_check(VrwebExporter.export_vrwml(second) == text, "avatar_%d export deterministic" % idx)
	second.free()
	if not write:
		var generated_path := "res://avatars/avatar_%d.vrwml" % idx
		_check(FileAccess.file_exists(generated_path),
				"avatar_%d generated artifact exists" % idx)
		if FileAccess.file_exists(generated_path):
			_check(FileAccess.get_file_as_string(generated_path) == text,
					"avatar_%d generated artifact matches authoring scene" % idx)

	var built := VrwebBuilder.build(HtmlParser.parse(text), source_path, AvatarVrwmlPolicy.new())
	var holder := built.get("root") as Node3D
	_check(holder != null and holder.get_child_count() == 1,
			"avatar_%d builds one root" % idx)
	if holder != null and holder.get_child_count() == 1:
		var avatar := holder.get_child(0) as Avatar
		_check(avatar != null, "avatar_%d root materializes as Avatar" % idx)
		if avatar != null:
			_check(is_equal_approx(avatar.nameplate_height, 2.0 if idx == 2 else 2.1),
					"avatar_%d nameplate height round-trips" % idx)
			var look := avatar.find_child("LookPitchApplier", true, false)
			_check(look != null and VrwmlClassRegistry.public_name(look) == "LookPitchApplier",
					"avatar_%d look applier materializes" % idx)
			var expected := NodePath("../Head" if idx == 2 else "../Face")
			_check(look != null and look.get("target_path") == expected,
					"avatar_%d target NodePath round-trips" % idx)
			var face := avatar.find_child("Face", true, false) as MeshInstance3D
			var mat := face.get_active_material(0) if face != null else null
			var marker = mat.get("albedo_texture") if mat != null else null
			_check(marker is UserSettingsAvatarTexture,
					"avatar_%d identity texture marker round-trips" % idx)
			_check(marker != null and marker.default_texture != null,
					"avatar_%d marker has implementation fallback texture" % idx)
	if holder != null:
		holder.free()

	if write and bool(report.get("ok", false)):
		var output := "res://avatars/avatar_%d.vrwml" % idx
		var file := FileAccess.open(output, FileAccess.WRITE)
		_check(file != null, "avatar_%d generated file opens" % idx)
		if file != null:
			file.store_string(text)
			file.close()
	authored.free()


func _test_bundled_resolver() -> void:
	var resolver := AvatarResolver.new()
	add_child(resolver)
	for idx in [1, 2]:
		var state := {"called": false}
		resolver.resolve("vrwebavatar://%d" % idx, func(scene: PackedScene) -> void:
			state.called = true
			_check(scene != null, "resolver returns avatar_%d PackedScene" % idx)
			if scene != null:
				var avatar := scene.instantiate() as Avatar
				_check(avatar != null, "resolver PackedScene %d instantiates Avatar" % idx)
				if avatar != null:
					_check(avatar.find_child("LookPitchApplier", true, false) != null,
							"resolver avatar_%d keeps appliers" % idx)
					avatar.free())
		_check(bool(state.called), "bundled avatar_%d resolves synchronously" % idx)
	var rejected := {"called": false}
	resolver.resolve("https://example.invalid/avatar.tscn", func(scene: PackedScene) -> void:
		rejected.called = true
		_check(scene == null, "external TSCN cannot bypass avatar VRWML policy"))
	_check(bool(rejected.called), "unsupported external avatar format rejects before network")
	resolver.free()
	var host := AvatarHost.new()
	add_child(host)
	_check(host.find_child("DefaultAvatar", true, false) is Avatar,
			"AvatarHost runtime default comes from bundled VRWML")
	host.free()


func _check(condition: bool, label: String) -> void:
	print(("  [ok]  " if condition else "  [FAIL] "), label)
	_ok = condition and _ok
