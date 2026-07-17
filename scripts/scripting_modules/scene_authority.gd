class_name SceneAuthority
extends RefCounted

const READABLE_PROPERTIES := {
	"position": true, "rotation": true, "scale": true, "transform": true,
	"visible": true, "color": true, "energy": true, "text": true,
}
const WRITABLE_PROPERTIES := {
	"position": true, "rotation": true, "scale": true, "transform": true,
	"visible": true, "color": true, "energy": true, "text": true,
}
const NODE_ALLOWLIST := {
	"Node3D": true, "MeshInstance3D": true, "StaticBody3D": true,
	"CollisionShape3D": true, "OmniLight3D": true, "Label3D": true,
}
const RESOURCE_ALLOWLIST := {
	"BoxMesh": true, "BoxShape3D": true, "StandardMaterial3D": true,
}
const RESOURCE_PROPERTIES := {"mesh": true, "shape": true, "material_override": true}
const MAX_GUEST_NODES := 256
const MAX_GUEST_RESOURCES := 256
const MAX_DEPTH := 32
const MAX_SIGNAL_EVENTS := 256
const SCENE_CATALOG_PATH := "res://spec/scene-api-catalog.json"

static var _scene_catalog: Dictionary = {}

var _owner: String
var _page: String
var _root: Node
var _handles: WasmHandleTable
var _content_policy: VrwebContentPolicy
var _root_handle := 0
var _guest_nodes: Dictionary = {}
var _guest_resources: Dictionary = {}
var _subscriptions: Dictionary = {}
var _subscription_seq := 1
var _event_queue: Array[Dictionary] = []
var _dropped_events := 0
var _updates_enabled := false
var _transactions: Dictionary = {}


func _init(owner: String, page: String, root: Node, handles: WasmHandleTable = null,
		content_policy: VrwebContentPolicy = null) -> void:
	_owner = owner
	_page = page
	_root = root
	_handles = handles if handles != null else WasmHandleTable.new()
	_content_policy = content_policy if content_policy != null else VrwebContentPolicy.new()
	_root_handle = _handles.create(root, owner, page, "node")


func root_handle() -> int:
	return _root_handle


## Synchronous byte-only entry point used by the native Component Model linker.
## Success is a PackedByteArray (or int for subscribe), failure is a stable String code.
func wasm_host_call(operation: String, id: int, payload: PackedByteArray,
		nested: Array) -> Variant:
	match operation:
		"query": return _wasm_query(id, payload)
		"mutate": return _wasm_mutate(id, payload)
		"commit": return _wasm_commit(id)
		"call": return _wasm_call(id, payload, nested)
		"subscribe":
			var signal_name: Variant = _decode_utf8(payload)
			if signal_name is String and str(signal_name).begins_with("wire_"):
				return str(signal_name)
			var subscribed := subscribe_signal(id, str(signal_name))
			return int(subscribed.value) if bool(subscribed.ok) else str(subscribed.error)
		"unsubscribe":
			unsubscribe_signal(id)
			return null
	return "unknown_host_operation"


func _wasm_query(target: int, payload: PackedByteArray) -> Variant:
	var request: Variant = _decode_wire(payload)
	if request is String: return request
	var op := str(request.get("op", ""))
	var result: Dictionary
	match op:
		"root": result = _ok(_root_handle)
		"class": result = class_name_of(target)
		"name": result = name_of(target)
		"parent": result = parent_of(target)
		"children": result = children_of(target)
		"property": result = get_property(target, str(request.get("property", "")))
		"create_resource": result = create_resource(str(request.get("class", "")))
		"path": result = _error("path_forbidden")
		_: result = _error("unknown_query")
	return _wire_result(result)


func _wasm_mutate(transaction: int, payload: PackedByteArray) -> Variant:
	if transaction <= 0: return "invalid_transaction"
	var request: Variant = _decode_wire(payload)
	if request is String: return request
	var mutation: SceneMutation = _transactions.get(transaction)
	if mutation == null:
		mutation = begin_mutation()
		_transactions[transaction] = mutation
	var result: Dictionary
	match str(request.get("op", "")):
		"set": result = mutation.set_property(int(request.get("handle", 0)),
				str(request.get("property", "")), request.get("value", {}))
		"create": result = mutation.create_node(str(request.get("class", "")),
				int(request.get("parent", 0)), request.get("initial", {}),
				str(request.get("token", "")))
		"set_resource": result = mutation.set_resource(int(request.get("handle", 0)),
				str(request.get("property", "")), int(request.get("resource", 0)))
		"reparent": result = mutation.reparent(int(request.get("handle", 0)),
				int(request.get("parent", 0)))
		"destroy": result = mutation.destroy(int(request.get("handle", 0)))
		_: result = _error("unknown_operation")
	if not bool(result.ok):
		mutation.cancel()
		_transactions.erase(transaction)
		return str(result.error)
	return PackedByteArray()


