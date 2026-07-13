extends StaticBody3D

const VISUAL := preload("../package_export/switch_scene.tscn")

var _context
var _enabled := false
var _lamp: OmniLight3D
var _label: Label3D


func mount(context) -> void:
	_context = context
	var visual := VISUAL.instantiate()
	visual.position = Vector3(0.0, 0.7, 0.0)
	add_child(visual)
	_build_godot_visual()
	if not context.input.on_activate(self, _on_activate, "Toggle shared light"):
		context.log.error("LightSwitch could not register input")
	var schema := {
		"version": 1,
		"fields": {"enabled": {"type": "bool", "default": false}},
		"default_write_rule": "authority",
		"commands": {"toggle": {"reducer": _reduce_toggle}},
	}
	if not context.state.register_schema("switch", schema):
		context.log.error("LightSwitch schema registration failed")
		return
	if not context.state.ensure_object("demo", "switch", {"enabled": false}):
		context.log.error("LightSwitch object registration failed")
		return
	context.state.subscribe("demo", "switch", _on_state)
	_apply(context.state.read("demo", "switch"))
	context.log.info("portable LightSwitch mounted")


func unmount() -> void:
	_context = null


func _on_activate(_point: Vector3) -> void:
	if _context == null:
		return
	_context.state.command("demo", "switch", 1, "toggle")


func _on_state(state: Dictionary, _changed: Dictionary, _revision: int) -> void:
	_apply(state)


func _reduce_toggle(state: Dictionary, _args: Dictionary, _command_context: Dictionary) -> Dictionary:
	return {"enabled": not bool(state.get("enabled", false))}


func _apply(state: Dictionary) -> void:
	_enabled = bool(state.get("enabled", false))
	if _lamp != null:
		_lamp.light_color = Color(0.35, 1.0, 0.45) if _enabled else Color(1.0, 0.2, 0.15)
		_lamp.light_energy = 4.0 if _enabled else 0.35
	if _label != null:
		_label.text = "LIGHT ON" if _enabled else "LIGHT OFF"
		_label.modulate = Color(0.35, 1.0, 0.45) if _enabled else Color(1.0, 0.3, 0.25)


func _build_godot_visual() -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.8, 1.4, 0.5)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.14, 0.2)
	var body := MeshInstance3D.new()
	body.mesh = mesh
	body.material_override = material
	add_child(body)
	_lamp = OmniLight3D.new()
	_lamp.position = Vector3(0.0, 0.25, 0.5)
	_lamp.omni_range = 6.0
	add_child(_lamp)
	_label = Label3D.new()
	_label.position = Vector3(0.0, 0.0, 0.27)
	_label.font_size = 64
	add_child(_label)
