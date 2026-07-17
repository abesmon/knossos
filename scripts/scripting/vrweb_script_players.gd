class_name VrwebScriptPlayers
extends RefCounted

## Read-only reactive view of the local participant and current instance roster for one realm.

const MAX_SUBSCRIPTIONS := 8

var _invoke: Callable
var _subscriptions: Array[Callable] = []
var _signal_connections: Array[Dictionary] = []
var _closed := false
var _staging := true
var _emitting := false
var _dirty := false


func setup(invoke: Callable) -> void:
	_invoke = invoke


func api() -> Dictionary:
	return {
		"local_info": local_info,
		"all": all,
		"on_changed": subscribe,
	}


func local_info() -> Dictionary:
	return {} if _closed else local_snapshot()


func all() -> Array:
	return [] if _closed else roster_snapshot()


func subscribe(callback: Callable) -> bool:
	if _closed or not callback.is_valid() or _subscriptions.size() >= MAX_SUBSCRIPTIONS:
		return false
	_subscriptions.append(callback)
	if not _staging:
		_invoke_callback(callback)
	return true


func commit() -> bool:
	if _closed:
		return false
	_staging = false
	_connect_reactive_signals()
	_emit_changed()
	return true


func close() -> void:
	if _closed:
		return
	_closed = true
	for record in _signal_connections:
		var source: Signal = record.signal
		var callback: Callable = record.callback
		if source.is_connected(callback):
			source.disconnect(callback)
	_signal_connections.clear()
	_subscriptions.clear()
	_invoke = Callable()


static func local_snapshot() -> Dictionary:
	var rank_table := NetworkManager.ranks_snapshot()
	var verified := HomeServer.is_logged_in() and HomeServer.has_certificate()
	return {
		"peer_id": NetworkManager.my_peer_id(),
		"user_id": Settings.user_id,
		"nick": Settings.nick,
		"rank": NetworkManager.my_rank(),
		"rank_assigned": NetworkManager.has_authority() or rank_table.has(Settings.user_id),
		"is_local": true,
		"is_authority": NetworkManager.has_authority(),
		"can_manage_ranks": NetworkManager.has_authority(),
		"verified": verified,
		"verified_address": HomeServer.address if verified else "",
		"online_enabled": Settings.online_enabled,
		"online": NetworkManager.is_online(),
		"in_room": NetworkManager.in_room(),
		"p2p_connected": NetworkManager.in_room(),
		"p2p_lost": false,
		"authority_peer_id": NetworkManager.authority_id(),
		"authority_user_id": NetworkManager.authority_user_id(),
	}


static func peer_snapshot(peer_id: int) -> Dictionary:
	if peer_id == NetworkManager.my_peer_id():
		return local_snapshot()
	var user_id := NetworkManager.user_id_of(peer_id)
	var rank_table := NetworkManager.ranks_snapshot()
	var verified_address := NetworkManager.verified_address_of(peer_id)
	return {
		"peer_id": peer_id,
		"user_id": user_id,
		"nick": NetworkManager.nick_of(peer_id),
		"rank": NetworkManager.rank_of_peer(peer_id),
		"rank_assigned": peer_id == NetworkManager.authority_id() \
				or (not user_id.is_empty() and rank_table.has(user_id)),
		"is_local": false,
		"is_authority": peer_id == NetworkManager.authority_id(),
		"can_manage_ranks": peer_id == NetworkManager.authority_id(),
		"verified": not verified_address.is_empty(),
		"verified_address": verified_address,
		"online_enabled": true,
		"online": true,
		"in_room": true,
		"p2p_connected": NetworkManager.peer_p2p_connected(peer_id),
		"p2p_lost": NetworkManager.peer_p2p_lost(peer_id),
		"authority_peer_id": NetworkManager.authority_id(),
		"authority_user_id": NetworkManager.authority_user_id(),
	}


static func roster_snapshot() -> Array:
	var result: Array = [local_snapshot()]
	var ids := NetworkManager.peer_ids()
	ids.sort()
	for peer_id in ids:
		result.append(peer_snapshot(int(peer_id)))
	return result


func _connect_reactive_signals() -> void:
	_connect_signal(NetworkManager.peer_joined, func(_id, _nick): _mark_changed())
	_connect_signal(NetworkManager.peer_left, func(_id): _mark_changed())
	_connect_signal(NetworkManager.p2p_peer_connected, func(_id): _mark_changed())
	_connect_signal(NetworkManager.p2p_peer_disconnected, func(_id): _mark_changed())
	_connect_signal(NetworkManager.identity_received,
			func(_id, _nick, _face, _avatar): _mark_changed())
	_connect_signal(NetworkManager.identity_verified, func(_id, _address): _mark_changed())
	_connect_signal(NetworkManager.ranks_changed, func(): _mark_changed())
	_connect_signal(NetworkManager.authority_changed, func(_id, _is_me): _mark_changed())
	_connect_signal(NetworkManager.connection_changed, func(_online): _mark_changed())
	_connect_signal(NetworkManager.net_status_changed, func(_status): _mark_changed())
	_connect_signal(Settings.changed, func(): _mark_changed())
	_connect_signal(HomeServer.state_changed, func(): _mark_changed())
	_connect_signal(HomeServer.certificate_changed, func(): _mark_changed())


func _connect_signal(source: Signal, callback: Callable) -> void:
	source.connect(callback)
	_signal_connections.append({"signal": source, "callback": callback})


func _mark_changed() -> void:
	if _closed or _staging:
		return
	if _emitting:
		_dirty = true
		return
	_emit_changed()


func _emit_changed() -> void:
	if _closed or _staging:
		return
	_emitting = true
	for callback in _subscriptions.duplicate():
		_invoke_callback(callback)
	_emitting = false
	if _dirty:
		_dirty = false
		_emit_changed()


func _invoke_callback(callback: Callable) -> void:
	if callback.is_valid() and _invoke.is_valid():
		_invoke.call(callback, {"local": local_snapshot(), "players": roster_snapshot()})

