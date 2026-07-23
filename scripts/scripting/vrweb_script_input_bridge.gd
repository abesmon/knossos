class_name VrwebScriptInputBridge
extends RefCounted

const META := "vrweb_script_input"

var _target: Node
var _callback: Callable
var _hint := ""
var _valid := true


func setup(target: Node, callback: Callable, hint: String) -> void:
	_target = target
	_callback = callback
	_hint = hint
	target.set_meta(META, self)


func dispatch(point: Vector3) -> bool:
	if not _valid or not _callback.is_valid():
		return false
	_callback.call({"type": "activate", "point": point})
	return true


func hint() -> String:
	return _hint if _valid else ""


func close() -> void:
	if not _valid:
		return
	_valid = false
	if is_instance_valid(_target) and _target.has_meta(META) and _target.get_meta(META) == self:
		_target.remove_meta(META)
	_target = null
	_callback = Callable()

