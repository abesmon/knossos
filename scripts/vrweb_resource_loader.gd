class_name VrwebResourceLoader
extends Node

## Асинхронная подгрузка нетекстурных внешних ресурсов VRWeb (<ExtResource>): аудио, меши,
## GLTF/GLB-сцены. Текстуры идут через отдельный ImageLoader (свой декод картинок); здесь —
## универсальная докачка сырых байтов (пул HTTPRequest, очередь, кэш по URL, локальные схемы)
## плюс статические декодеры байт -> ресурс/сцена Godot.
##
## Живёт внутри текущего мира (`_world`): при навигации мир сносится вместе с лоадером,
## незавершённые запросы умирают — нет смысла дотягивать ресурсы старой страницы.

const MAX_CONCURRENT := 4
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"
const MAX_BYTES := 48 * 1024 * 1024   # потолок размера ресурса, байт (защита от DoS)

## A dedicated consumer may lower the ceiling (script fetch uses 2 MiB). Keeping the limit on
## the shared loader building block means oversized bodies are rejected before entering cache.
var max_bytes := MAX_BYTES

var _cache: Dictionary = {}     # request key -> {body, status, result}
var _waiters: Dictionary = {}   # request key -> Array[Callable]
var _queue: Array[Dictionary] = []
var _active: int = 0


## Просит сырые байты для url. Когда готовы (или не удалось — тогда пустой массив) — зовёт
## on_ready(PackedByteArray). Дубликаты одного url коалесцируются, результат кэшируется.
func request_bytes(url: String, on_ready: Callable,
		headers: PackedStringArray = PackedStringArray()) -> void:
	request_response(url, func(response): on_ready.call(response.body), headers)


## Вариант для клиентов, которым кроме тела нужен HTTP status (например, script fetch различает
## 401/403 и transport failure). Заголовки входят в cache key, поэтому anonymous и identity
## ответы одного URL никогда не смешиваются.
func request_response(url: String, on_ready: Callable,
		headers: PackedStringArray = PackedStringArray()) -> void:
	if url == "":
		on_ready.call({"body": PackedByteArray(), "status": 0,
			"result": HTTPRequest.RESULT_CANT_CONNECT})
		return
	var key := _request_key(url, headers)
	if _cache.has(key):
		on_ready.call(_cache[key])
		return
	if _waiters.has(key):
		_waiters[key].append(on_ready)
		return
	_waiters[key] = [on_ready]
	_queue.append({"key": key, "url": url, "headers": headers.duplicate()})
	_pump()


## Просит GLTF/GLB-сцену для url. on_ready(Node) — корень сцены (или null, если не удалось).
func request_scene(url: String, on_ready: Callable) -> void:
	var res := _bundle_resource(url)
	if res is PackedScene:
		on_ready.call((res as PackedScene).instantiate())
		return
	request_bytes(url, func(bytes): on_ready.call(build_gltf_scene(bytes)))


## Просит первый Mesh из GLTF/GLB для url. on_ready(Mesh) — меш (или null, если не удалось).
func request_mesh(url: String, on_ready: Callable) -> void:
	var res := _bundle_resource(url)
	if res is Mesh:
		on_ready.call(res as Mesh)
		return
	if res is PackedScene:
		var scene := (res as PackedScene).instantiate()
		var mesh := _find_mesh(scene)
		scene.free()
		on_ready.call(mesh)
		return
	request_bytes(url, func(bytes): on_ready.call(extract_first_mesh(bytes)))


## Просит аудиопоток для url. type — ожидаемый класс (AudioStreamMP3/OggVorbis/WAV) для
## байтового декода; для бандл-ресурса тип берётся из импортированного потока. on_ready(AudioStream).
func request_audio(url: String, type: String, on_ready: Callable) -> void:
	var res := _bundle_resource(url)
	if res is AudioStream:
		on_ready.call(res as AudioStream)
		return
	request_bytes(url, func(bytes): on_ready.call(decode_audio(bytes, type)))


