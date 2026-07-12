class_name PageModuleFetcher
extends Node

## Async fetch + integrity + immutable cache. Не компилирует и не распаковывает модули.

const MAX_CONCURRENT := 4
const MAX_BYTES := PageModuleCache.MAX_ARTIFACT_BYTES
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"

var _generation := 0
var _queue: Array[Dictionary] = []
var _active := 0
var _results: Array[Dictionary] = []
var _errors: Array[Dictionary] = []
var _callback := Callable()
var _page_url := ""
var _requests: Array[HTTPRequest] = []


## on_done({modules, errors, cancelled}). Definitions — IR PageModuleCollector.
func fetch_all(definitions: Array, page_url: String, on_done: Callable) -> void:
	cancel()
	_generation += 1
	_page_url = page_url
	_callback = on_done
	_results = []
	_errors = []
	_queue = []
	for definition in definitions:
		var module: Dictionary = (definition as Dictionary).duplicate(true)
		if str(module.get("kind", "")) == "inline":
			_accept_bytes(module, "", str(module.get("source", "")).to_utf8_buffer(), "")
		else:
			var resolved := PageFetcher.resolve_url(str(module.get("src", "")),
					str(module.get("base_url", page_url)))
			if resolved.is_empty():
				_errors.append(_error(module, "invalid_url", "Некорректный URL модуля"))
			else:
				_queue.append({"module": module, "url": resolved, "generation": _generation})
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
		var bytes := FileAccess.get_file_as_bytes(path) if path != "" and FileAccess.file_exists(path) \
				else PackedByteArray()
		_complete(job, bytes, "" if not bytes.is_empty() else "read_failed")
		return
	var request := HTTPRequest.new()
	request.use_threads = true
	request.accept_gzip = true
	request.body_size_limit = MAX_BYTES
	# Не следуем redirect молча: финальный origin нужен integrity policy.
	request.max_redirects = 0
	add_child(request)
	_requests.append(request)
	request.request_completed.connect(func(result, code, _headers, body):
		_requests.erase(request)
		request.queue_free()
		var ok: bool = int(result) == HTTPRequest.RESULT_SUCCESS and int(code) >= 200 and int(code) < 300
		_complete(job, body if ok else PackedByteArray(), "" if ok else "http_%d" % code))
	var err := request.request(url, ["User-Agent: " + USER_AGENT,
		"Accept: application/vrweb-module+zip,text/x-gdscript,application/octet-stream"])
	if err != OK:
		_requests.erase(request)
		request.queue_free()
		_complete(job, PackedByteArray(), "request_%d" % err)


func _complete(job: Dictionary, bytes: PackedByteArray, fetch_error: String) -> void:
	_active = maxi(0, _active - 1)
	if int(job.generation) != _generation:
		return
	if not fetch_error.is_empty() or bytes.is_empty():
		_errors.append(_error(job.module, fetch_error, "Не удалось загрузить модуль"))
	else:
		_accept_bytes(job.module, str(job.url), bytes, "")
	_pump()
	_finish_if_ready()


func _accept_bytes(module: Dictionary, resolved_url: String, bytes: PackedByteArray,
		previous_hash: String) -> void:
	var checked := PageModuleIntegrity.verify(module, _page_url, resolved_url, bytes, previous_hash)
	if not bool(checked.allowed):
		_errors.append(_error(module, str(checked.code), "Integrity-проверка не пройдена"))
		return
	var cached := PageModuleCache.store(bytes)
	if not bool(cached.ok):
		_errors.append(_error(module, str(cached.error), "Не удалось сохранить module cache"))
		return
	module["resolved_url"] = resolved_url
	module["hash"] = str(checked.hash)
	module["sri"] = str(checked.sri)
	module["warnings"] = checked.warnings
	module["cache_path"] = str(cached.path)
	module["bytes"] = bytes
	_results.append(module)


func _finish_if_ready() -> void:
	if _active != 0 or not _queue.is_empty() or not _callback.is_valid():
		return
	var callback := _callback
	_callback = Callable()
	callback.call({"modules": _results, "errors": _errors, "cancelled": false})


static func _error(module: Dictionary, code: String, message: String) -> Dictionary:
	return {"module_id": str(module.get("id", "")), "code": code, "message": message}