func _wasm_commit(transaction: int) -> Variant:
	var mutation: SceneMutation = _transactions.get(transaction)
	if mutation == null: return "transaction_not_found"
	_transactions.erase(transaction)
	return _wire_result(mutation.commit())


func _wasm_call(target: int, method_bytes: PackedByteArray, nested: Array) -> Variant:
	var method: Variant = _decode_utf8(method_bytes)
	if method is String and str(method).begins_with("wire_"): return method
	var args: Array = []
	for raw in nested:
		if not (raw is PackedByteArray): return "wire_argument_type"
		var decoded: Variant = _decode_wire(raw)
		if decoded is String: return decoded
		args.append(decoded)
	return _wire_result(call_method(target, str(method), args))


func _wire_result(result: Dictionary) -> Variant:
	if not bool(result.ok): return str(result.error)
	return JSON.stringify(result.value).to_utf8_buffer()


func _decode_wire(bytes: PackedByteArray) -> Variant:
	if bytes.size() > WasmValueCodec.MAX_BYTE_BUFFER: return "wire_too_large"
	var text: Variant = _decode_utf8(bytes)
	if text is String and str(text).begins_with("wire_"): return text
	var json := JSON.new()
	if json.parse(str(text)) != OK or not (json.data is Dictionary):
		return "wire_malformed_json"
	return json.data


func _decode_utf8(bytes: PackedByteArray) -> Variant:
	if bytes.size() > WasmValueCodec.MAX_BYTE_BUFFER: return "wire_too_large"
	if not WasmValueCodec.is_valid_utf8(bytes): return "wire_invalid_utf8"
	var text := bytes.get_string_from_utf8()
	return text


func class_name_of(handle: int) -> Dictionary:
	var node := _node(handle)
	return _ok(node.value.get_class()) if bool(node.ok) else node


func name_of(handle: int) -> Dictionary:
	var node := _node(handle)
	return _ok(str(node.value.name)) if bool(node.ok) else node


func parent_of(handle: int) -> Dictionary:
	var node := _node(handle)
	if not bool(node.ok): return node
	if node.value == _root:
		return _ok(0)
	var parent: Node = node.value.get_parent()
	if not _in_scope(parent):
		return _error("outside_scope")
	return _ok(_handles.create(parent, _owner, _page, "node"))


func children_of(handle: int) -> Dictionary:
	var node := _node(handle)
	if not bool(node.ok): return node
	var handles: Array[int] = []
	for child in node.value.get_children():
		if _in_scope(child):
			handles.append(_handles.create(child, _owner, _page, "node"))
	return _ok(handles)


func get_property(handle: int, property: String) -> Dictionary:
	if not READABLE_PROPERTIES.has(property):
		return _error("property_not_readable")
	var node := _node(handle)
	if not bool(node.ok): return node
	var exists := false
	for info in node.value.get_property_list():
		if str(info.name) == property:
			exists = true
			break
	if not exists:
		return _error("property_not_found")
	var encoded := WasmValueCodec.encode(node.value.get(property))
	return encoded if not bool(encoded.ok) else _ok(encoded.value)


func begin_mutation() -> SceneMutation:
	return SceneMutation.new(self)


func create_resource(class_name_: String) -> Dictionary:
	if not RESOURCE_ALLOWLIST.has(class_name_):
		return _error("resource_class_forbidden")
	if _guest_resources.size() >= MAX_GUEST_RESOURCES:
		return _error("resource_quota")
	var resource = ClassDB.instantiate(class_name_)
	if not (resource is Resource):
		return _error("resource_instantiation_failed")
	_guest_resources[resource.get_instance_id()] = resource
	return _ok(_handles.create(resource, _owner, _page, "resource"))


func call_method(handle: int, method: String, encoded_args: Array) -> Dictionary:
	var node := _node(handle)
	if not bool(node.ok): return node
	var spec := _method_spec(node.value, method)
	if spec.is_empty():
		return _error("method_not_allowed")
	if encoded_args.size() < int(spec.min) or encoded_args.size() > int(spec.max):
		return _error("method_arity")
	var args: Array = []
	for encoded in encoded_args:
		var decoded := WasmValueCodec.decode(encoded)
		if not bool(decoded.ok): return decoded
		args.append(decoded.value)
	var result: Variant = node.value.callv(method, args)
	if result == null:
		return _ok({"t": "null"})
	var encoded_result := WasmValueCodec.encode(result)
	return encoded_result if not bool(encoded_result.ok) else _ok(encoded_result.value)


