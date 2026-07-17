class_name NativeWasmBackend
extends ScriptingModuleBackend

const WasmComponentNodeClass = preload("res://scripts/scripting_modules/wasm_component_node.gd")
var _runtime: Object
var _prepared: Dictionary = {}
const HOST_CAPABILITIES: Array[String] = [
	"vrweb:core/1", "vrweb:scene/1", "vrweb:state/1", "vrweb:assets/1",
	"vrweb:timers/1", "vrweb:input/1", "vrweb:features/1", "vrweb:log/1",
]
var _instances: Dictionary = {}
var _instance_seq := 0
var _handles := WasmHandleTable.new()
var _authorities: Dictionary = {}
var _host_contexts: Dictionary = {}
var _instance_specs: Dictionary = {}
var _module_states: Dictionary = {}
var _event_delivery_active := false
var _queued_deliveries: Array[Dictionary] = []


static func is_available() -> bool:
	return ClassDB.class_exists("VrwebWasmRuntime")


func _init() -> void:
	if is_available():
		_runtime = ClassDB.instantiate("VrwebWasmRuntime")


func prepare(modules: Array) -> Dictionary:
	_prepared.clear()
	var errors: Array[String] = []
	var diagnostics: Array[Dictionary] = []
	if _runtime == null or not bool(_runtime.call("is_available")):
		return {"ok": false, "errors": ["WASM runtime unavailable"], "diagnostics": [{
			"code": "runtime_unavailable", "phase": "prepare", "message": "WASM runtime unavailable",
			"module": "", "origin": "", "hash": "", "instance": ""}]}
	for item in modules:
		var module: Dictionary = item
		var module_id := str(module.get("id", ""))
		var component_path := str(module.get("component_path", ""))
		if component_path.is_empty():
			var message := "module «%s»: component path отсутствует" % module_id
			errors.append(message)
			diagnostics.append(_diagnostic(module, "component_path_missing", "prepare", message))
			continue
		var absolute_path := ProjectSettings.globalize_path(component_path)
		if not bool(_runtime.call("prepare_component", module_id, absolute_path)):
			var message := "module «%s»: %s" % [module_id,
				str(_runtime.call("get_last_error"))]
			errors.append(message)
			diagnostics.append(_diagnostic(module, "component_invalid", "prepare", message))
			continue
		var signature_errors := validate_signature(
				Array(_runtime.call("component_imports", module_id)),
				Array(_runtime.call("component_exports", module_id)), module,
				HOST_CAPABILITIES)
		if not signature_errors.is_empty():
			_runtime.call("drop_component", module_id)
			for error in signature_errors:
				var message := "module «%s»: %s" % [module_id, error]
				errors.append(message)
				diagnostics.append(_diagnostic(module, "import_policy_denied", "prepare", message))
			continue
		_prepared[module_id] = module
	return {"ok": errors.is_empty(), "errors": errors, "diagnostics": diagnostics}


static func validate_signature(imports: Array, exports: Array, module: Dictionary,
		provided_capabilities: Array[String]) -> Array[String]:
	var errors: Array[String] = []
	var manifest: Dictionary = module.get("manifest", {})
	var required: Array = manifest.get("requires", module.get("requires", []))
	var optional: Array = manifest.get("optional", module.get("optional", []))
	for raw_import in imports:
		var import_name := str(raw_import)
		if import_name.begins_with("wasi:"):
			errors.append("WASI import запрещён: %s" % import_name)
			continue
		var capability := _capability_for_import(import_name)
		if capability.is_empty():
			errors.append("неизвестный import: %s" % import_name)
		elif capability not in required and capability not in optional:
			errors.append("import не объявлен в manifest: %s" % import_name)
		elif capability not in provided_capabilities:
			errors.append("host capability недоступна: %s" % capability)
	var declared_exports: Dictionary = manifest.get("exports", module.get("exports", {}))
	if not declared_exports.is_empty():
		for lifecycle_export in ["create", "mount", "event", "unmount"]:
			if lifecycle_export not in exports:
				errors.append("world export отсутствует в component: %s" % lifecycle_export)
	return errors


static func _capability_for_import(import_name: String) -> String:
	if not import_name.begins_with("vrweb:") or not import_name.contains("/") \
			or not import_name.contains("@"):
		return ""
	var package_name := import_name.get_slice("/", 0)
	var version := import_name.rsplit("@", true, 1)[-1]
	var major := version.get_slice(".", 0)
	if not major.is_valid_int() or int(major) != 1:
		return ""
	return package_name + "/" + major


