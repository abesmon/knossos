class_name VrwebScriptScene
extends RefCounted

## Capability vrweb/scene-objects/1: доступ page script к эфемерному слою сцены
## (docs/network/ephemeral-changes.md). Скрипт действует ОТ ИМЕНИ локального пользователя:
## действия идут обычным путём request_scene_action_tracked, авторитет валидирует их против
## своих прав (bindings + ranks) — мост не добавляет собственной модели прав.
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


## api из лямбд фиксированной арности: доверенный bootstrap добивает опущенные хвостовые
## аргументы (callback) значением nil по манифесту арности.
func api() -> Dictionary:
	return {
		"add": func(spec, callback = null): return add_object(spec, callback),
		"update": func(id, props, callback = null): return update_object(id, props, callback),
		"remove": func(id, callback = null): return remove_object(id, callback),
		"object": func(id): return read_object(id),
		"objects": func(kind = null): return list_objects(kind),
	}


## add(spec, callback?) -> id|nil,code. spec: {kind, parent?, ttl?, props?}. id генерится
## клиентом (адрес СВОЕГО объекта — по нему же update/remove). Исход коммита авторитетом
## придёт в callback {ok, id, error}; без callback действие best-effort (как пузырь).
func add_object(spec, callback):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if typeof(spec) != TYPE_DICTIONARY:
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var kind := str((spec as Dictionary).get("kind", ""))
	if kind.is_empty() or kind.to_utf8_buffer().size() > MAX_KIND_BYTES:
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var parent := str((spec as Dictionary).get("parent", ""))
	if parent.to_utf8_buffer().size() > MAX_PARENT_BYTES:
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var ttl := maxf(0.0, float((spec as Dictionary).get("ttl", 0.0)))
	var props = (spec as Dictionary).get("props", {})
	if props == null or (props is Array and (props as Array).is_empty()):
		props = {}
	if typeof(props) != TYPE_DICTIONARY:
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var id := NetworkManager.new_object_id()
	var action := {"op": SceneChanges.OP_ADD, "id": id, "kind": kind, "parent": parent,
		"ttl": ttl, "props": (props as Dictionary).duplicate(true)}
	_dispatch(action, id, callback)
	return id


func update_object(id, props, callback):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if typeof(props) != TYPE_DICTIONARY or str(id).is_empty():
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	_dispatch({"op": SceneChanges.OP_UPDATE, "id": str(id),
		"props": (props as Dictionary).duplicate(true)}, str(id), callback)
	return true


func remove_object(id, callback):
	if _closed:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if str(id).is_empty():
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	_dispatch({"op": SceneChanges.OP_REMOVE, "id": str(id)}, str(id), callback)
	return true


## Плоские данные объекта слоя (или {}): скрипту отдаётся копия без движковых типов.
func read_object(id) -> Dictionary:
	if _closed:
		return {}
	var object := NetworkManager.scene_object(str(id))
	return object.duplicate(true)


## Перечисление объектов слоя (опционально по kind) — для инструментов-модификаторов
## (ластик, клинеры): массив плоских данных. Размер ограничен самим слоем (MAX_OBJECTS).
func list_objects(kind) -> Array:
	if _closed:
		return []
	var wanted := "" if kind == null else str(kind)
	var result: Array = []
	var objects := NetworkManager.scene_objects()
	for id in objects:
		var object: Dictionary = objects[id]
		if wanted != "" and str(object.get("kind", "")) != wanted:
			continue
		result.append(object.duplicate(true))
	return result


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
		# Отказ авторитета — семантический deny слоя (права/лимиты), а не структурная ошибка.
		_invoke.call(cb, {"ok": accepted, "id": str(entry.id),
			"error": "" if accepted else VrwebScriptError.DENIED})
