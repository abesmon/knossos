class_name VrwebScriptAssets
extends RefCounted

## Composable remote-data capability for one Luau realm. Network and engine resources never
## cross the VM boundary: fetch returns portable values, while decoded resources are represented
## by opaque handles that can only be applied through VrwebDocumentHost's checked property path.

const MAX_FETCH_BYTES := 2 * 1024 * 1024
const MAX_RESOURCES := 64
const MAX_REQUESTS := 64
const RESPONSE_TYPES := {"text": true, "json": true, "bytes": true}
const RESOURCE_TYPES := {
	"image": true,
	"audio-mp3": true,
	"audio-ogg": true,
	"audio-wav": true,
	"mesh-gltf": true,
}

var _base_url := ""
var _script_id := ""
var _owner: Node
var _invoke: Callable
var _apply: Callable
var _policy: VrwebContentPolicy
var _valid := true
var _staging := true
var _pending: Array[Dictionary] = []
var _resources: Dictionary = {}
var _next_resource := 1
var _request_count := 0
var _fetch_loader: VrwebResourceLoader
var _resource_loader: VrwebResourceLoader
var _image_loader: ImageLoader


func setup(script_id: String, base_url: String, owner: Node, invoke: Callable, apply: Callable,
		policy: VrwebContentPolicy) -> void:
	_script_id = script_id
	_base_url = base_url
	_owner = owner
	_invoke = invoke
	_apply = apply
	_policy = policy


func api() -> Dictionary:
	return {
		"resolve": resolve,
		"fetch": fetch,
		"fetch_with": fetch_with,
		"load": load,
		"load_with": load_with,
		"decode": decode,
	}


func commit() -> bool:
	if not _valid or not is_instance_valid(_owner):
		return false
	_staging = false
	for request in _pending:
		_start(request)
	_pending.clear()
	return true


func close() -> void:
	if not _valid:
		return
	_valid = false
	_pending.clear()
	_resources.clear()
	_invoke = Callable()
	_apply = Callable()
	if is_instance_valid(_resource_loader):
		_resource_loader.queue_free()
	if is_instance_valid(_fetch_loader):
		_fetch_loader.queue_free()
	_fetch_loader = null
	_resource_loader = null
	_owner = null


func resolve(path: String):
	if not _valid:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if path.to_utf8_buffer().size() > 4096:
		return VrwebScriptError.err(VrwebScriptError.LIMIT)
	return PageFetcher.resolve_url(path, _base_url)


func fetch(path: String, response_type: String, callback: Callable):
	return _fetch(path, response_type, {}, callback)


func fetch_with(path: String, response_type: String, options: Dictionary,
		callback: Callable):
	return _fetch(path, response_type, options, callback)


func _fetch(path: String, response_type: String, options: Dictionary,
		callback: Callable):
	if not _valid:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not callback.is_valid() or not RESPONSE_TYPES.has(response_type):
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var url := _allowed_url(path, "script_asset_fetch")
	if url.is_empty():
		return VrwebScriptError.err(VrwebScriptError.DENIED)
	var credentials := _credential_headers(url, options)
	if not bool(credentials.ok):
		return VrwebScriptError.err(str(credentials.get("error", VrwebScriptError.DENIED)))
	return _enqueue({"operation": "fetch", "url": url, "type": response_type,
		"callback": callback, "headers": credentials.headers,
		"credentials": credentials.mode})


func load(path: String, resource_type: String, callback: Callable):
	return _load(path, resource_type, {}, callback)


func load_with(path: String, resource_type: String, options: Dictionary,
		callback: Callable):
	return _load(path, resource_type, options, callback)


func _load(path: String, resource_type: String, options: Dictionary,
		callback: Callable):
	if not _valid:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not callback.is_valid() or not RESOURCE_TYPES.has(resource_type):
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	var url := _allowed_url(path, "script_asset_load")
	if url.is_empty():
		return VrwebScriptError.err(VrwebScriptError.DENIED)
	var credentials := _credential_headers(url, options)
	if not bool(credentials.ok):
		return VrwebScriptError.err(str(credentials.get("error", VrwebScriptError.DENIED)))
	return _enqueue({"operation": "load", "url": url, "type": resource_type,
		"callback": callback, "headers": credentials.headers,
		"credentials": credentials.mode})


