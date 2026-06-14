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

var _cache: Dictionary = {}     # url -> PackedByteArray (пусто = не удалось)
var _waiters: Dictionary = {}   # url -> Array[Callable]
var _queue: Array[String] = []
var _active: int = 0


## Просит сырые байты для url. Когда готовы (или не удалось — тогда пустой массив) — зовёт
## on_ready(PackedByteArray). Дубликаты одного url коалесцируются, результат кэшируется.
func request_bytes(url: String, on_ready: Callable) -> void:
	if url == "":
		on_ready.call(PackedByteArray())
		return
	if _cache.has(url):
		on_ready.call(_cache[url])
		return
	if _waiters.has(url):
		_waiters[url].append(on_ready)
		return
	_waiters[url] = [on_ready]
	_queue.append(url)
	_pump()


func _pump() -> void:
	while _active < MAX_CONCURRENT and not _queue.is_empty():
		_start(_queue.pop_front())


func _start(url: String) -> void:
	_active += 1
	# Локальные ресурсы (vrweblocal/vrwebresource) читаем синхронно через FileAccess.
	if PageFetcher.is_local(url):
		var body := PackedByteArray()
		var path := PageFetcher.to_file_path(url)
		if path != "" and FileAccess.file_exists(path):
			body = FileAccess.get_file_as_bytes(path)
		_finish(url, body)
		return
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	http.body_size_limit = MAX_BYTES
	add_child(http)
	http.request_completed.connect(
		func(result, code, _headers, body): _on_done(url, http, result, code, body)
	)
	var err := http.request(url, ["User-Agent: " + USER_AGENT])
	if err != OK:
		_on_done(url, http, HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray())


func _on_done(url: String, http: HTTPRequest, result: int, code: int, body: PackedByteArray) -> void:
	http.queue_free()
	var ok := result == HTTPRequest.RESULT_SUCCESS and code < 400 and not body.is_empty()
	_finish(url, body if ok else PackedByteArray())


func _finish(url: String, body: PackedByteArray) -> void:
	_active -= 1
	_cache[url] = body
	for cb in _waiters.get(url, []):
		if cb.is_valid():
			cb.call(body)
	_waiters.erase(url)
	_pump()


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
		push_warning("[VRWeb] GLTF не распарсился (err %d)" % err)
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
