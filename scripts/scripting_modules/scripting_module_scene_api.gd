class_name ScriptingModuleSceneAPI
extends RefCounted

## Minimal portable ownership facade. Trusted GDScript may still use Godot directly.

var _scene_root: Node
var _valid := true


func _init(scene_root_node: Node) -> void:
	_scene_root = scene_root_node


func root() -> Node:
	return _scene_root if is_valid() else null


func find(relative_path: NodePath) -> Node:
	if not is_valid() or relative_path.is_absolute():
		return null
	return _scene_root.get_node_or_null(relative_path)


func is_valid() -> bool:
	return _valid and is_instance_valid(_scene_root)


func invalidate() -> void:
	_valid = false
	_scene_root = null
