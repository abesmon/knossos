extends Node

## End-to-end demo regression: generic WorldUiCanvas Controls, ordinary Godot signals,
## explicit shader format, opaque material application and replicated source publication.

var _failed := false


func _ready() -> void:
	NetworkManager._replicated.reset_session()
	var html := FileAccess.get_file_as_string("res://addons/vrweb_tools/examples/shader_lab.html")
	var doc := HtmlParser.parse(html)
	var declarations := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://examples/shader_lab.html")
	_eq(declarations.errors.is_empty(), true, "shader demo has a valid Luau declaration")
	_eq(declarations.scripts.size(), 1, "shader demo owns one page script")

	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var built := VrwebBuilder.build(doc, "vrwebresource://examples/shader_lab.html", policy)
	var page_root := built.get("root") as Node
	add_child(page_root)
	var targets := _targets(doc, built)
	var canvas := targets.get("editor-canvas") as WorldUiCanvas
	var editor := targets.get("source-editor") as CodeEdit
	var publish := targets.get("apply-button") as Button
	var diagnostics := targets.get("diagnostics") as Label
	var preview := targets.get("shader-plane") as MeshInstance3D

	_eq(canvas != null and canvas.ui_size().is_equal_approx(Vector2(5.2, 3.4)), true,
			"WorldUiCanvas is the only special world-space UI wrapper")
	_eq(canvas != null and (canvas.content_root() as SubViewport).size == Vector2i(1040, 680),
			true, "canvas keeps UI pixel resolution independent from its meter size")
	_eq(editor != null and editor.get_parent() is VBoxContainer, true,
			"standard CodeEdit preserves the declarative Control hierarchy")
	_eq(editor != null and canvas.content_root().is_ancestor_of(editor), true,
			"standard Controls are routed into the canvas SubViewport")
	_eq(publish != null and diagnostics != null and preview != null, true,
			"button, diagnostics and preview remain ordinary queryable nodes")

	# Reproduce the real world-space path: ray hover -> synthetic click -> keyboard forwarding.
	await get_tree().process_frame
	var viewport := canvas.content_root() as SubViewport
	_eq(viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS, true,
			"interactive canvas continuously refreshes its 3D viewport texture")
	var editor_px := editor.global_position + editor.size * 0.5
	var editor_uv := editor_px / Vector2(viewport.size)
	canvas._on_ui_pointer_move(editor_uv)
	await get_tree().process_frame
	canvas._on_ui_accept(editor_uv)
	_eq(viewport.gui_get_focus_owner() == editor and canvas.keyboard_focus_active(), true,
			"clicking CodeEdit immediately establishes visible caret and keyboard focus")
	var typed := InputEventKey.new()
	typed.pressed = true
	typed.keycode = KEY_Z
	typed.physical_keycode = KEY_Z
	typed.unicode = 122
	_eq(canvas.forward_keyboard_input(typed), true,
			"focused WorldUiCanvas accepts keyboard input")
	await get_tree().process_frame
	_eq(editor.text.contains("z"), true, "forwarded key is inserted into CodeEdit")
	canvas.release_keyboard_focus()
	editor.text = ""

	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	var script_errors := []
	runtime.script_failed.connect(func(script_id: String, phase: String, message: String):
		script_errors.append({"script_id": script_id, "phase": phase, "message": message}))
	runtime.setup(page_root, targets, "vrwebresource://examples/shader_lab.html", null, policy)
	var activated := runtime.activate(declarations.scripts)
	_eq(activated.ok, true, "shader demo Luau activates (%s)" % str(script_errors))
	_eq(preview.material_override is ShaderMaterial, true,
			"initial replicated source becomes an opaque ShaderMaterial (%s)" % diagnostics.text)
	var initial_shader: Shader = (preview.material_override as ShaderMaterial).shader \
			if preview.material_override is ShaderMaterial else null
	_eq(initial_shader != null and initial_shader.code.contains("float pulse"), true,
			"explicit Godot shader source reaches the preview")
	_eq(initial_shader != null and initial_shader.code.contains(
			"uniform float AUTHORITY_TIME;"), true,
			"runtime injects the standard authority clock into every shader")
	runtime._process(0.01)
	var shader_authority_time = (preview.material_override as ShaderMaterial).get_shader_parameter(
			"AUTHORITY_TIME")
	_eq(shader_authority_time is float and float(shader_authority_time) > 0.0, true,
			"AUTHORITY_TIME input follows the VRWeb authority clock (%s)" %
			str(shader_authority_time))
	_eq(publish.pressed.get_connections().size() == 1, true,
			"page script can subscribe to an ordinary zero-argument Godot signal")

	var changed_source := """shader_type spatial;
render_mode unshaded;
void fragment() { ALBEDO = vec3(0.05, 0.85, 0.35); }
"""
	editor.text = changed_source
	editor.text_changed.emit()
	_eq(diagnostics.text.begins_with("LOCAL DRAFT"), true,
			"CodeEdit text_changed reaches Luau through the generic signal bridge")

	var online_before := Settings.online_enabled
	Settings.online_enabled = false
	publish.pressed.emit()
	await get_tree().process_frame
	Settings.online_enabled = online_before
	_eq(script_errors.is_empty(), true, "publish callback completes (%s)" % str(script_errors))
	var shared := NetworkManager.replicated_state("demo.shader-lab/shared_preview",
			"demo.shader-lab/shader_source")
	_eq(shared.get("source", "") == changed_source, true,
			"published source is stored in replicated multiplayer state")
	var changed_shader: Shader = (preview.material_override as ShaderMaterial).shader \
			if preview.material_override is ShaderMaterial else null
	_eq(changed_shader != null and changed_shader.code.contains("0.85"), true,
			"replicated update recompiles and replaces the preview material (%s)" % diagnostics.text)
	_eq(diagnostics.text.begins_with("SYNCED"), true,
			"the same state subscription updates standard UI diagnostics")

	runtime.close()
	runtime.queue_free()
	page_root.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _targets(doc: HtmlNode, built: Dictionary) -> Dictionary:
	var result := {}
	var index := SceneHtml.build_page_index(doc)
	for node_id in index.get("nodes", {}):
		var record: Dictionary = index.nodes[node_id]
		var node = (built.nodes as Dictionary).get(record.elem)
		if node != null:
			result[node_id] = node
	for resource_id in built.get("resources", {}):
		if not result.has(resource_id):
			result[resource_id] = built.resources[resource_id]
	return result


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
