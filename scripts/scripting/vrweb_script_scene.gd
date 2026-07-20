class_name VrwebScriptScene
extends RefCounted

## Capability vrweb/scene-objects/1: доступ page script к эфемерному слою сцены
## (docs/network/ephemeral-changes.md). Скрипт действует ОТ ИМЕНИ локального пользователя:
## действия идут обычным путём request_scene_action_tracked, авторитет валидирует их против
## своих прав (владение по author, ранги) — мост не добавляет собственной модели прав.
## Kind не ограничивается allowlist'ом: авторитет и content policy — единственные судьи
## (модель браузера, docs/space/portable-tools.md).

const MAX_KIND_BYTES := 64
const MAX_PARENT_BYTES := 256

var _script_id := ""
var _invoke: Callable
var _closed := false
var _staging := true
var _pending: Array[Dictionary] = []
var _tokens: Dictionary = {}   # token -> {callback: Callable, id: String}
var _connected := false


func setup(script_id: String, invoke: Callable) -> void:
	_script_id = script_id
	_invoke = invoke


func api() -> Dictionary:
	return {
		"add": add_object,
		"update": update_object,
		"remove": remove_object,
		"object": read_object,
	}


## add(spec, callback?) -> id|nil. spec: {kind, parent?, ttl?, props?}. id генерится клиентом
## (адрес СВОЕГО объекта — по нему же update/remove). Исход коммита авторитетом придёт в
## callback {ok, id}; без callback действие best-effort (как пузырь).
func add_object(spec, callback = null):
	if _closed or typeof(spec) != TYPE_DICTIONARY:
		return null
	var kind := str((spec as Dictionary).get("kind", ""))
	if kind.is_empty() or kind.to_utf8_buffer().size() > MAX_KIND_BYTES:
		return null
	var parent := str((spec as Dictionary).get("parent", ""))
	if parent.to_utf8_buffer().size() > MAX_PARENT_BYTES:
		return null
	var ttl := maxf(0.0, float((spec as Dictionary).get("ttl", 0.0)))
	var props = (spec as Dictionary).get("props", {})
	if typeof(props) != TYPE_DICTIONARY:
		return null
	var id := NetworkManager.new_object_id()
	var action := {"op": SceneChanges.OP_ADD, "id": id, "kind": kind, "parent": parent,
		"ttl": ttl, "props": (props as Dictionary).duplicate(true)}
	_dispatch(action, id, callback)
	return id


func update_object(id, props, callback = null) -> bool:
	if _closed or typeof(props) != TYPE_DICTIONARY or str(id).is_empty():
		return false
	_dispatch({"op": SceneChanges.OP_UPDATE, "id": str(id),
		"props": (props as Dictionary).duplicate(true)}, str(id), callback)
	return true


func remove_object(id, callback = null) -> bool:
	if _closed or str(id).is_empty():
		return false
	_dispatch({"op": SceneChanges.OP_REMOVE, "id": str(id)}, str(id), callback)
	return true


## Плоские данные объекта слоя (или {}): скрипту отдаётся копия без движковых типов.
func read_object(id) -> Dictionary:
	if _closed:
		return {}
	var object := NetworkManager.scene_object(str(id))
	return object.duplicate(true)


## Top-level стейджится как остальные мосты: действия уходят только после успешного commit
## realm — неудавшийся скрипт не оставляет следов в общем мире.
func commit() -> bool:
	if _closed:
		return false
	_staging = false
	for entry in _pending:
		_send(entry.action, str(entry.id), entry.callback)
	_pending.clear()
	return true


func close() -> void:
	if _closed:
		return
	_closed = true
	# Объекты слоя принадлежат ПОЛЬЗОВАТЕЛЮ, а не realm: закрытие страницы/замена скрипта их
	## не удаляет (артефакты — как штрихи карандаша). Снимаем только ожидания ack.
	if _connected and NetworkManager.scene_action_acked.is_connected(_on_acked):
		NetworkManager.scene_action_acked.disconnect(_on_acked)
	_connected = false
	_tokens.clear()
	_pending.clear()
	_invoke = Callable()


func _dispatch(action: Dictionary, id: String, callback) -> void:
	if _staging:
		_pending.append({"action": action, "id": id, "callback": callback})
	else:
		_send(action, id, callback)


func _send(action: Dictionary, id: String, callback) -> void:
	var cb := callback as Callable if callback is Callable else Callable()
	if not cb.is_valid():
		NetworkManager.request_scene_action(action)
		return
	if not _connected:
		NetworkManager.scene_action_acked.connect(_on_acked)
		_connected = true
	var token := NetworkManager.request_scene_action_tracked(action)
	_tokens[token] = {"callback": cb, "id": id}


func _on_acked(token: int, accepted: bool) -> void:
	if _closed or not _tokens.has(token):
		return
	var entry: Dictionary = _tokens[token]
	_tokens.erase(token)
	var cb: Callable = entry.callback
	if cb.is_valid() and _invoke.is_valid():
		_invoke.call(cb, {"ok": accepted, "id": str(entry.id)})
