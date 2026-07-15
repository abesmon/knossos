extends Node

## Регрессия вложенных UI focus leases: поздний запрос мира не перебивает верхнее окно.


func _ready() -> void:
	var player := Player.new()
	player.capture_mouse(true)
	var address := player.claim_mouse_focus("address")
	var permission := player.claim_mouse_focus("permission")
	player.capture_mouse(true) # завершение Enter после синхронного открытия preflight
	var ok := not player.mouse_is_captured()
	player.release_mouse_focus(address)
	ok = ok and not player.mouse_is_captured()
	player.release_mouse_focus(permission)
	ok = ok and player.mouse_is_captured()
	player.capture_mouse(false)
	player.free()
	if not ok:
		push_error("FAIL: nested mouse focus lease was overridden")
	get_tree().quit(0 if ok else 1)
