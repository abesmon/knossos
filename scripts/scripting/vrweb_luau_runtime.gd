class_name VrwebLuauRuntime
extends Node

## One browser-like Luau realm per page. Script tags execute in document order and share globals.

signal script_failed(script_id: String, phase: String, message: String)
signal script_replaced(script_id: String, old_hash: String, new_hash: String)

const TOP_LEVEL_BUDGET_MS := 75
const CALLBACK_BUDGET_MS := 25
const SOFT_MEMORY_BYTES := 16 * 1024 * 1024
const SAFE_LIBS := LuaState.LIB_BASE | LuaState.LIB_COROUTINE | LuaState.LIB_TABLE \
		| LuaState.LIB_STRING | LuaState.LIB_BIT32 | LuaState.LIB_BUFFER | LuaState.LIB_UTF8 \
		| LuaState.LIB_MATH | LuaState.LIB_VECTOR

## Провайдер OS-диалога выбора файла для document.files.pick (владелец runtime — main —
## задаёт до activate; item-runtime получает его через контекст EphemeralView).
var file_picker: Callable = Callable()

var _realm: Dictionary = {}
var _declarations: Array[Dictionary] = []
var _active_hashes: Dictionary = {}
var _page_id := ""
var _page_root: Node
var _targets: Dictionary = {}
var _base_url := ""
var _player: Node
var _policy: VrwebContentPolicy
var _deadline_by_script: Dictionary = {}
var _limit_reason_by_script: Dictionary = {}
var _active_execution_id := ""
var _closed := false
var _scene_time := 0.0


func _process(delta: float) -> void:
	if _closed or _realm.is_empty():
		return
	_scene_time += delta
	var host: VrwebDocumentHost = _realm.get("host")
	if host != null:
		host.update(delta, _clock_snapshot())


func _exit_tree() -> void:
	close()


func setup(page_root: Node, targets: Dictionary, base_url: String, player: Node,
		policy: VrwebContentPolicy) -> void:
	_page_root = page_root
	_targets = targets.duplicate()
	_base_url = base_url
	_player = player
	_policy = policy
	_scene_time = 0.0


func activate(scripts: Array) -> Dictionary:
	if _closed or not _realm.is_empty():
		return {"ok": false, "activated": [], "errors": [{"script_id": "", "phase": "lookup",
			"message": "runtime is closed or the page realm is already active"}]}
	var prepared := _prepare_page(scripts, {})
	var errors: Array = prepared.errors
	if (prepared.realm as Dictionary).is_empty():
		return {"ok": false, "activated": [], "errors": errors}
	_realm = prepared.realm
	_page_id = str(_realm.id)
	if not (_realm.host as VrwebDocumentHost).commit():
		_dispose_realm(_realm, false)
		_realm = {}
		for declaration in prepared.declarations:
			errors.append({"script_id": str(declaration.id), "phase": "commit",
				"message": "document staging commit failed"})
		return {"ok": false, "activated": [], "errors": errors}
	_declarations.assign(prepared.declarations)
	_rebuild_active_hashes()
	var activated: Array[String] = []
	for declaration in _declarations:
		activated.append(str(declaration.id))
	return {"ok": errors.is_empty(), "activated": activated, "errors": errors}


