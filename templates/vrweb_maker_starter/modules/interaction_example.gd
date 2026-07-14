extends StaticBody3D

## Copy this script onto a collider node, select "package" in the VRWeb dock, then set module
## metadata. The context is the portable VRWeb Scripting API; no Knossos class is referenced.

var _context
var _timer_id := 0


func mount(context) -> void:
	_context = context
	context.log.info("interaction example mounted")
	if not context.input.on_activate(self, _on_activate, "Activate example"):
		context.log.warning("activate target must be a collider inside this component")
	var schema := {
		"version": 1,
		"fields": {"count": {"type": "int", "default": 0}},
		"default_write_rule": "authority",
		"commands": {"increment": {"reducer": _reduce_increment}},
	}
	if context.state.register_schema("counter", schema) \
			and context.state.ensure_object("main", "counter", {"count": 0}):
		context.state.subscribe("main", "counter", _on_state)
		_on_state(context.state.read("main", "counter"), {}, 0)
	if context.assets.has("message"):
		context.log.debug(context.assets.text("message"))
	_timer_id = context.timers.start(5.0, _on_timer, true)


func unmount() -> void:
	# The host also cancels owned timers/input/subscriptions, but explicit cleanup documents intent.
	if _context != null:
		_context.input.off_activate(self)
		if _timer_id > 0:
			_context.timers.cancel(_timer_id)
	_context = null


func _on_activate(_point: Vector3) -> void:
	if _context != null:
		_context.state.command("main", "counter", 1, "increment")


func _reduce_increment(state: Dictionary, _args: Dictionary,
		_command_context: Dictionary) -> Dictionary:
	return {"count": int(state.get("count", 0)) + 1}


func _on_state(state: Dictionary, _changed: Dictionary, _revision: int) -> void:
	if _context != null:
		_context.log.info("count = %d" % int(state.get("count", 0)))


func _on_timer() -> void:
	if _context != null:
		_context.log.debug("example timer tick")