func subscribe_signal(handle: int, signal_name: String) -> Dictionary:
	var node := _node(handle)
	if not bool(node.ok): return node
	if not _signal_allowed(node.value, signal_name) or not node.value.has_signal(signal_name):
		return _error("signal_not_allowed")
	var subscription := _subscription_seq
	_subscription_seq += 1
	var callback := Callable(self, "_on_signal").bind(subscription, signal_name)
	if node.value.connect(signal_name, callback) != OK:
		return _error("signal_connect_failed")
	_subscriptions[subscription] = {"node": weakref(node.value), "signal": signal_name,
		"callback": callback}
	return _ok(subscription)


func unsubscribe_signal(subscription: int) -> bool:
	if not _subscriptions.has(subscription):
		return false
	var entry: Dictionary = _subscriptions[subscription]
	var node: Node = entry.node.get_ref()
	if node != null and node.is_connected(entry.signal, entry.callback):
		node.disconnect(entry.signal, entry.callback)
	_subscriptions.erase(subscription)
	return true


func enable_updates(enabled: bool) -> void:
	_updates_enabled = enabled


func enqueue_frame(delta: float) -> bool:
	if not _updates_enabled or not is_finite(delta) or delta < 0.0:
		return false
	_enqueue_event({"kind": "frame", "delta": minf(delta, 0.25)})
	return true


func drain_events(limit: int = MAX_SIGNAL_EVENTS) -> Array[Dictionary]:
	var count := mini(maxi(limit, 0), _event_queue.size())
	var out: Array[Dictionary] = []
	for _index in count:
		out.append(_event_queue.pop_front())
	return out


func dropped_event_count() -> int:
	return _dropped_events


func validate_property_write(handle: int, property: String,
		encoded_value: Dictionary) -> Dictionary:
	if not WRITABLE_PROPERTIES.has(property):
		return _error("property_not_writable")
	var node := _node(handle)
	if not bool(node.ok): return node
	var decoded := WasmValueCodec.decode(encoded_value)
	if not bool(decoded.ok): return decoded
	return validate_property_on_node(node.value, property, decoded.value)