func instantiate_export(module_id: String, export_name: String) -> Dictionary:
	module_id = module_id.trim_prefix("#")
	if not _prepared.has(module_id):
		var message := "module «%s» не подготовлен" % module_id
		return {"node": null, "context": null, "error": message,
			"diagnostic": _diagnostic({"id": module_id}, "module_not_prepared", "instantiate", message)}
	var module: Dictionary = _prepared[module_id]
	var exports: Dictionary = module.get("exports", {})
	if not exports.has(export_name):
		var message := "module «%s» не экспортирует «%s»" % [module_id, export_name]
		return {"node": null, "context": null, "error": message,
			"diagnostic": _diagnostic(module, "export_not_found", "instantiate", message)}
	var instance_id := "%s::%d" % [module_id, _instance_seq]
	_instance_seq += 1
	var node: Node3D = WasmComponentNodeClass.new()
	node.name = export_name
	node.set_meta("vrweb_wasm_module", module_id)
	node.set_meta("vrweb_wasm_instance", instance_id)
	node.configure_unmount(Callable(self, "_unmount_instance").bind(module_id, instance_id))
	var page_id := str(module.get("hash", module.get("base_url", "page")))
	var authority := SceneAuthority.new(module_id, page_id, node, _handles)
	if not _module_states.has(module_id):
		_module_states[module_id] = {}
	var services := WasmModuleServices.new(module_id, module, HOST_CAPABILITIES,
			_module_states[module_id])
	var host_context := WasmHostContext.new(authority, services)
	var limits: Dictionary = (module.get("manifest", {}) as Dictionary).get("limits",
			ScriptingModuleManifest.DEFAULT_LIMITS)
	if not bool(_runtime.call("instantiate_lifecycle_with_host_limits", module_id, instance_id,
			Callable(host_context, "host_call"), int(limits.fuel), int(limits.memory_bytes),
			int(limits.deadline_ms), int(limits.host_calls), int(limits.instances),
			int(limits.tables), int(limits.memories))):
		# node.free() triggers its unmount callback, and unmount_instance clears runtime
		# last_error. Preserve the instantiation diagnostic before cleanup.
		var runtime_error := str(_runtime.call("get_last_error"))
		host_context.close()
		node.free()
		return {"node": null, "context": null,
			"error": runtime_error, "diagnostic": _diagnostic(module,
				_runtime_error_code(runtime_error), "instantiate", runtime_error, instance_id)}
	var ids: Array = _instances.get(module_id, [])
	ids.append(instance_id)
	_instances[module_id] = ids
	_authorities[instance_id] = authority
	_host_contexts[instance_id] = host_context
	_instance_specs[instance_id] = {"module": module_id, "export": export_name, "node": node}
	return {"node": node, "context": {"module_id": module_id, "instance_id": instance_id,
		"module_hash": str(module.get("hash", "")), "origin": str(module.get("base_url", "")),
		"scene_root_handle": authority.root_handle(), "scene_authority": authority,
		"services": services, "host_context": host_context},
		"error": ""}


func deliver_event(module_id: String, event: Dictionary) -> Dictionary:
	if _event_delivery_active:
		if _queued_deliveries.size() >= WasmModuleServices.MAX_EVENTS:
			return {"ok": false, "error": "event_queue_limit", "diagnostics": []}
		_queued_deliveries.append({"module": module_id, "event": event.duplicate(true)})
		return {"ok": true, "error": "", "diagnostics": [], "queued": true}
	_event_delivery_active = true
	var result := _deliver_event_now(module_id, event)
	while not _queued_deliveries.is_empty():
		var queued: Dictionary = _queued_deliveries.pop_front()
		var delivered := _deliver_event_now(str(queued.module), queued.event)
		if not bool(delivered.ok):
			result.ok = false
			result.error = "; ".join([str(result.error), str(delivered.error)]).trim_prefix("; ")
			result.diagnostics.append_array(delivered.diagnostics)
	_event_delivery_active = false
	return result


