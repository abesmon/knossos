class_name VrwebScriptFetcher
extends Node

## Ordered inline/linked source fetcher. It never accepts bytecode or packages.

const MAX_CONCURRENT := 4
const MAX_BYTES := VrwebScriptDeclaration.MAX_SOURCE_BYTES
const REQUEST_TIMEOUT_SECONDS := 15.0
const MAX_REDIRECTS := 8
const USER_AGENT := "VRWeb/0.2 (Knossos; Luau)"

var _generation := 0
var _queue: Array[Dictionary] = []
var _active := 0
var _results: Dictionary = {}
var _errors: Array[Dictionary] = []
var _callback := Callable()
var _requests: Array[HTTPRequest] = []


func fetch_all(declarations: Array, on_done: Callable) -> void:
	cancel()
	_generation += 1
	_results.clear()
	_errors.clear()
	_queue.clear()
	_callback = on_done
	for index in declarations.size():
		var declaration: Dictionary = declarations[index].duplicate(true)
		if declaration.kind == "inline":
			_accept(index, declaration, "", str(declaration.source).to_utf8_buffer())
			continue
		var resolved := PageFetcher.resolve_url(str(declaration.src), str(declaration.base_url))
		if resolved.is_empty():
			_errors.append(_error(declaration, "invalid_url", "Некорректный script URL"))
		elif not _url_allowed(resolved, str(declaration.base_url)):
			_errors.append(_error(declaration, "forbidden_url",
					"Script URL выходит за разрешённую transport boundary"))
		else:
			_queue.append({"index": index, "declaration": declaration, "url": resolved,
				"generation": _generation})
	_pump()
	_finish_if_ready()


func cancel() -> void:
	_generation += 1
	_queue.clear()
	for request in _requests:
		if is_instance_valid(request):
			request.cancel_request()
			request.queue_free()
	_requests.clear()
	_active = 0
	_callback = Callable()


func _pump() -> void:
	while _active < MAX_CONCURRENT and not _queue.is_empty():
		_start(_queue.pop_front())


func _start(job: Dictionary) -> void:
	_active += 1
	var url := str(job.url)
	if PageFetcher.is_local(url):
		var path := PageFetcher.to_file_path(url)
		var bytes := FileAccess.get_file_as_bytes(path) if not path.is_empty() \
				and FileAccess.file_exists(path) else PackedByteArray()
		_complete(job, bytes, "" if not bytes.is_empty() else "read_failed")
		return
	var request := HTTPRequest.new()
	request.use_threads = true
	request.accept_gzip = true
	request.body_size_limit = MAX_BYTES
	request.timeout = REQUEST_TIMEOUT_SECONDS
	request.max_redirects = MAX_REDIRECTS
	add_child(request)
	_requests.append(request)
	request.request_completed.connect(func(result, code, _headers, body):
		_requests.erase(request)
		request.queue_free()
		var ok := int(result) == HTTPRequest.RESULT_SUCCESS and int(code) >= 200 and int(code) < 300
		_complete(job, body if ok else PackedByteArray(), "" if ok else "http_%d" % code))
	var error := request.request(url, ["User-Agent: " + USER_AGENT,
		"Accept: application/vrweb+luau,text/plain,application/octet-stream"])
	if error != OK:
		_requests.erase(request)
		request.queue_free()
		_complete(job, PackedByteArray(), "request_%d" % error)


func _complete(job: Dictionary, bytes: PackedByteArray, fetch_error: String) -> void:
	if int(job.generation) != _generation:
		return
	_active = maxi(0, _active - 1)
	if not fetch_error.is_empty() or bytes.is_empty():
		_errors.append(_error(job.declaration, fetch_error, "Не удалось загрузить script"))
	elif bytes.size() > MAX_BYTES:
		_errors.append(_error(job.declaration, "too_large", "Script превышает лимит"))
	else:
		_accept(int(job.index), job.declaration, str(job.url), bytes)
	_pump()
	_finish_if_ready()


func _accept(index: int, declaration: Dictionary, resolved_url: String,
		bytes: PackedByteArray) -> void:
	var checked := VrwebScriptIntegrity.verify(declaration, bytes)
	if not bool(checked.ok):
		_errors.append(_error(declaration, str(checked.code), "Integrity-проверка не пройдена"))
		return
	declaration["source"] = bytes.get_string_from_utf8()
	declaration["resolved_url"] = resolved_url
	declaration["hash"] = str(checked.hash)
	declaration["sri"] = str(checked.sri)
	_results[index] = declaration


func _finish_if_ready() -> void:
	if _active != 0 or not _queue.is_empty() or not _callback.is_valid():
		return
	var ordered: Array[Dictionary] = []
	var indexes := _results.keys()
	indexes.sort()
	for index in indexes:
		ordered.append(_results[index])
	var callback := _callback
	_callback = Callable()
	callback.call({"scripts": ordered, "errors": _errors, "cancelled": false})


static func _error(declaration: Dictionary, code: String, message: String) -> Dictionary:
	return {"script_id": str(declaration.get("id", "")), "code": code, "message": message}


static func _url_allowed(resolved_url: String, base_url: String) -> bool:
	if resolved_url.begins_with("http://") or resolved_url.begins_with("https://"):
		return true
	# Local schemes are an explicit local-page capability. A remote page may not turn a
	# linked script into a read/execute primitive over the user's filesystem or app bundle.
	if resolved_url.begins_with(PageFetcher.LOCAL_SCHEME):
		return base_url.begins_with(PageFetcher.LOCAL_SCHEME)
	if resolved_url.begins_with(PageFetcher.RESOURCE_SCHEME):
		return base_url.begins_with(PageFetcher.RESOURCE_SCHEME)
	return false
