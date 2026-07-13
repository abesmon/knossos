extends Node

var _failed := false


func _ready() -> void:
	var source := """
extends Node
var mount_seen := false
func mount(context):
    mount_seen = context.features.has("vrweb/core/1") and context.has("lifecycle/1") \
        and context.scene.root() == self and context.scene_root() == self
func unmount():
    pass
"""
	var doc := HtmlParser.parse('<script type="application/vrweb+gdscript" id="life">%s</script>' % source)
	var collected := ScriptingModuleCollector.collect(doc, "vrwebresource://life.html")
	var registry := ScriptingModuleRegistry.new()
	registry.prepare(collected.modules, ScriptingModuleRegistry.ScriptMode.ALLOW_ALL)
	var made := registry.instantiate_export("life", "default")
	var made_second := registry.instantiate_export("life", "default")
	_eq(str(made.error), "", "lifecycle component instantiates")
	var component: Node = made.node
	var component_second: Node = made_second.node
	var context: ScriptingModuleContext = made.context
	var context_second: ScriptingModuleContext = made_second.context
	add_child(component)
	add_child(component_second)
	await get_tree().process_frame
	_eq(component.get("mount_seen"), true, "mount receives valid scoped context")
	_eq(context.mounted, true, "context records mount")
	_eq(context.features.has("vrweb/scene/1"), true, "context advertises portable scene API")
	_eq(context.features.has("godot/engine/4"), true, "trusted runtime advertises Godot API")
	_eq(context.features.has("vrweb/unknown/1"), false, "unknown capability is absent")
	var target := StaticBody3D.new()
	component.add_child(target)
	var activation := {"seen": false}
	_eq(context.input.on_activate(target, func(_point): activation.seen = true, "Toggle light"), true,
			"input activation can bind an owned collider")
	_eq(context.input.hint(target), "Toggle light", "input exposes portable aim hint")
	_eq(context.input.dispatch(target, Vector3.ZERO), true, "host dispatches activation")
	_eq(activation.seen, true, "activation invokes module callback")
	var foreign := StaticBody3D.new()
	add_child(foreign)
	_eq(context.input.on_activate(foreign, func(_point): pass), false,
			"input rejects collider outside component branch")
	foreign.queue_free()
	_eq(context.state == context_second.state, true, "components share module-level state facade")
	var schema := {
		"version": 1,
		"fields": {"enabled": {"type": "bool", "default": false}},
		"default_write_rule": "authority",
		"commands": {"toggle": {"reducer": Callable(self, "_reduce_toggle")}},
	}
	_eq(context.state.register_schema("switch", schema), true, "module registers namespaced schema")
	_eq(context.state.ensure_object("lamp", "switch", {"enabled": false}), true,
			"module registers namespaced object")
	_eq(context.state.read("lamp", "switch").get("enabled"), false, "module reads state")
	var timer_called := false
	var timer_id := context.timers.start(10.0, func(): timer_called = true)
	_eq(context.has("timers/1"), true, "context advertises lifecycle-safe timers")
	_eq(timer_id > 0, true, "context starts timer")
	component.queue_free()
	await get_tree().process_frame
	_eq(context.unmounted, true, "unmount runs on tree exit")
	_eq(context.valid, false, "context invalidated after unmount")
	_eq(context.scene_root(), null, "invalid context releases scene root")
	_eq(context.timers.cancel(timer_id), false, "unmount cancels owned timers")
	_eq(timer_called, false, "cancelled timer callback was not invoked")
	_eq(context.assets.has("anything"), false, "unmount invalidates asset facade")
	_eq(is_instance_valid(target), false, "owned input target leaves with component")
	_eq(context_second.state.is_closed(), false, "first component does not close shared state")
	component_second.queue_free()
	await get_tree().process_frame
	_eq(context_second.state.is_closed(), true, "last component closes shared state")
	get_tree().quit(1 if _failed else 0)


func _reduce_toggle(state: Dictionary, _args: Dictionary, _context: Dictionary) -> Dictionary:
	return {"enabled": not bool(state.get("enabled", false))}


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
