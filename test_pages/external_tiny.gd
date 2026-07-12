extends Node3D
@export var marker := "external-default"
func answer() -> int: return 73
func presentation_text() -> String: return "EXTERNAL SCRIPT: %s = %d" % [marker, answer()]
func _ready() -> void:
	var label := get_node_or_null("ChildLabel") as Label3D
	if label != null:
		label.text = presentation_text()
		label.modulate = Color(1.0, 0.65, 0.25)