## A source replacement rebuilds the whole shared page realm atomically. Later scripts may have
## captured globals declared by the replaced source, so replacing only one closure set would leave
## the page in a state browsers cannot produce from its document.
func replace(script_id: String, source: String, base_hash := "") -> Dictionary:
	if _closed or _realm.is_empty() or not _active_hashes.has(script_id):
		return _error("lookup", "script is not active")
	var old_hash := str(_active_hashes[script_id])
	if not base_hash.is_empty() and old_hash != base_hash:
		return _error("revision", "base hash does not match active revision")
	_snapshot_session(_realm)
	var next_declarations: Array[Dictionary] = []
	for current in _declarations:
		var declaration: Dictionary = current.duplicate(true)
		if str(declaration.id) == script_id:
			declaration["source"] = source
			declaration["kind"] = "inline"
			declaration["src"] = ""
			declaration["integrity"] = ""
			declaration["hash"] = source.sha256_text()
		next_declarations.append(declaration)
	var prepared := _prepare_page(next_declarations,
			(_realm.host as VrwebDocumentHost).session)
	if not (prepared.errors as Array).is_empty() or (prepared.realm as Dictionary).is_empty():
		if not (prepared.realm as Dictionary).is_empty():
			_dispose_realm(prepared.realm, false)
		var first: Dictionary = (prepared.errors as Array)[0] if not \
				(prepared.errors as Array).is_empty() else {"phase": "load", "message": "source rejected"}
		return _error(str(first.phase), str(first.message))
	var old := _realm
	var candidate: Dictionary = prepared.realm
	(old.host as VrwebDocumentHost).snapshot_replicated_state()
	_realm = candidate
	_page_id = str(candidate.id)
	if not (candidate.host as VrwebDocumentHost).commit():
		_realm = old
		_page_id = str(old.id)
		_dispose_realm(candidate, false)
		(old.host as VrwebDocumentHost).restore_replicated_state()
		return _error("commit", "candidate page realm could not commit")
	(old.host as VrwebDocumentHost).retire_for_replacement(candidate.host)
	_close_lua_state(old)
	_declarations.assign(prepared.declarations)
	_rebuild_active_hashes()
	script_replaced.emit(script_id, old_hash, str(_active_hashes[script_id]))
	return {"ok": true, "script_id": script_id, "old_hash": old_hash,
		"new_hash": str(_active_hashes[script_id]), "phase": "", "error": ""}


func remove(script_id: String) -> bool:
	if _realm.is_empty() or not _active_hashes.has(script_id):
		return false
	var remaining: Array[Dictionary] = []
	for declaration in _declarations:
		if str(declaration.id) != script_id:
			remaining.append(declaration.duplicate(true))
	if remaining.is_empty():
		_dispose_realm(_realm, false)
		_realm = {}
		_declarations.clear()
		_active_hashes.clear()
		_page_id = ""
		return true
	_snapshot_session(_realm)
	var prepared := _prepare_page(remaining, (_realm.host as VrwebDocumentHost).session)
	if not (prepared.errors as Array).is_empty() or (prepared.realm as Dictionary).is_empty():
		if not (prepared.realm as Dictionary).is_empty():
			_dispose_realm(prepared.realm, false)
		return false
	var old := _realm
	var candidate: Dictionary = prepared.realm
	(old.host as VrwebDocumentHost).snapshot_replicated_state()
	_realm = candidate
	_page_id = str(candidate.id)
	if not (candidate.host as VrwebDocumentHost).commit():
		_realm = old
		_page_id = str(old.id)
		_dispose_realm(candidate, false)
		(old.host as VrwebDocumentHost).restore_replicated_state()
		return false
	(old.host as VrwebDocumentHost).retire_for_replacement(candidate.host)
	_close_lua_state(old)
	_declarations.assign(prepared.declarations)
	_rebuild_active_hashes()
	return true


func active_hashes() -> Dictionary:
	return _active_hashes.duplicate()


## Kept script-addressable for the realtime protocol, but session is page-global like browser JS.
func session_of(script_id: String) -> Dictionary:
	if _realm.is_empty() or not _active_hashes.has(script_id):
		return {}
	_snapshot_session(_realm)
	return (_realm.host as VrwebDocumentHost).session.duplicate(true)


func close() -> void:
	if _closed:
		return
	_closed = true
	if not _realm.is_empty():
		_snapshot_session(_realm)
		_dispose_realm(_realm, false)
	_realm = {}
	_declarations.clear()
	_active_hashes.clear()
	_deadline_by_script.clear()
	_limit_reason_by_script.clear()
	_targets.clear()
	_page_root = null
	_player = null


