class_name WorldUiCanvas
extends WorldUiSurface

## Переиспользуемая интерактивная 2D-панель в мире. SubViewport играет роль canvas:
## обычные Godot Control/Button/Tree/LineEdit получают pointer motion, click и wheel, поэтому
## новые таблицы/кнопки/формы не требуют нового 3D hit-test и собственного протокола ввода.

@export var viewport_path: NodePath = NodePath("SubViewport")
@export var mesh_path: NodePath = NodePath("Mesh")
@export var back_mesh_path: NodePath = NodePath("Mesh/Back")
@export var collision_path: NodePath = NodePath("CollisionShape3D")

var _canvas_viewport: SubViewport
var _canvas_mesh: MeshInstance3D
var _canvas_back: MeshInstance3D
var _canvas_collision: CollisionShape3D
var _canvas_size_m := Vector2.ONE
var _last_canvas_px := Vector2.ZERO
var _requested_size_m := Vector2.ZERO
var _requested_viewport_size := Vector2i.ZERO
var _keyboard_focus_active := false


## Конфигурация публичного <WorldUiCanvas> до входа в scene tree. Дочерние Control
## материализуются builder-ом прямо под content_root().
func setup_canvas(size_m: Vector2, viewport_size: Vector2i) -> void:
	_requested_size_m = size_m
	_requested_viewport_size = viewport_size
	var viewport := get_node_or_null(viewport_path) as SubViewport
	if viewport != null and viewport_size.x > 0 and viewport_size.y > 0:
		viewport.size = viewport_size


func content_root() -> Node:
	return get_node_or_null(viewport_path)


func _ready() -> void:
	super()
	_canvas_viewport = get_node_or_null(viewport_path) as SubViewport
	_canvas_mesh = get_node_or_null(mesh_path) as MeshInstance3D
	_canvas_back = get_node_or_null(back_mesh_path) as MeshInstance3D
	_canvas_collision = get_node_or_null(collision_path) as CollisionShape3D
	if _canvas_viewport != null:
		# Интерактивный canvas должен перерисовывать viewport texture после каждого изменения
		# Control: caret, введённого текста, hover, pressed state и script-driven свойств.
		_canvas_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _requested_viewport_size.x > 0 and _requested_viewport_size.y > 0 \
			and _canvas_viewport != null:
		_canvas_viewport.size = _requested_viewport_size
	if _requested_size_m.x > 0.0 and _requested_size_m.y > 0.0:
		configure_canvas_geometry(_requested_size_m)
	elif _canvas_mesh != null and _canvas_mesh.mesh is QuadMesh:
		_canvas_size_m = (_canvas_mesh.mesh as QuadMesh).size
	_bind_canvas_texture()


func ui_size() -> Vector2:
	return _canvas_size_m


## Единая геометрия canvas: размер фронта/изнанки и физического hit-target меняется атомарно.
func configure_canvas_geometry(size_m: Vector2) -> void:
	_canvas_size_m = Vector2(maxf(size_m.x, 0.001), maxf(size_m.y, 0.001))
	if _canvas_mesh == null:
		return
	var quad := _canvas_mesh.mesh as QuadMesh
	if quad == null:
		quad = QuadMesh.new()
		_canvas_mesh.mesh = quad
	quad.size = _canvas_size_m
	_bind_canvas_texture()
	if _canvas_back != null:
		_canvas_back.mesh = quad
		_canvas_back.material_override = _canvas_mesh.material_override
	if _canvas_collision != null:
		var box := _canvas_collision.shape as BoxShape3D
		if box == null:
			box = BoxShape3D.new()
			_canvas_collision.shape = box
		box.size = Vector3(_canvas_size_m.x, _canvas_size_m.y, 0.08)


func canvas_px(uv: Vector2) -> Vector2:
	if _canvas_viewport == null:
		return Vector2(-1.0, -1.0)
	return uv * Vector2(_canvas_viewport.size)


func _bind_canvas_texture() -> void:
	if _canvas_mesh == null or _canvas_viewport == null:
		return
	var material := _canvas_mesh.material_override as StandardMaterial3D
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_BACK
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_canvas_mesh.material_override = material
	material.albedo_texture = _canvas_viewport.get_texture()


func _on_ui_pointer_move(uv: Vector2) -> void:
	if _canvas_viewport == null:
		return
	var px := canvas_px(uv)
	var event := InputEventMouseMotion.new()
	event.position = px
	event.global_position = px
	event.relative = px - _last_canvas_px
	_last_canvas_px = px
	_canvas_viewport.push_input(event, true)


func _on_ui_pointer_exit() -> void:
	if _canvas_viewport == null:
		return
	# Движение за пределы viewport даёт Control-узлам штатный mouse_exited вместо зависшего hover.
	var event := InputEventMouseMotion.new()
	event.position = Vector2(-10000.0, -10000.0)
	event.global_position = event.position
	_canvas_viewport.push_input(event, true)


func _on_ui_accept(uv: Vector2) -> void:
	# SubViewport.push_input() can finish GUI dispatch after interact_at() returns. If Player
	# checks focus immediately, gui_get_focus_owner() is still empty and keyboard routing never
	# starts. Capture the hovered text control before the synthetic click and focus it explicitly;
	# the click that follows still places the caret at the requested pixel.
	var hovered := _canvas_viewport.gui_get_hovered_control() if _canvas_viewport != null else null
	_keyboard_focus_active = false
	if hovered is LineEdit or hovered is TextEdit:
		hovered.grab_focus()
		_keyboard_focus_active = true
	_push_canvas_button(canvas_px(uv), MOUSE_BUTTON_LEFT)
	var focus := _canvas_viewport.gui_get_focus_owner() if _canvas_viewport != null else null
	if focus is LineEdit or focus is TextEdit:
		_keyboard_focus_active = true


func _on_ui_scroll(direction: float) -> void:
	var button := MOUSE_BUTTON_WHEEL_DOWN if direction > 0.0 else MOUSE_BUTTON_WHEEL_UP
	_push_canvas_button(_last_canvas_px, button)


func _push_canvas_button(px: Vector2, button: MouseButton) -> void:
	if _canvas_viewport == null or px.x < 0.0:
		return
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = pressed
		event.position = px
		event.global_position = px
		_canvas_viewport.push_input(event, true)


func _ui_is_active(_uv: Vector2) -> bool:
	return _canvas_viewport != null


func keyboard_focus_active() -> bool:
	return _keyboard_focus_active and _canvas_viewport != null \
			and is_instance_valid(_canvas_viewport.gui_get_focus_owner())


func forward_keyboard_input(event: InputEvent) -> bool:
	if not keyboard_focus_active() or not (event is InputEventKey):
		return false
	_canvas_viewport.push_input(event, true)
	return true


func release_keyboard_focus() -> void:
	_keyboard_focus_active = false
	if _canvas_viewport != null:
		_canvas_viewport.gui_release_focus()
