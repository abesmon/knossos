class_name ScriptingModulePeerGate
extends RefCounted

## Peer compatibility state contains declarations/hashes/capabilities only. It never transports
## component bytes and is reset on room teardown or reconnect.

const MAX_DESCRIPTOR_BYTES := 64 * 1024

var _identity: Array = []
var _runtime_available := true
var _required_capabilities: Array[String] = []
var _available_capabilities: Array[String] = []
var _peers: Dictionary = {}


func configure(identity: Array, runtime_available: bool, required_capabilities: Array[String],
		available_capabilities: Array[String]) -> void:
	_identity = identity.duplicate(true)
	_runtime_available = runtime_available
	_required_capabilities = required_capabilities.duplicate()
	_available_capabilities = available_capabilities.duplicate()
	_peers.clear()


func descriptor() -> Dictionary:
	return {"format": 1, "identity": _identity.duplicate(true),
		"runtime_available": _runtime_available,
		"capabilities": _available_capabilities.duplicate()}


func accept(peer_id: int, remote: Dictionary) -> Dictionary:
	if peer_id <= 0 or var_to_bytes(remote).size() > MAX_DESCRIPTOR_BYTES \
			or int(remote.get("format", 0)) != 1 \
			or typeof(remote.get("identity")) != TYPE_ARRAY \
			or typeof(remote.get("capabilities")) != TYPE_ARRAY:
		var invalid := {"outcome": "rejected", "code": "module_descriptor_invalid"}
		_peers[peer_id] = invalid
		return invalid
	var remote_identity: Array = remote.identity
	var runtime_available := _runtime_available and bool(remote.get("runtime_available", false))
	var result := ScriptingModuleIdentity.compare(_identity, remote_identity,
			runtime_available or _identity.is_empty())
	if str(result.outcome) == "compatible":
		var remote_capabilities: Array = remote.capabilities
		for capability in _required_capabilities:
			if capability not in remote_capabilities:
				result = {"outcome": "degraded", "code": "capability_unavailable"}
				break
	_peers[peer_id] = result.duplicate()
	return result


func remove(peer_id: int) -> void:
	_peers.erase(peer_id)


func clear_peers() -> void:
	_peers.clear()


func result_for(peer_id: int) -> Dictionary:
	if _identity.is_empty() and not _peers.has(peer_id):
		return {"outcome": "compatible", "code": ""}
	return (_peers.get(peer_id, {"outcome": "pending", "code": "descriptor_pending"}) \
			as Dictionary).duplicate()


func permits_replicated_state(peer_id: int) -> bool:
	return str(result_for(peer_id).outcome) == "compatible"


func aggregate() -> Dictionary:
	for result in _peers.values():
		if str(result.outcome) == "rejected": return (result as Dictionary).duplicate()
	for result in _peers.values():
		if str(result.outcome) in ["degraded", "pending"]:
			return (result as Dictionary).duplicate()
	return {"outcome": "compatible" if _runtime_available or _identity.is_empty() else "degraded",
		"code": "" if _runtime_available or _identity.is_empty() else "runtime_unavailable"}
