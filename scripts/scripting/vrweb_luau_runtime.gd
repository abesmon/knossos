class_name VrwebLuauRuntime
extends Node

## One isolated Luau VM per page script. Supports revision-staged replacement in place.

signal script_failed(script_id: String, phase: String, message: String)
signal script_replaced(script_id: String, old_hash: String, new_hash: String)

const TOP_LEVEL_BUDGET_MS := 75
const CALLBACK_BUDGET_MS := 25
const SOFT_MEMORY_BYTES := 16 * 1024 * 1024
const SAFE_LIBS := LuaState.LIB_BASE | LuaState.LIB_COROUTINE | LuaState.LIB_TABLE \
		| LuaState.LIB_STRING | LuaState.LIB_BIT32 | LuaState.LIB_BUFFER | LuaState.LIB_UTF8 \
		| LuaState.LIB_MATH | LuaState.LIB_VECTOR

var _realms: Dictionary = {}
var _page_root: Node
var _targets: Dictionary = {}
var _base_url := ""
var _player: Node
var _policy: VrwebContentPolicy
var _deadline_by_script: Dictionary = {}
var _limit_reason_by_script: Dictionary = {}
var _closed := false
var _scene_time := 0.0


func _process(delta: float) -> void:
	if _closed:
		return
	_scene_time += delta
	var clock := _clock_snapshot()
	for realm in _realms.values().duplicate():
		var host: VrwebDocumentHost = (realm as Dictionary).get("host")
		if host != null:
			host.update(delta, clock)


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
	var errors: Array[Dictionary] = []
	var activated: Array[String] = []
	for declaration in scripts:
		var script_id := str(declaration.get("id", ""))
		if _closed or _realms.has(script_id):
			errors.append({"script_id": script_id, "phase": "lookup",
				"message": "runtime is closed or script id is already active"})
			continue
		var prepared := _prepare(declaration, {})
		if not bool(prepared.ok):
			errors.append({"script_id": str(declaration.get("id", "")),
				"phase": str(prepared.phase), "message": str(prepared.error)})
			continue
		var realm: Dictionary = prepared.realm
		# Publish the candidate during commit so synchronous state reducers/callbacks are
		# dispatched into its VM. Nothing else can observe it before commit succeeds.
		_realms[str(declaration.id)] = realm
		if not (realm.host as VrwebDocumentHost).commit():
			_realms.erase(str(declaration.id))
			_dispose_realm(realm, false)
			errors.append({"script_id": str(declaration.id), "phase": "commit",
				"message": "document staging commit failed"})
			continue
		activated.append(str(declaration.id))
	return {"ok": errors.is_empty(), "activated": activated, "errors": errors}


func replace(script_id: String, source: String, base_hash := "") -> Dictionary:
	if _closed or not _realms.has(script_id):
		return _error("lookup", "script is not active")
	var old: Dictionary = _realms[script_id]
	if not base_hash.is_empty() and str(old.hash) != base_hash:
		return _error("revision", "base hash does not match active revision")
	_snapshot_session(old)
	var declaration: Dictionary = old.declaration.duplicate(true)
	declaration["source"] = source
	declaration["kind"] = "inline"
	declaration["src"] = ""
	declaration["integrity"] = ""
	declaration["hash"] = source.sha256_text()
	var prepared := _prepare(declaration, (old.host as VrwebDocumentHost).session)
	if not bool(prepared.ok):
		return prepared
	var candidate: Dictionary = prepared.realm
	# Keep the old revision intact until the candidate has crossed the commit boundary.
	# The temporary mapping also makes synchronous candidate callbacks use the new VM.
	(old.host as VrwebDocumentHost).snapshot_replicated_state()
	_realms[script_id] = candidate
	if not (candidate.host as VrwebDocumentHost).commit():
		_realms[script_id] = old
		_dispose_realm(candidate, false)
		(old.host as VrwebDocumentHost).restore_replicated_state()
		return _error("commit", "candidate could not commit")
	(old.host as VrwebDocumentHost).retire_for_replacement(candidate.host)
	old.state.close()
	script_replaced.emit(script_id, str(old.hash), str(candidate.hash))
	return {"ok": true, "script_id": script_id, "old_hash": str(old.hash),
		"new_hash": str(candidate.hash), "phase": "", "error": ""}


func remove(script_id: String) -> bool:
	if not _realms.has(script_id):
		return false
	var realm: Dictionary = _realms[script_id]
	_snapshot_session(realm)
	_dispose_realm(realm, false)
	_realms.erase(script_id)
	return true


func active_hashes() -> Dictionary:
	var hashes := {}
	for script_id in _realms:
		hashes[script_id] = str((_realms[script_id] as Dictionary).hash)
	return hashes


func session_of(script_id: String) -> Dictionary:
	if not _realms.has(script_id):
		return {}
	var realm: Dictionary = _realms[script_id]
	_snapshot_session(realm)
	return (realm.host as VrwebDocumentHost).session.duplicate(true)