func _deliver_event_now(module_id: String, event: Dictionary) -> Dictionary:
	module_id = module_id.trim_prefix("#")
	var errors: Array[String] = []
	var diagnostics: Array[Dictionary] = []
	var module: Dictionary = _prepared.get(module_id, {"id": module_id})
	for instance_id in _instances.get(module_id, []).duplicate():
		var scene_events: Array = []
		var service_events: Array = []
		if _host_contexts.has(instance_id):
			var services: WasmModuleServices = _host_contexts[instance_id].services
			services.poll()
			var kind := str(event.get("kind", ""))
			if not kind.is_empty():
				services.enqueue_input(kind, event.get("value", {}))
			service_events = services.drain_events()
			var authority: SceneAuthority = _host_contexts[instance_id].authority
			scene_events = authority.drain_events()
		var envelope := JSON.stringify({"kind": "host-events", "event": event,
			"scene": scene_events, "services": service_events}).to_utf8_buffer()
		if envelope.size() > WasmValueCodec.MAX_BYTE_BUFFER:
			var message := "%s: event_envelope_too_large" % instance_id
			errors.append(message)
			diagnostics.append(_diagnostic(module, "event_envelope_too_large", "event",
					message, instance_id))
			continue
		if not bool(_runtime.call("deliver_event_bytes", instance_id, envelope)):
			var runtime_error := str(_runtime.call("get_last_error"))
			var message := "%s: %s" % [instance_id, runtime_error]
			errors.append(message)
			diagnostics.append(_diagnostic(module, _runtime_error_code(runtime_error), "event",
					message, instance_id))
	return {"ok": errors.is_empty(), "error": "; ".join(errors), "diagnostics": diagnostics}


static func _runtime_error_code(message: String) -> String:
	var lower := message.to_lower()
	if lower.contains("fuel") or lower.contains("deadline") or lower.contains("epoch"):
		return "execution_budget_exhausted"
	if lower.contains("memory") or lower.contains("resource limit"):
		return "memory_limit_exceeded"
	if lower.contains("host call budget"):
		return "host_call_budget_exhausted"
	return "guest_trap"


static func _diagnostic(module: Dictionary, code: String, phase: String, message: String,
		instance_id: String = "") -> Dictionary:
	var stack := _safe_guest_stack(message)
	var source_location := ""
	var offset_regex := RegEx.new()
	offset_regex.compile("0x[0-9a-fA-F]+")
	var offset := offset_regex.search(stack)
	if offset != null: source_location = offset.get_string()
	var manifest: Dictionary = module.get("manifest", {})
	var debug: Dictionary = manifest.get("debug", {})
	var mapped_source := WasmSourceMap.map_message(message,
			str(module.get("debug_source_map_path", "")))
	if not mapped_source.is_empty():
		source_location = "%s:%d:%d" % [mapped_source.source, mapped_source.line,
				mapped_source.column]
	return {"code": code, "phase": phase, "message": message,
		"module": str(module.get("id", "")), "origin": str(module.get("base_url", "")),
		"hash": str(module.get("hash", "")), "instance": instance_id,
		"guest_stack": stack, "source_location": source_location,
		"debug_sidecar": str(debug.get("source_map", "")),
		"mapped_source": mapped_source}


static func _safe_guest_stack(message: String) -> String:
	var lines: Array[String] = []
	for raw_line in message.split("\n"):
		var line := str(raw_line).strip_edges()
		var lower := line.to_lower()
		if lower.contains("wasm backtrace") or lower.contains("wasm function") \
				or lower.contains("guest trap") or lower.begins_with("wasm["):
			lines.append(line.left(256))
			if lines.size() >= 8: break
	return "\n".join(lines).left(2048)


func unmount(module_id: String) -> void:
	module_id = module_id.trim_prefix("#")
	for instance_id in _instances.get(module_id, []).duplicate():
		_unmount_instance(module_id, instance_id)
	if _runtime != null:
		_runtime.call("drop_component", module_id)
	_prepared.erase(module_id)
	_module_states.erase(module_id)


