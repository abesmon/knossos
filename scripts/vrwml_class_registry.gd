@tool
class_name VrwmlClassRegistry
extends RefCounted

## Публичные VRWML-классы, чья семантика принадлежит формату, а реализация Knossos живёт в
## GDScript. Обычные engine-классы по-прежнему создаёт ClassDB. Registry нужен симметрично:
## exporter заменяет внутренний Script на публичное имя тега, builder создаёт локальную
## реализацию этого тега без поставки Script в документе.

const NODE_SCRIPTS := {
	"Avatar": preload("res://actors/avatar/avatar.gd"),
	"AvatarAnimationTreeApplier": preload("res://actors/avatar/appliers/avatar_animation_tree_applier.gd"),
	"LookPitchApplier": preload("res://actors/avatar/appliers/look_pitch_applier.gd"),
	"VoiceScaleApplier": preload("res://actors/avatar/appliers/voice_scale_applier.gd"),
	"UserTextureApplier": preload("res://actors/avatar/appliers/user_texture_applier.gd"),
}

const RESOURCE_SCRIPTS := {
	"AvatarParamBinding": preload("res://actors/avatar/appliers/avatar_param_binding.gd"),
	"UserSettingsAvatarTexture": preload("res://actors/avatar/user_settings_avatar_texture.gd"),
}


static func public_name(obj: Object) -> String:
	if obj == null or not obj.has_method("get_script"):
		return ""
	var script: Script = obj.get_script()
	if script == null:
		return ""
	for tag in NODE_SCRIPTS:
		if NODE_SCRIPTS[tag] == script:
			return tag
	for tag in RESOURCE_SCRIPTS:
		if RESOURCE_SCRIPTS[tag] == script:
			return tag
	return ""


static func instantiate_node(tag: String) -> Node:
	var script: Script = NODE_SCRIPTS.get(tag)
	if script == null:
		return null
	return script.new() as Node


static func instantiate_resource(tag: String) -> Resource:
	var script: Script = RESOURCE_SCRIPTS.get(tag)
	if script == null:
		return null
	return script.new() as Resource


static func instantiate(tag: String) -> Object:
	var node := instantiate_node(tag)
	if node != null:
		return node
	return instantiate_resource(tag)


static func is_node_tag(tag: String) -> bool:
	return NODE_SCRIPTS.has(tag)


static func is_resource_tag(tag: String) -> bool:
	return RESOURCE_SCRIPTS.has(tag)