func decode(bytes: PackedByteArray, resource_type: String):
	if not _valid:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if _staging:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	if not RESOURCE_TYPES.has(resource_type) or bytes.is_empty():
		return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
	if bytes.size() > MAX_FETCH_BYTES:
		return VrwebScriptError.err(VrwebScriptError.LIMIT)
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_operation(
			"script_asset_decode", {"type": resource_type, "bytes": bytes.size()},
			{"source": "script", "script_id": _script_id})):
		return VrwebScriptError.err(VrwebScriptError.DENIED)
	var handle = _store_resource(_decode_bytes(bytes, resource_type, ""), resource_type, "")
	return handle if handle != null else VrwebScriptError.err(VrwebScriptError.UNSUPPORTED)


func resource(resource_id: int) -> Resource:
	var record: Dictionary = _resources.get(resource_id, {})
	return record.get("value") as Resource


func _enqueue(request: Dictionary):
	if _request_count >= MAX_REQUESTS:
		return VrwebScriptError.err(VrwebScriptError.LIMIT)
	_request_count += 1
	if _staging:
		_pending.append(request)
	else:
		_start(request)
	return true


func _start(request: Dictionary) -> void:
	if not _valid:
		return
	if str(request.operation) == "fetch":
		_fetcher().request_response(str(request.url), func(response):
			_finish_fetch(request, response), request.headers)
		return
	_start_load(request)


func _start_load(request: Dictionary) -> void:
	var url := str(request.url)
	var kind := str(request.type)
	var headers: PackedStringArray = request.headers
	if not headers.is_empty():
		_loader().request_response(url, func(response):
			_finish_loaded_bytes(request, response), headers)
		return
	if kind == "image":
		_images().request_image(url, func(value): _finish_resource(request, value))
	elif kind == "mesh-gltf":
		_loader().request_mesh(url, func(value): _finish_resource(request, value))
	else:
		_loader().request_audio(url, _audio_class(kind),
			func(value): _finish_resource(request, value))


func _finish_fetch(request: Dictionary, response: Dictionary) -> void:
	if not _valid:
		return
	_request_count = maxi(0, _request_count - 1)
	var bytes: PackedByteArray = response.body
	var status := int(response.status)
	var kind := str(request.type)
	var error := ""
	var data = null
	if bytes.is_empty():
		error = "http_%d" % status if status > 0 else "request_failed"
	elif bytes.size() > MAX_FETCH_BYTES:
		error = "response_too_large"
	elif kind == "bytes":
		data = bytes
	elif kind == "text":
		data = bytes.get_string_from_utf8()
	else:
		var parser := JSON.new()
		if parser.parse(bytes.get_string_from_utf8()) != OK:
			error = "invalid_json"
		else:
			data = parser.data
	_dispatch(request.callback, {"ok": error.is_empty(), "url": str(request.url),
		"response_type": kind, "data": data, "error": error, "status": status,
		"credentials": str(request.credentials)})


func _finish_loaded_bytes(request: Dictionary, response: Dictionary) -> void:
	if not _valid:
		return
	var value: Resource = null
	if not (response.body as PackedByteArray).is_empty() and int(response.status) < 400:
		value = _decode_bytes(response.body, str(request.type), str(request.url))
	_finish_resource(request, value, int(response.status))


func _finish_resource(request: Dictionary, value: Resource, status := 200) -> void:
	if not _valid:
		return
	_request_count = maxi(0, _request_count - 1)
	var handle = _store_resource(value, str(request.type), str(request.url))
	_dispatch(request.callback, {"ok": handle != null, "url": str(request.url),
		"resource_type": str(request.type), "resource": handle,
		"error": "" if handle != null else ("http_%d" % status if status >= 400 \
		else "decode_failed"), "status": status, "credentials": str(request.credentials)})


func _store_resource(value: Resource, resource_type: String, url: String):
	if value == null or _resources.size() >= MAX_RESOURCES:
		return null
	var resource_id := _next_resource
	_next_resource += 1
	_resources[resource_id] = {"value": value, "type": resource_type, "url": url}
	return {
		"__vrweb_host": "resource",
		"type": resource_type,
		"url": url,
		"apply": func(target: Dictionary, property: String):
			if not _valid or not _apply.is_valid():
				return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
			return _apply.call(resource_id, target, property),
	}


func _dispatch(callback: Callable, event: Dictionary) -> void:
	if _valid and _invoke.is_valid() and callback.is_valid():
		_invoke.call(callback, event)


