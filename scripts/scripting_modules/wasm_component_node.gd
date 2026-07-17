class_name WasmComponentNode
extends Node3D

var _unmount_callback := Callable()


func configure_unmount(callback: Callable) -> void:
	_unmount_callback = callback


func _notification(what: int) -> void:
	if what != NOTIFICATION_EXIT_TREE and what != NOTIFICATION_PREDELETE:
		return
	if not _unmount_callback.is_valid():
		return
	var callback := _unmount_callback
	_unmount_callback = Callable()
	callback.call()
