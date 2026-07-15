class_name ScriptingModuleFeaturesAPI
extends RefCounted

## Versioned capability discovery for portable scripting modules.

var _available: Dictionary
var _valid := true


func _init(available: Dictionary) -> void:
	_available = available.duplicate()


func has(feature: String) -> bool:
	return _valid and bool(_available.get(feature, false))


func require(feature: String) -> bool:
	if has(feature):
		return true
	if _valid:
		Log.warn("scripting-module", "required capability is unavailable: %s" % feature)
	return false


func invalidate() -> void:
	_valid = false
	_available.clear()