## Готовый импортированный ресурс бандла (vrwebresource://) или null, если это не бандл-ресурс
## либо Godot не знает такого ресурса (тогда грузим побайтово как обычно — сеть или файл ОС).
## ResourceLoader следует import-ремапу, поэтому работает и в билде (где лежит .ctex/.scn).
func _bundle_resource(url: String) -> Resource:
	if not PageFetcher.is_bundle_resource(url):
		return null
	var path := PageFetcher.to_file_path(url)
	if path == "" or not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path)


func _pump() -> void:
	while _active < MAX_CONCURRENT and not _queue.is_empty():
		_start(_queue.pop_front())


func _start(request: Dictionary) -> void:
	_active += 1
	var key := str(request.key)
	var url := str(request.url)
	# Локальные ресурсы (vrweblocal/vrwebresource) читаем синхронно через FileAccess.
	if PageFetcher.is_local(url):
		var body := PackedByteArray()
		var path := PageFetcher.to_file_path(url)
		if path != "" and FileAccess.file_exists(path):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null and file.get_length() <= max_bytes:
				body = file.get_buffer(file.get_length())
		_finish(key, {"body": body, "status": 200 if not body.is_empty() else 0,
			"result": HTTPRequest.RESULT_SUCCESS if not body.is_empty() \
			else HTTPRequest.RESULT_REQUEST_FAILED})
		return
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	http.body_size_limit = max_bytes
	# Credential headers must never be forwarded to another origin by an automatic redirect.
	# The caller receives 3xx and may explicitly re-issue a newly signed request to the next URL.
	if not (request.headers as PackedStringArray).is_empty():
		http.max_redirects = 0
	add_child(http)
	http.request_completed.connect(
		func(result, code, _headers, body): _on_done(key, http, result, code, body)
	)
	var headers: PackedStringArray = request.headers
	headers = headers.duplicate()
	headers.append("User-Agent: " + USER_AGENT)
	var err := http.request(url, headers)
	if err != OK:
		_on_done(key, http, HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray())


func _on_done(key: String, http: HTTPRequest, result: int, code: int,
		body: PackedByteArray) -> void:
	http.queue_free()
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300 \
			and not body.is_empty()
	_finish(key, {"body": body if ok else PackedByteArray(), "status": code, "result": result})


func _finish(key: String, response: Dictionary) -> void:
	_active -= 1
	_cache[key] = response
	for cb in _waiters.get(key, []):
		if cb.is_valid():
			cb.call(response)
	_waiters.erase(key)
	_pump()


static func _request_key(url: String, headers: PackedStringArray) -> String:
	return url if headers.is_empty() else url + "#headers=" + "\n".join(headers).sha256_text()


# --- Статические декодеры: байты -> ресурс/сцена Godot ---

## Аудиопоток из байтов по типу ресурса. null — пустые байты или неподдержанный тип.
static func decode_audio(bytes: PackedByteArray, type: String) -> AudioStream:
	if bytes.is_empty():
		return null
	match type:
		"AudioStreamMP3":
			var mp3 := AudioStreamMP3.new()
			mp3.data = bytes
			return mp3
		"AudioStreamOggVorbis":
			return AudioStreamOggVorbis.load_from_buffer(bytes)
		"AudioStreamWAV":
			return AudioStreamWAV.load_from_buffer(bytes)
	return null


## GLTF/GLB из байтов -> корневой Node сцены (с иерархией, мешами, материалами). null при ошибке.
## Поддерживаются самодостаточные .glb (внешние буферы .gltf не подтягиваются — base_path пуст).
static func build_gltf_scene(bytes: PackedByteArray) -> Node:
	if bytes.is_empty():
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		Log.warn("resload", "GLTF не распарсился (err %d)" % err)
		return null
	return doc.generate_scene(state)


## Первый Mesh из GLTF/GLB-сцены (для свойств вроде MeshInstance3D.mesh). null при ошибке.
## Временная сцена строится и тут же освобождается — Mesh (RefCounted) переживает.
static func extract_first_mesh(bytes: PackedByteArray) -> Mesh:
	var scene := build_gltf_scene(bytes)
	if scene == null:
		return null
	var mesh := _find_mesh(scene)
	scene.free()
	return mesh


static func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for c in node.get_children():
		var m := _find_mesh(c)
		if m != null:
			return m
	return null