func reload_module(module: Dictionary) -> Dictionary:
	var module_id := str(module.get("id", "")).trim_prefix("#")
	if not _prepared.has(module_id):
		return {"ok": false, "error": "module is not prepared", "replacements": [],
			"diagnostic": _diagnostic(module, "module_not_prepared", "reload",
					"module is not prepared")}
	var component_path := str(module.get("component_path", ""))
	if component_path.is_empty():
		return {"ok": false, "error": "component path is missing", "replacements": [],
			"diagnostic": _diagnostic(module, "component_path_missing", "reload",
					"component path is missing")}
	var candidate_id := "%s::reload-candidate::%d" % [module_id, _instance_seq]
	_instance_seq += 1
	if not bool(_runtime.call("prepare_component", candidate_id,
			ProjectSettings.globalize_path(component_path))):
		var runtime_error := str(_runtime.call("get_last_error"))
		return {"ok": false, "error": runtime_error, "replacements": [],
			"diagnostic": _diagnostic(module, "component_invalid", "reload", runtime_error)}
	var signature_errors := validate_signature(
			Array(_runtime.call("component_imports", candidate_id)),
			Array(_runtime.call("component_exports", candidate_id)), module, HOST_CAPABILITIES)
	if not signature_errors.is_empty():
		_runtime.call("drop_component", candidate_id)
		var message := "; ".join(signature_errors)
		return {"ok": false, "error": message, "replacements": [],
			"diagnostic": _diagnostic(module, "import_policy_denied", "reload", message)}

	# Probe every live export before touching the old component or its instances. Probe state is
	# isolated, so guest create/mount cannot modify the state preserved for the real module.
	var live_specs: Array[Dictionary] = []
	for instance_id in _instances.get(module_id, []).duplicate():
		if _instance_specs.has(instance_id):
			live_specs.append((_instance_specs[instance_id] as Dictionary).duplicate())
	var probe_module := module.duplicate(true)
	probe_module.id = candidate_id
	_prepared[candidate_id] = probe_module
	for export_name in live_specs.map(func(spec: Dictionary) -> String: return str(spec.export)):
		var probe := instantiate_export(candidate_id, str(export_name))
		if probe.node == null:
			_prepared.erase(candidate_id)
			_module_states.erase(candidate_id)
			_runtime.call("drop_component", candidate_id)
			return {"ok": false, "error": str(probe.error), "replacements": [],
				"diagnostic": _diagnostic(module, _runtime_error_code(str(probe.error)),
						"reload", str(probe.error))}
		probe.node.configure_unmount(Callable())
		_unmount_instance(candidate_id, str(probe.context.instance_id))
		probe.node.free()
	_prepared.erase(candidate_id)
	_module_states.erase(candidate_id)
	if not bool(_runtime.call("promote_component", candidate_id, module_id)):
		var promote_error := str(_runtime.call("get_last_error"))
		return {"ok": false, "error": promote_error, "replacements": [],
			"diagnostic": _diagnostic(module, "component_invalid", "reload", promote_error)}

	var old_hash := str((_prepared[module_id] as Dictionary).get("hash", ""))
	_prepared[module_id] = module
	var replacements: Array[Dictionary] = []
	for spec in live_specs:
		var old_node: Node3D = spec.node
		var parent := old_node.get_parent()
		var sibling_index := old_node.get_index() if parent != null else -1
		var old_name := old_node.name
		var old_transform := old_node.transform
		var old_instance_id := str(old_node.get_meta("vrweb_wasm_instance", ""))
		old_node.configure_unmount(Callable())
		_unmount_instance(module_id, old_instance_id)
		old_node.free()
		var made := instantiate_export(module_id, str(spec.export))
		if made.node == null:
			return {"ok": false, "error": str(made.error), "replacements": replacements,
				"diagnostic": _diagnostic(module, _runtime_error_code(str(made.error)),
						"reload", str(made.error))}
		made.node.name = old_name
		made.node.transform = old_transform
		if parent != null:
			parent.add_child(made.node)
			parent.move_child(made.node, mini(sibling_index, parent.get_child_count() - 1))
		replacements.append({"old_instance": old_instance_id, "node": made.node,
			"context": made.context})
	return {"ok": true, "error": "", "replacements": replacements,
		"old_hash": old_hash, "new_hash": str(module.get("hash", ""))}


func close() -> void:
	_queued_deliveries.clear()
	_event_delivery_active = false
	for module_id in _instances.keys().duplicate():
		unmount(str(module_id))
	if _runtime != null:
		_runtime.call("clear_components")
	_prepared.clear()
	_instances.clear()
	_authorities.clear()
	_host_contexts.clear()
	_instance_specs.clear()
	_module_states.clear()


func runtime_object() -> Object:
	return _runtime


func _unmount_instance(module_id: String, instance_id: String) -> void:
	if _runtime != null:
		_runtime.call("unmount_instance", instance_id)
	if _host_contexts.has(instance_id):
		_host_contexts[instance_id].close()
		_host_contexts.erase(instance_id)
	_authorities.erase(instance_id)
	_instance_specs.erase(instance_id)
	var ids: Array = _instances.get(module_id, [])
	ids.erase(instance_id)
	if ids.is_empty():
		_instances.erase(module_id)
	else:
		_instances[module_id] = ids
