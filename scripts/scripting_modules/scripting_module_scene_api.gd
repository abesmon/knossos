class_name ScriptingModuleSceneAPI
extends RefCounted

## Minimal portable ownership facade. Trusted GDScript may still use Godot directly.

var _root: Node
var _valid := true


func _init(root: Node) -> void:
	_root = root


func root() -> Node:
	return _root if is_valid() else null


func find(relative_path: NodePath) -> Node:
	if not is_valid() or relative_path.is_absolute():
		return null
	return _root.get_node_or_null(relative_path)


func is_valid() -> bool:
	return _valid and is_instance_valid(_root)


func invalidate() -> void:
	_valid = false
	_root = null