func _allowed_url(path: String, operation: String) -> String:
	if path.to_utf8_buffer().size() > 4096:
		return ""
	var url := PageFetcher.resolve_url(path, _base_url)
	var allowed := url.begins_with("http://") or url.begins_with("https://")
	if url.begins_with(PageFetcher.LOCAL_SCHEME):
		allowed = _base_url.begins_with(PageFetcher.LOCAL_SCHEME)
	elif url.begins_with(PageFetcher.RESOURCE_SCHEME):
		allowed = _base_url.begins_with(PageFetcher.RESOURCE_SCHEME)
	if not allowed:
		return ""
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_operation(operation,
			{"url": url}, {"source": "script", "script_id": _script_id})):
		return ""
	return url


func _credential_headers(url: String, options: Dictionary) -> Dictionary:
	var mode := str(options.get("credentials", "same-origin"))
	if mode not in ["omit", "same-origin", "include"]:
		return {"ok": false, "headers": PackedStringArray(), "mode": mode,
			"error": VrwebScriptError.INVALID_ARGS}
	var headers := PackedStringArray()
	if mode != "omit":
		# Bearer is stronger than federated identity and may authorize account APIs. It is only
		# ambient when the document itself has the same web origin as the requested Home Server.
		var bearer := ""
		if _same_web_origin(_base_url, url):
			bearer = HomeServer.auth_header_for(url)
		if not bearer.is_empty():
			headers.append(bearer)
		elif mode == "include" and url.begins_with("https://"):
			headers = HomeServer.data_identity_headers_for(url)
			if headers.is_empty():
				return {"ok": false, "headers": headers, "mode": mode,
					"error": VrwebScriptError.DENIED}
		elif mode == "include" and not PageFetcher.is_local(url):
			return {"ok": false, "headers": headers, "mode": mode,
				"error": VrwebScriptError.DENIED}
	return {"ok": true, "headers": headers, "mode": mode}


static func _same_web_origin(left: String, right: String) -> bool:
	return not _web_origin(left).is_empty() and _web_origin(left) == _web_origin(right)


static func _web_origin(url: String) -> String:
	var scheme_end := url.find("://")
	if scheme_end == -1:
		return ""
	var scheme := url.substr(0, scheme_end).to_lower()
	if scheme not in ["http", "https"]:
		return ""
	var rest := url.substr(scheme_end + 3)
	return scheme + "://" + rest.get_slice("/", 0).to_lower()


func _loader() -> VrwebResourceLoader:
	if not is_instance_valid(_resource_loader):
		_resource_loader = VrwebResourceLoader.new()
		_resource_loader.name = "VrwebScriptResourceLoader"
		_owner.add_child(_resource_loader)
	return _resource_loader


func _fetcher() -> VrwebResourceLoader:
	if not is_instance_valid(_fetch_loader):
		_fetch_loader = VrwebResourceLoader.new()
		_fetch_loader.name = "VrwebScriptDataFetcher"
		_fetch_loader.max_bytes = MAX_FETCH_BYTES
		_owner.add_child(_fetch_loader)
	return _fetch_loader


func _images() -> ImageLoader:
	if is_instance_valid(_image_loader) and not _image_loader.is_queued_for_deletion():
		return _image_loader
	if is_instance_valid(_owner) and _owner.is_inside_tree():
		var candidate := _owner.get_tree().get_first_node_in_group(ImageLoader.GROUP) as ImageLoader
		_image_loader = candidate if is_instance_valid(candidate) \
				and not candidate.is_queued_for_deletion() else null
	if not is_instance_valid(_image_loader) or _image_loader.is_queued_for_deletion():
		_image_loader = ImageLoader.new()
		_image_loader.name = "VrwebScriptImageLoader"
		_owner.add_child(_image_loader)
	return _image_loader


static func _decode_bytes(bytes: PackedByteArray, resource_type: String, url: String) -> Resource:
	match resource_type:
		"image":
			return ImageLoader.decode_image(bytes, url)
		"mesh-gltf":
			return VrwebResourceLoader.extract_first_mesh(bytes)
		"audio-mp3", "audio-ogg", "audio-wav":
			return VrwebResourceLoader.decode_audio(bytes, _audio_class(resource_type))
	return null


static func _audio_class(resource_type: String) -> String:
	match resource_type:
		"audio-mp3": return "AudioStreamMP3"
		"audio-ogg": return "AudioStreamOggVorbis"
		"audio-wav": return "AudioStreamWAV"
	return ""
