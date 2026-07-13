class_name AvatarVrwmlPolicy
extends VrwebContentPolicy

## Контекстная allowlist для документа, который AvatarResolver загружает как аватар. Сам файл
## ничего не заявляет о своей честности: policy выбирает consumer. Первая версия намеренно
## покрывает классы двух встроенных аватаров; новые стандартные возможности добавляются явно.

const NODE_TAGS := {
	"Avatar": true,
	"Node3D": true,
	"MeshInstance3D": true,
	"AnimationTree": true,
	"AvatarAnimationTreeApplier": true,
	"LookPitchApplier": true,
	"VoiceScaleApplier": true,
	"UserTextureApplier": true,
	"ExtScene": true,
}

const RESOURCE_TYPES := {
	"CapsuleMesh": true,
	"BoxMesh": true,
	"QuadMesh": true,
	"SphereMesh": true,
	"ArrayMesh": true,
	"StandardMaterial3D": true,
	"AvatarParamBinding": true,
	"UserSettingsAvatarTexture": true,
	"Texture2D": true,
	"ImageTexture": true,
	"CompressedTexture2D": true,
	"Mesh": true,
	"PackedScene": true,
}

const DENIED_PROPERTIES := {
	"script": true,
	"source_code": true,
}

const MAX_NODES := 2048
const MAX_RESOURCES := 512
const MAX_PROPERTIES := 8192

var _nodes := 0
var _resources := 0
var _properties := 0
var diagnostics: Array[Dictionary] = []


func _init() -> void:
	super(Mode.ENFORCE)


func evaluate_element(tag: String, attrs: Dictionary, _context: Dictionary = {}) -> Dictionary:
	_nodes += 1
	_properties += attrs.size()
	return _decision(NODE_TAGS.has(tag) and _nodes <= MAX_NODES \
			and _properties <= MAX_PROPERTIES, "avatar.node.%s" % tag)


func evaluate_property(_class_label: String, property_name: String, _raw_value: String,
		_context: Dictionary = {}) -> Dictionary:
	_properties += 1
	return _decision(not DENIED_PROPERTIES.has(property_name) and _properties <= MAX_PROPERTIES,
			"avatar.property.%s" % property_name)


func evaluate_resource(resource_type: String, attrs: Dictionary,
		_context: Dictionary = {}) -> Dictionary:
	_resources += 1
	_properties += attrs.size()
	return _decision(RESOURCE_TYPES.has(resource_type) and _resources <= MAX_RESOURCES \
			and _properties <= MAX_PROPERTIES, "avatar.resource.%s" % resource_type)


func has_errors() -> bool:
	return not diagnostics.is_empty()


func summary() -> String:
	if diagnostics.is_empty():
		return ""
	var rules: Array[String] = []
	for item in diagnostics:
		var rule := str(item.get("rule", "avatar.unknown"))
		if not rules.has(rule):
			rules.append(rule)
	return ", ".join(rules)


func _decision(is_allowed: bool, rule: String) -> Dictionary:
	var decision := {
		"allowed": is_allowed,
		"reason": "" if is_allowed else "не разрешено в контексте аватара",
		"rule": rule,
	}
	if not is_allowed and diagnostics.size() < 100:
		diagnostics.append(decision.duplicate())
	return decision