func close() -> void:
	if _closed:
		return
	_closed = true
	for realm in _realms.values():
		_snapshot_session(realm)
		_dispose_realm(realm, false)
	_realms.clear()
	_deadline_by_script.clear()
	_limit_reason_by_script.clear()
	_targets.clear()
	_page_root = null
	_player = null


func _prepare(declaration: Dictionary, previous_session: Dictionary) -> Dictionary:
	var script_id := str(declaration.get("id", ""))
	var source := str(declaration.get("source", ""))
	if str(declaration.get("profile", "")) != VrwebScriptDeclaration.PROFILE:
		return _error("profile", "unsupported runtime profile")
	if not VrwebScriptDeclaration.valid_id(script_id) or source.is_empty() \
			or source.to_utf8_buffer().size() > VrwebScriptDeclaration.MAX_SOURCE_BYTES:
		return _error("load", "invalid id or source")
	var state = LuaState.new()
	state.open_libs(SAFE_LIBS)
	var host := VrwebDocumentHost.new()
	var invoke := func(callback: Callable, event = {}, wants_result := false):
		return _invoke_script(script_id, callback, event, wants_result)
	host.setup(script_id, str(declaration.get("hash", source.sha256_text())), _page_root,
			_targets, _base_url, _player, self, invoke, previous_session, _policy,
			_clock_snapshot)
	state.register_library("document", host.api())
	state.pop(1)
	var bytecode: PackedByteArray = Luau.compile(source)
	if bytecode.is_empty() or not state.load_bytecode(bytecode,
			"@vrweb-source:///%s.luau" % script_id):
		var load_error := str(state.to_variant(-1)) if state.get_top() > 0 else "source rejected"
		host.close(true)
		state.close()
		return _error("load", load_error)
	state.sandbox()
	state.interrupt.connect(_on_interrupt.bind(script_id))
	state.set_interrupts(true)
	_deadline_by_script[script_id] = Time.get_ticks_msec() + TOP_LEVEL_BUDGET_MS
	_limit_reason_by_script.erase(script_id)
	var status: int = state.pcall(0, 0)
	_deadline_by_script.erase(script_id)
	if status != Luau.LUA_OK:
		var message := str(_limit_reason_by_script.get(script_id,
			str(state.to_variant(-1)) if state.get_top() > 0 else "runtime error"))
		_limit_reason_by_script.erase(script_id)
		host.close(true)
		state.close()
		script_failed.emit(script_id, "execute", message)
		return _error("execute", message)
	var realm := {"id": script_id, "hash": str(declaration.get("hash", source.sha256_text())),
		"declaration": declaration.duplicate(true), "state": state, "host": host}
	_snapshot_session(realm)
	return {"ok": true, "realm": realm, "phase": "", "error": ""}


func _invoke_script(script_id: String, callback: Callable, event, wants_result := false):
	if _closed or not callback.is_valid() or not _realms.has(script_id):
		# During top-level staging the realm is not committed yet; callbacks cannot fire there.
		return null
	var realm: Dictionary = _realms[script_id]
	var state = realm.state
	if state == null or not state.is_valid():
		return null
	(realm.host as VrwebDocumentHost).begin_invocation()
	_deadline_by_script[script_id] = Time.get_ticks_msec() + CALLBACK_BUDGET_MS
	_limit_reason_by_script.erase(script_id)
	# Push the original Luau function back into its VM. Calling LuaCallable.call() directly
	# makes the extension print errors outside our protected pcall and cannot safely recover from
	# an interrupt. This path gives every callback the same controlled boundary as top-level code.
	state.push_callable(callback)
	state.push_variant(event)
	var status: int = state.pcall(1, 1 if wants_result else 0)
	_deadline_by_script.erase(script_id)
	var limit_reason := str(_limit_reason_by_script.get(script_id, ""))
	_limit_reason_by_script.erase(script_id)
	if status != Luau.LUA_OK:
		var message := limit_reason
		if message.is_empty():
			message = str(state.to_variant(-1)) if state.get_top() > 0 else "callback error"
		if state.get_top() > 0:
			state.pop(1)
		script_failed.emit(script_id, "callback", message)
		remove(script_id)
		return null
	var result = null
	if wants_result:
		result = state.to_variant(-1)
		state.pop(1)
	_snapshot_session(realm)
	if int(state.get_total_bytes(0)) > SOFT_MEMORY_BYTES:
		script_failed.emit(script_id, "memory", "soft memory budget exceeded")
		remove(script_id)
		return null
	return result


func _on_interrupt(state, _gc_state: int, script_id: String) -> void:
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
	var state = realm.get("state")
	if state != null and state.is_valid():
		state.close()


static func _error(phase: String, message: String) -> Dictionary:
	return {"ok": false, "phase": phase, "error": message, "realm": {}}


func _clock_snapshot() -> Dictionary:
	return {
		"local_time": _scene_time,
		"authority_time": NetworkManager.authority_time_seconds(),
		"authority_ready": NetworkManager.authority_clock_synchronized(),
	}
