class_name ScriptingModuleInputAPI
extends RefCounted

## Portable activation hook over Knossos' aim/interact protocol.

const META := "vrweb_input_api"

var _root: Node
var _valid := true
var _targets: Dictionary = {} # instance id -> {node, callback, hint}


func _init(root: Node) -> void:
	_root = root


func on_activate(target: Node, callback: Callable, hint := "") -> bool:
	if not _valid or not _owns(target) or not callback.is_valid():
		return false
	target.set_meta(META, self)
	_targets[target.get_instance_id()] = {"node": target, "callback": callback, "hint": str(hint)}
	return true


func off_activate(target: Node) -> bool:
	if not is_instance_valid(target) or not _targets.has(target.get_instance_id()):
		return false
	_targets.erase(target.get_instance_id())
	if target.has_meta(META) and target.get_meta(META) == self:
		target.remove_meta(META)
	return true


func dispatch(target: Node, point: Vector3) -> bool:
	var record: Dictionary = _targets.get(target.get_instance_id(), {}) if _valid else {}
	if record.is_empty():
		return false
	var callback: Callable = record.callback
	if not callback.is_valid():
		return false
	callback.call(point)
	return true


func hint(target: Node) -> String:
	var record: Dictionary = _targets.get(target.get_instance_id(), {}) if _valid else {}
	return str(record.get("hint", ""))


func invalidate() -> void:
	if not _valid:
		return
	_valid = false
	for record in _targets.values():
		var target: Node = record.node
		if is_instance_valid(target) and target.has_meta(META) and target.get_meta(META) == self:
			target.remove_meta(META)
	_targets.clear()
	_root = null


func _owns(target: Node) -> bool:
	if not is_instance_valid(_root) or not is_instance_valid(target):
		return false
	return target == _root or _root.is_ancestor_of(target)