func _prepare_page(scripts: Array, previous_session: Dictionary) -> Dictionary:
	var errors: Array[Dictionary] = []
	var candidates: Array[Dictionary] = []
	var ids := {}
	for value in scripts:
		var declaration: Dictionary = value
		var script_id := str(declaration.get("id", ""))
		var source := str(declaration.get("source", ""))
		if str(declaration.get("profile", "")) != VrwebScriptDeclaration.PROFILE:
			errors.append({"script_id": script_id, "phase": "profile",
				"message": "unsupported runtime profile"})
			continue
		if not VrwebScriptDeclaration.valid_id(script_id) or source.is_empty() \
				or source.to_utf8_buffer().size() > VrwebScriptDeclaration.MAX_SOURCE_BYTES:
			errors.append({"script_id": script_id, "phase": "load",
				"message": "invalid id or source"})
			continue
		if ids.has(script_id):
			errors.append({"script_id": script_id, "phase": "lookup",
				"message": "script id is duplicated"})
			continue
		ids[script_id] = true
		candidates.append(declaration.duplicate(true))
	if candidates.is_empty():
		return {"realm": {}, "declarations": [], "errors": errors}

	var page_id := str(candidates[0].id)
	var combined_hash_source := ""
	for declaration in candidates:
		combined_hash_source += str(declaration.get("hash",
				str(declaration.source).sha256_text())) + "\n"
	var root_state = LuaState.new()
	root_state.open_libs(SAFE_LIBS)
	var host := VrwebDocumentHost.new()
	var invoke := func(callback: Callable, event = {}, wants_result := false):
		return _invoke_page(callback, event, wants_result)
	host.setup(page_id, combined_hash_source.sha256_text(), _page_root, _targets, _base_url,
			_player, self, invoke, previous_session, _policy, _clock_snapshot)
	host.file_picker = file_picker
	root_state.register_library("document", host.api())
	root_state.pop(1)
	root_state.set_interrupts(true)
	# Luau keeps the sandboxed root globals read-only. A sandboxed child thread inherits those
	# safe globals through __index and owns the writable page-global table shared by every tag.
	root_state.sandbox()
	var state = root_state.new_thread()
	root_state.pop(1)
	state.sandbox_thread()
	state.interrupt.connect(_on_interrupt)

	var executed: Array[Dictionary] = []
	for declaration in candidates:
		var script_id := str(declaration.id)
		var source := str(declaration.source)
		var bytecode: PackedByteArray = Luau.compile(source)
		if bytecode.is_empty() or not state.load_bytecode(bytecode,
				"@vrweb-source:///%s.luau" % script_id):
			var message := str(state.to_variant(-1)) if state.get_top() > 0 else "source rejected"
			if state.get_top() > 0:
				state.pop(1)
			errors.append({"script_id": script_id, "phase": "load", "message": message})
			script_failed.emit(script_id, "load", message)
			continue
		_active_execution_id = script_id
		_deadline_by_script[script_id] = Time.get_ticks_msec() + TOP_LEVEL_BUDGET_MS
		_limit_reason_by_script.erase(script_id)
		var status: int = state.pcall(0, 0)
		_deadline_by_script.erase(script_id)
		_active_execution_id = ""
		if status != Luau.LUA_OK:
			var message := str(_limit_reason_by_script.get(script_id,
					str(state.to_variant(-1)) if state.get_top() > 0 else "runtime error"))
			_limit_reason_by_script.erase(script_id)
			if state.get_top() > 0:
				state.pop(1)
			errors.append({"script_id": script_id, "phase": "execute", "message": message})
			script_failed.emit(script_id, "execute", message)
			continue
		executed.append(declaration)
	if executed.is_empty():
		host.close(true)
		root_state.close()
		return {"realm": {}, "declarations": [], "errors": errors}
	var realm := {"id": page_id, "state": state, "root_state": root_state, "host": host}
	_snapshot_session(realm)
	return {"realm": realm, "declarations": executed, "errors": errors}


