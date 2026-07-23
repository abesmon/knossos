extends Node

## Регрессия стандартного специального тега: документный и realtime-пути используют один
## VrwebBuilder и материализуют <VRWebStroke> без отдельного kind="stroke".

var _failed := false


func _ready() -> void:
	var doc := HtmlParser.parse("""
<vrwml>
  <VRWebStroke points="[0, 1, 0, 0.5, 1.2, 0.1]" color="Color(1, 0.25, 0, 1)" width="0.04" />
</vrwml>
""")
	var built := VrwebBuilder.build(doc, "https://example.test/world.html",
			VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var holder := built.get("root") as Node3D
	_check(holder != null, "VRWebStroke создаёт корень VRWML")
	if holder != null:
		add_child(holder)
		var stroke := holder.get_child(0) as StrokeActor if holder.get_child_count() > 0 else null
		_check(stroke != null, "VRWebStroke материализован StrokeActor")
		if stroke != null:
			_check(is_equal_approx(float(stroke.width), 0.04), "width разобран")
			_check(stroke.color is Color and (stroke.color as Color).is_equal_approx(
					Color(1, 0.25, 0)), "color разобран")
			var mesh_node := stroke.get_node("Mesh") as MeshInstance3D
			var mesh := mesh_node.mesh as ImmediateMesh
			_check(mesh != null and mesh.get_surface_count() == 1, "полилиния построила один меш")
		holder.queue_free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("ok: ", label)
	else:
		_failed = true
		push_error("FAIL: " + label)