func validate_property_on_node(node: Node, property: String, value: Variant) -> Dictionary:
	if not WRITABLE_PROPERTIES.has(property):
		return _error("property_not_writable")
	var policy_decision := _content_policy.evaluate_property(node.get_class(), property, str(value),
			{"source": "wasm", "module": _owner, "page": _page})
	if not VrwebContentPolicy.allowed(policy_decision):
		return _error("content_policy_denied")
	var property_info := _property_info(node, property)
	if property_info.is_empty() or int(property_info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY:
		return _error("property_not_writable")
	if typeof(value) != int(property_info.get("type", TYPE_NIL)):
		return _error("property_type_mismatch")
	return _ok({"node": node, "property": property, "value": value})


func validate_resource_write(node_handle: int, property: String,
		resource_handle: int) -> Dictionary:
	if not RESOURCE_PROPERTIES.has(property):
		return _error("resource_property_forbidden")
	var node := _node(node_handle)
	if not bool(node.ok): return node
	var resource := _handles.resolve(resource_handle, _owner, _page, "resource")
	if not bool(resource.ok): return resource
	if not _guest_resources.has(resource.value.get_instance_id()):
		return _error("resource_not_owned")
	var property_info := _property_info(node.value, property)
	if property_info.is_empty() or int(property_info.get("type", TYPE_NIL)) != TYPE_OBJECT:
		return _error("resource_property_type")
	var expected := str(property_info.get("class_name", ""))
	if not expected.is_empty() and not resource.value.is_class(expected):
		return _error("resource_property_type")
	return _ok({"node": node.value, "property": property, "value": resource.value})


func validate_create_node(class_name_: String, parent_handle: int,
		initial: Dictionary) -> Dictionary:
	if not NODE_ALLOWLIST.has(class_name_):
		return _error("node_class_forbidden")
	if _guest_nodes.size() >= MAX_GUEST_NODES:
		return _error("node_quota")
	var parent := _node(parent_handle)
	if not bool(parent.ok): return parent
	if _depth_from_root(parent.value) + 1 > MAX_DEPTH:
		return _error("depth_quota")
	var node = ClassDB.instantiate(class_name_)
	if not (node is Node):
		return _error("node_instantiation_failed")
	var prepared: Array[Dictionary] = []
	for property in initial:
		var decoded := WasmValueCodec.decode(initial[property])
		if not bool(decoded.ok):
			node.free()
			return decoded
		var checked := validate_property_on_node(node, str(property), decoded.value)
		if not bool(checked.ok):
			node.free()
			return checked
		prepared.append(checked.value)
	return _ok({"node": node, "parent": parent.value, "properties": prepared})


func adopt_created_node(node: Node) -> int:
	_guest_nodes[node.get_instance_id()] = true
	return _handles.create(node, _owner, _page, "node")


func can_allocate_guest_nodes(count: int) -> bool:
	return count >= 0 and _guest_nodes.size() + count <= MAX_GUEST_NODES


func validate_reparent(node_handle: int, parent_handle: int) -> Dictionary:
	var node := _node(node_handle)
	if not bool(node.ok): return node
	var parent := _node(parent_handle)
	if not bool(parent.ok): return parent
	if not _guest_nodes.has(node.value.get_instance_id()):
		return _error("node_not_owned")
	if node.value == parent.value or node.value.is_ancestor_of(parent.value):
		return _error("reparent_cycle")
	if _depth_from_root(parent.value) + 1 > MAX_DEPTH:
		return _error("depth_quota")
	return _ok({"node": node.value, "parent": parent.value})


func validate_destroy(node_handle: int) -> Dictionary:
	var node := _node(node_handle)
	if not bool(node.ok): return node
	if node.value == _root or not _guest_nodes.has(node.value.get_instance_id()):
		return _error("node_not_owned")
	return _ok(node.value)


func forget_destroyed(node: Node) -> void:
	_guest_nodes.erase(node.get_instance_id())


func close() -> void:
	for transaction in _transactions.values():
		transaction.cancel()
	_transactions.clear()
	for subscription in _subscriptions.keys().duplicate():
		unsubscribe_signal(int(subscription))
	_event_queue.clear()
	_updates_enabled = false
	if is_instance_valid(_root):
		_free_guest_descendants(_root)
	_guest_nodes.clear()
	_guest_resources.clear()
	_handles.invalidate_scope(_owner, _page)
	_root = null
	_root_handle = 0


func _node(handle: int) -> Dictionary:
	var resolved := _handles.resolve(handle, _owner, _page, "node")
	if not bool(resolved.ok): return resolved
	if not _in_scope(resolved.value):
		return _error("outside_scope")
	return resolved


func _in_scope(node: Node) -> bool:
	return is_instance_valid(_root) and is_instance_valid(node) \
		and (node == _root or _root.is_ancestor_of(node))


func _property_info(object: Object, property: String) -> Dictionary:
	for info in object.get_property_list():
		if str(info.name) == property:
			return info
	return {}


func _depth_from_root(node: Node) -> int:
	var depth := 0
	var current := node
	while current != null and current != _root:
		depth += 1
		current = current.get_parent()
	return depth


func _method_spec(node: Node, method: String) -> Dictionary:
	var methods: Dictionary = _catalog().get("methods", {})
	for class_name_ in methods:
		var class_methods: Dictionary = methods[class_name_]
		if node.is_class(class_name_) and class_methods.has(method):
			var raw: Dictionary = class_methods[method]
			if str(raw.get("classification", "")) != "safe":
				return {}
			return {"min": int(raw.get("args_min", raw.get("args", 0))),
				"max": int(raw.get("args_max", raw.get("args", 0)))}
	return {}


func _signal_allowed(node: Node, signal_name: String) -> bool:
	var signals: Dictionary = _catalog().get("signals", {})
	for class_name_ in signals:
		if node.is_class(class_name_) and signal_name in Array(signals[class_name_]):
			return true
	return false


func _on_signal(subscription: int, signal_name: String, arg0: Variant = null,
		arg1: Variant = null, arg2: Variant = null, arg3: Variant = null) -> void:
	# A signal may already be queued by Godot when unsubscribe/close runs. Never turn that stale
	# callable into a guest callback after its lifecycle authority has been revoked.
	if not _subscriptions.has(subscription):
		return
	var encoded_args: Array = []
	for arg in [arg0, arg1, arg2, arg3]:
		if arg == null: continue
		var encoded := WasmValueCodec.encode(arg)
		if not bool(encoded.ok):
			return
		encoded_args.append(encoded.value)
	_enqueue_event({"kind": "signal", "subscription": subscription,
		"signal": signal_name, "args": encoded_args})


func _enqueue_event(event: Dictionary) -> void:
	if _event_queue.size() >= MAX_SIGNAL_EVENTS:
		_dropped_events += 1
		return
	_event_queue.append(event)


func _free_guest_descendants(parent: Node) -> void:
	for child in parent.get_children().duplicate():
		if _guest_nodes.has(child.get_instance_id()):
			child.free()
		else:
			_free_guest_descendants(child)


static func _catalog() -> Dictionary:
	if not _scene_catalog.is_empty():
		return _scene_catalog
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SCENE_CATALOG_PATH))
	if parsed is Dictionary and int(parsed.get("version", 0)) == 1:
		_scene_catalog = parsed
	return _scene_catalog


func _ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}


func _error(code: String) -> Dictionary:
	return {"ok": false, "value": null, "error": code}
