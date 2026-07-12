class_name PageModuleContext
extends RefCounted

## Первая минимальная версия compatibility facade. Trusted GDScript может обойти её, но
## module-код, использующий публичный API, получает явный lifecycle и feature detection.

var module_id: String
var module_hash: String
var root: Node
var state: PageModuleStateAPI
var timers: PageModuleTimerAPI
var assets: PageModuleAssetAPI
var _session: PageModuleSession
var valid := true
var mounted := false
var unmounted := false


func _init(p_module_id: String, p_hash: String, p_root: Node,
		p_session: PageModuleSession, module_root := "", module_assets: Dictionary = {}) -> void:
	module_id = p_module_id
	module_hash = p_hash
	root = p_root
	_session = p_session
	state = p_session.state
	timers = PageModuleTimerAPI.new(p_root)
	assets = PageModuleAssetAPI.new(module_root, module_assets)


func has(feature: String) -> bool:
	return valid and feature in ["lifecycle/1", "scene-root/1", "replicated-state/1", "timers/1",
			"assets/1"]


func scene_root() -> Node:
	return root if valid and is_instance_valid(root) else null


func log_message(message: String) -> void:
	if valid:
		Log.info("module:%s" % module_id, message)


func invalidate() -> void:
	if not valid:
		return
	valid = false
	timers.invalidate()
	assets.invalidate()
	root = null
