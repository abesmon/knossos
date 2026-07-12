class_name PageModuleSession
extends RefCounted

## Общие сервисы всех component instances одного module/hash в рамках страницы.

var module_id: String
var module_hash: String
var state: PageModuleStateAPI
var active_components := 0
var closed := false


func _init(p_module_id: String, p_hash: String) -> void:
	module_id = p_module_id
	module_hash = p_hash
	state = PageModuleStateAPI.new(module_id)


func acquire() -> void:
	if not closed:
		active_components += 1


func release() -> void:
	if closed:
		return
	active_components = maxi(0, active_components - 1)
	if active_components == 0:
		close()


func close() -> void:
	if closed:
		return
	closed = true
	state.close()
