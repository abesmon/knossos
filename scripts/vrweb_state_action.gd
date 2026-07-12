class_name VrwebStateAction
extends WorldUiSurface

## Независимая интерактивная поверхность: находит VRWebReplicatedState по NodePath и вызывает
## его команду. Визуальные дети необязательны и не связаны с расположением state-узла.

var state_path := NodePath()
var command := ""
var args: Dictionary = {}
var hint := ""
var surface_size := Vector2.ONE
var surface_center := Vector3.ZERO


func setup(config: Dictionary) -> void:
	state_path = NodePath(str(config.get("state_path", "")))
	command = str(config.get("command", ""))
	args = (config.get("args", {}) as Dictionary).duplicate(true)
	hint = str(config.get("hint", ""))
	surface_size = config.get("size", Vector2.ONE)
	surface_center = config.get("center", Vector3.ZERO)


func ui_size() -> Vector2:
	return surface_size


func ui_center_local() -> Vector3:
	return surface_center


func _ui_is_active(_uv: Vector2) -> bool:
	return _state_node() != null and not command.is_empty()


func _ui_hint(_uv: Vector2) -> String:
	return hint


func _on_ui_accept(_uv: Vector2) -> void:
	var state_node := _state_node()
	if state_node != null and not command.is_empty():
		state_node.request_command(command, args)


func _state_node() -> VrwebReplicatedState:
	return get_node_or_null(state_path) as VrwebReplicatedState
