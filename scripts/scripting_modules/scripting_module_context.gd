class_name ScriptingModuleContext
extends RefCounted

## Первая минимальная версия compatibility facade. Trusted GDScript может обойти её, но
## module-код, использующий публичный API, получает явный lifecycle и feature detection.

var module_id: String
var module_hash: String
var origin: String
var root: Node
var scene: ScriptingModuleSceneAPI
var state: ScriptingModuleStateAPI
var timers: ScriptingModuleTimerAPI
var assets: ScriptingModuleAssetAPI
var input: ScriptingModuleInputAPI
var features: ScriptingModuleFeaturesAPI
var log: ScriptingModuleLogAPI
var _session: ScriptingModuleSession
var valid := true
var mounted := false
var unmounted := false


func _init(p_module_id: String, p_hash: String, p_root: Node,
		p_session: ScriptingModuleSession, module_root := "", module_assets: Dictionary = {},
		p_origin := "", capabilities: Dictionary = {}) -> void:
	module_id = p_module_id
	module_hash = p_hash
	origin = p_origin
	root = p_root
	_session = p_session
	scene = ScriptingModuleSceneAPI.new(p_root)
	state = p_session.state
	timers = ScriptingModuleTimerAPI.new(p_root)
	assets = ScriptingModuleAssetAPI.new(module_root, module_assets)
	input = ScriptingModuleInputAPI.new(p_root)
	features = ScriptingModuleFeaturesAPI.new(capabilities)
	log = ScriptingModuleLogAPI.new(module_id, module_hash)


func has(feature: String) -> bool:
	if not valid:
		return false
	var aliases := {"lifecycle/1": "vrweb/core/1", "scene-root/1": "vrweb/scene/1",
		"replicated-state/1": "vrweb/state/1", "timers/1": "vrweb/timers/1",
		"assets/1": "vrweb/assets/1"}
	return features.has(str(aliases.get(feature, feature)))


func scene_root() -> Node:
	return root if valid and is_instance_valid(root) else null


func log_message(message: String) -> void:
	if valid:
		log.info(message)


func invalidate() -> void:
	if not valid:
		return
	valid = false
	input.invalidate()
	timers.invalidate()
	assets.invalidate()
	scene.invalidate()
	features.invalidate()
	log.invalidate()
	root = null
