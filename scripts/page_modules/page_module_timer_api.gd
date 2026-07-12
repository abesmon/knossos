class_name PageModuleTimerAPI
extends RefCounted

## Lifecycle-safe timers owned by one component context.

var _root: Node
var _valid := true
var _next_id := 1
var _timers: Dictionary = {}


func _init(root: Node) -> void:
	_root = root


func start(seconds: float, callback: Callable, repeat := false) -> int:
	if not _valid or not is_instance_valid(_root) or not callback.is_valid() or seconds <= 0.0:
		return 0
	var id := _next_id
	_next_id += 1
	var timer := Timer.new()
	timer.one_shot = not repeat
	timer.wait_time = seconds
	_timers[id] = timer
	_root.add_child(timer)
	timer.timeout.connect(func():
		if not _valid or not _timers.has(id):
			return
		callback.call()
		if not repeat:
			cancel(id)
	)
	timer.start()
	return id


func cancel(id: int) -> bool:
	if not _timers.has(id):
		return false
	var timer: Timer = _timers[id]
	_timers.erase(id)
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
	return true


func cancel_all() -> void:
	for id in _timers.keys():
		cancel(id)


func invalidate() -> void:
	if not _valid:
		return
	_valid = false
	cancel_all()
	_root = null
