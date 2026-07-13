class_name VrwebContentPolicy
extends RefCounted

## Single decision boundary for declarative VRWeb content. The initial policy is deliberately
## permissive: all modes observe content, but no rule denies it until rules are added explicitly.

enum Mode { ALLOW_ALL, AUDIT, ENFORCE }

const SOURCE_DOCUMENT := "document"
const SOURCE_LIVE_PEER := "live_peer"

var mode: Mode = Mode.ALLOW_ALL
var _class_counts: Dictionary = {}
var _property_counts: Dictionary = {}
var _mutation_counts: Dictionary = {}
var _resource_counts: Dictionary = {}
var _operation_counts: Dictionary = {}
var _source_counts: Dictionary = {}


func _init(p_mode: Mode = Mode.ALLOW_ALL) -> void:
	mode = p_mode


func evaluate_element(tag: String, attrs: Dictionary, context: Dictionary = {}) -> Dictionary:
	_record(_class_counts, tag)
	_record_source(context)
	for property_name in attrs:
		_record(_property_counts, "%s.%s" % [tag, str(property_name)])
	return _allow()


func evaluate_property(class_label: String, property_name: String, _raw_value: String,
		context: Dictionary = {}) -> Dictionary:
	_record(_mutation_counts, "%s.%s" % [class_label, property_name])
	_record_source(context)
	return _allow()


func evaluate_resource(resource_type: String, attrs: Dictionary,
		context: Dictionary = {}) -> Dictionary:
	_record(_resource_counts, resource_type)
	_record_source(context)
	for property_name in attrs:
		_record(_property_counts, "%s.%s" % [resource_type, str(property_name)])
	return _allow()


func evaluate_operation(operation: String, _payload: Dictionary,
		context: Dictionary = {}) -> Dictionary:
	_record(_operation_counts, operation)
	_record_source(context)
	return _allow()


func snapshot() -> Dictionary:
	return {
		"mode": mode,
		"classes": _class_counts.duplicate(),
		"properties": _property_counts.duplicate(),
		"mutations": _mutation_counts.duplicate(),
		"resources": _resource_counts.duplicate(),
		"operations": _operation_counts.duplicate(),
		"sources": _source_counts.duplicate(),
	}


func reset_audit() -> void:
	_class_counts.clear()
	_property_counts.clear()
	_mutation_counts.clear()
	_resource_counts.clear()
	_operation_counts.clear()
	_source_counts.clear()


static func allowed(decision: Dictionary) -> bool:
	return bool(decision.get("allowed", false))


static func _allow() -> Dictionary:
	return {"allowed": true, "reason": "", "rule": "allow_all"}


func _record_source(context: Dictionary) -> void:
	_record(_source_counts, str(context.get("source", "unknown")))


static func _record(target: Dictionary, key: String) -> void:
	target[key] = int(target.get(key, 0)) + 1