func _invoke_page(callback: Callable, event, wants_result := false):
	if _closed or not callback.is_valid() or _realm.is_empty():
		# During top-level staging the page realm is not published; callbacks cannot fire there.
		return null
	var state = _realm.state
	if state == null or not state.is_valid():
		return null
	(_realm.host as VrwebDocumentHost).begin_invocation()
	var execution_id := _page_id
	_active_execution_id = execution_id
	_deadline_by_script[execution_id] = Time.get_ticks_msec() + CALLBACK_BUDGET_MS
	_limit_reason_by_script.erase(execution_id)
	state.push_callable(callback)
	state.push_variant(event)
	var status: int = state.pcall(1, 1 if wants_result else 0)
	_deadline_by_script.erase(execution_id)
	_active_execution_id = ""
	var limit_reason := str(_limit_reason_by_script.get(execution_id, ""))
	_limit_reason_by_script.erase(execution_id)
	if status != Luau.LUA_OK:
		var message := limit_reason
		if message.is_empty():
			message = str(state.to_variant(-1)) if state.get_top() > 0 else "callback error"
		if state.get_top() > 0:
			state.pop(1)
		script_failed.emit(execution_id, "callback", message)
		_disable_page()
		return null
	var result = null
	if wants_result:
		result = state.to_variant(-1)
		state.pop(1)
	_snapshot_session(_realm)
	if int(state.get_total_bytes(0)) > SOFT_MEMORY_BYTES:
		script_failed.emit(execution_id, "memory", "soft memory budget exceeded")
		_disable_page()
		return null
	return result


func _on_interrupt(state, _gc_state: int) -> void:
	var script_id := _active_execution_id
	if script_id.is_empty():
		return
	var reason := ""
	if int(state.get_total_bytes(0)) > SOFT_MEMORY_BYTES:
		reason = "soft memory budget exceeded"
	elif _deadline_by_script.has(script_id) \
			and Time.get_ticks_msec() > int(_deadline_by_script[script_id]):
		reason = "execution deadline exceeded"
	if reason.is_empty():
		return
	_limit_reason_by_script[script_id] = reason
	state.push_string(reason)
	state.error()


func _snapshot_session(realm: Dictionary) -> void:
	var state = realm.get("state")
	var host: VrwebDocumentHost = realm.get("host")
	if state == null or host == null or not state.is_valid():
		return
	state.get_global("document")
	if state.is_table(-1):
		state.get_field(-1, "session")
		if state.is_table(-1):
			var value: Dictionary = state.to_dictionary(-1)
			if var_to_bytes(value).size() <= VrwebDocumentHost.MAX_VALUE_BYTES:
				host.session = value.duplicate(true)
		state.pop(1)
	state.pop(1)


func _dispose_realm(realm: Dictionary, preserve_replicated_state: bool) -> void:
	var host: VrwebDocumentHost = realm.get("host")
	if host != null:
		host.close(preserve_replicated_state)
	_close_lua_state(realm)


func _close_lua_state(realm: Dictionary) -> void:
	var root_state = realm.get("root_state")
	if root_state != null and root_state.is_valid():
		root_state.close()
		return
	var state = realm.get("state")
	if state != null and state.is_valid():
		state.close()


func _disable_page() -> void:
	if _realm.is_empty():
		return
	_dispose_realm(_realm, false)
	_realm = {}
	_declarations.clear()
	_active_hashes.clear()
	_page_id = ""


func _rebuild_active_hashes() -> void:
	_active_hashes.clear()
	for declaration in _declarations:
		_active_hashes[str(declaration.id)] = str(declaration.get("hash",
				str(declaration.source).sha256_text()))


static func _error(phase: String, message: String) -> Dictionary:
	return {"ok": false, "phase": phase, "error": message, "realm": {}}


func _clock_snapshot() -> Dictionary:
	return {
		"local_time": _scene_time,
		"authority_time": NetworkManager.authority_time_seconds(),
		"authority_ready": NetworkManager.authority_clock_synchronized(),
	}
