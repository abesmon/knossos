class_name ImageLoader
extends Node

## Прогрессивная подгрузка картинок (Phase 1). После сборки мира объекты-картинки
## просят свою текстуру у этого сервиса; он качает байты через пул HTTPRequest'ов
## (ограниченная параллельность, очередь), декодирует в ImageTexture и кэширует по URL.
## Загрузка идёт асинхронно «после» генерации — как прогрессивная подгрузка на сайте.
##
## Живёт внутри текущего мира (`_world`): при навигации мир сносится вместе с лоадером,
## незавершённые запросы умирают — нет смысла дотягивать картинки старой страницы.

const MAX_CONCURRENT := 6
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"

var _cache: Dictionary = {}     # url -> Texture2D (null = не удалось)
var _waiters: Dictionary = {}   # url -> Array[Callable], ждут текстуру
var _queue: Array[String] = []  # url'ы в очереди на загрузку
var _active: int = 0


## Просит текстуру для url. Когда готова (или не удалось — тогда null) — зовёт on_ready(tex).
func request_image(url: String, on_ready: Callable) -> void:
	if url == "":
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
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	add_child(http)
	http.request_completed.connect(
		func(result, code, headers, body): _on_done(url, http, result, code, headers, body)
	)
	var err := http.request(url, ["User-Agent: " + USER_AGENT])
	if err != OK:
		_on_done(url, http, HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


func _on_done(url: String, http: HTTPRequest, result: int, code: int,
		headers: PackedStringArray, body: PackedByteArray) -> void:
	http.queue_free()
	_active -= 1

	var tex: Texture2D = null
	if result == HTTPRequest.RESULT_SUCCESS and code < 400 and not body.is_empty():
		tex = _decode(url, body, headers)
	_cache[url] = tex

	for cb in _waiters.get(url, []):
		if cb.is_valid():
			cb.call(tex)
	_waiters.erase(url)
	_pump()


## Декодирует байты в текстуру. Тип угадываем по Content-Type, иначе по расширению,
## иначе перебором кодеков. SVG поддерживаем, если в сборке Godot есть кодек.
func _decode(url: String, body: PackedByteArray, headers: PackedStringArray) -> Texture2D:
	var hint := _content_type(headers)
	if hint == "":
		hint = url.get_extension().to_lower()

	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED

	if hint.contains("png"):
		err = img.load_png_from_buffer(body)
	elif hint.contains("jpg") or hint.contains("jpeg"):
		err = img.load_jpg_from_buffer(body)
	elif hint.contains("webp"):
		err = img.load_webp_from_buffer(body)
	elif hint.contains("svg") and img.has_method("load_svg_from_buffer"):
		err = img.load_svg_from_buffer(body, 1.0)

	# Тип не распознан или не совпал — пробуем популярные кодеки по очереди.
	if err != OK:
		for codec in ["png", "jpg", "webp"]:
			var probe := Image.new()
			var e := OK
			match codec:
				"png": e = probe.load_png_from_buffer(body)
				"jpg": e = probe.load_jpg_from_buffer(body)
				"webp": e = probe.load_webp_from_buffer(body)
			if e == OK:
				img = probe
				err = OK
				break

	if err != OK or img.is_empty():
		return null

	# Большие картинки ужимаем — мир из сотен текстур не должен съесть память.
	var max_side := 1024
	var w := img.get_width()
	var h := img.get_height()
	if max(w, h) > max_side:
		var scale := float(max_side) / float(max(w, h))
		img.resize(int(w * scale), int(h * scale), Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _content_type(headers: PackedStringArray) -> String:
	for h in headers:
		if h.to_lower().begins_with("content-type:"):
			return h.substr(13).strip_edges().to_lower()
	return ""
