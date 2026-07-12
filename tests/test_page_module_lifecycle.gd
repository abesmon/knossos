extends Node

var _failed := false


func _ready() -> void:
	var source := """
extends Node
var mount_seen := false
func mount(context):
    mount_seen = context.has("lifecycle/1") and context.scene_root() == self
func unmount():
    pass
"""
	var doc := HtmlParser.parse('<script type="application/vrweb+gdscript" id="life">%s</script>' % source)
	var collected := PageModuleCollector.collect(doc, "vrwebresource://life.html")
	var registry := PageModuleRegistry.new()
	registry.prepare(collected.modules, PageModuleRegistry.ScriptMode.ALLOW_ALL)
	var made := registry.instantiate_export("life", "default")
	var made_second := registry.instantiate_export("life", "default")
	_eq(str(made.error), "", "lifecycle component instantiates")
	var component: Node = made.node
	var component_second: Node = made_second.node
	var context: PageModuleContext = made.context
	var context_second: PageModuleContext = made_second.context
	add_child(component)
	add_child(component_second)
	await get_tree().process_frame
	_eq(component.get("mount_seen"), true, "mount receives valid scoped context")
	_eq(context.mounted, true, "context records mount")
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
