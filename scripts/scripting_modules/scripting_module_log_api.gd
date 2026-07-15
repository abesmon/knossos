class_name ScriptingModuleLogAPI
extends RefCounted

## Structured module logging without exposing cache paths to page code.

var _prefix: String
var _valid := true


func _init(module_id: String, module_hash: String) -> void:
	_prefix = "module:%s:%s" % [module_id, module_hash.left(12)]


func debug(message: Variant) -> void:
	if _valid:
		Log.info(_prefix, "DEBUG: " + str(message))


func info(message: Variant) -> void:
	if _valid:
		Log.info(_prefix, str(message))


func warning(message: Variant) -> void:
	if _valid:
		Log.warn(_prefix, str(message))


func error(message: Variant) -> void:
	if _valid:
		Log.err(_prefix, str(message))


func invalidate() -> void:
	_valid = false
