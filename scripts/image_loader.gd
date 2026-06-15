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
	# Локальные картинки (vrweblocal/vrwebresource) читаем синхронно через FileAccess —
	# без сети и пула HTTPRequest (см. docs/local-resources.md).
	if PageFetcher.is_local(url):
		var body := PackedByteArray()
		var path := PageFetcher.to_file_path(url)
		if path != "" and FileAccess.file_exists(path):
			body = FileAccess.get_file_as_bytes(path)
		_finish(url, body, PackedStringArray())
		return
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
	var ok := result == HTTPRequest.RESULT_SUCCESS and code < 400 and not body.is_empty()
	_finish(url, body if ok else PackedByteArray(), headers)


## Общий хвост для сетевых и локальных загрузок: декодирует байты (пустые -> заглушка),
## кэширует, будит ожидающих и подкручивает очередь. Освобождает один активный слот.
func _finish(url: String, body: PackedByteArray, headers: PackedStringArray) -> void:
	_active -= 1
	var tex: Texture2D = null
	if not body.is_empty():
		tex = _decode(url, body, headers)
	_cache[url] = tex

	for cb in _waiters.get(url, []):
		if cb.is_valid():
			cb.call(tex)
	_waiters.erase(url)
	_pump()


## Декодирует байты в текстуру строго по типу (Content-Type, иначе расширение url).
## Перебор кодеков НЕ делаем — это лишь засыпало бы консоль ошибками декодера на
## каждой картинке; не распознали тип -> отдаём null, и картинка получит заглушку.
## SVG поддерживаем, если в сборке Godot есть кодек.
func _decode(url: String, body: PackedByteArray, headers: PackedStringArray) -> Texture2D:
	var hint := _content_type(headers)
	if hint == "":
		hint = url.get_extension().to_lower()

	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED

	if hint.contains("png"):
		err = img.load_png_from_buffer(body)
	elif hint.contains("jpg") or hint.contains("jpeg"):
		# Встроенный в Godot декодер (jpgd) не умеет grayscale-JPEG с сэмплингом ≠ 1×1
		# (такие отдаёт, например, Wikimedia для ч/б фото). Не зовём декодер на заведомо
		# неподдерживаемых — иначе спам ошибок в консоли; вместо текстуры будет заглушка.
		if _jpeg_unsupported(body):
			return null
		err = img.load_jpg_from_buffer(body)
	elif hint.contains("gif"):
		# В Godot нет встроенного декодера GIF — декодируем сами и для многокадровых
		# отдаём самопроигрывающийся AnimatedTexture. См. docs/gif-support.md.
		return _decode_gif(body)
	elif hint.contains("webp"):
		err = img.load_webp_from_buffer(body)
	elif hint.contains("svg") and img.has_method("load_svg_from_buffer"):
		err = img.load_svg_from_buffer(body, 1.0)

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


## Декодирует GIF в текстуру. Один кадр -> обычный ImageTexture (дёшево, как статичная
## картинка). Несколько -> AnimatedTexture, который Godot проигрывает сам и который, будучи
## Texture2D, без правок встаёт в albedo_texture у потребителей. См. docs/gif-support.md.
## Кадры ужимаем сильнее обычного (анимация * N кадров — это память).
func _decode_gif(body: PackedByteArray) -> Texture2D:
	var frames := GifDecoder.decode(body)
	if frames.is_empty():
		return null

	var first: Image = frames[0]["image"]
	var w := first.get_width()
	var h := first.get_height()
	var max_side := 512
	var scale := 1.0
	if max(w, h) > max_side:
		scale = float(max_side) / float(max(w, h))
	var dst_w := maxi(1, int(w * scale))
	var dst_h := maxi(1, int(h * scale))

	if frames.size() == 1:
		if scale < 1.0:
			first.resize(dst_w, dst_h, Image.INTERPOLATE_BILINEAR)
		first.generate_mipmaps()
		return ImageTexture.create_from_image(first)

	# AnimatedTexture держит максимум 256 кадров — длинные гифки подрезаем.
	var count := mini(frames.size(), 256)
	var anim := AnimatedTexture.new()
	anim.frames = count
	anim.one_shot = false
	for i in range(count):
		var fimg: Image = frames[i]["image"]
		if scale < 1.0:
			fimg.resize(dst_w, dst_h, Image.INTERPOLATE_BILINEAR)
		anim.set_frame_texture(i, ImageTexture.create_from_image(fimg))
		anim.set_frame_duration(i, frames[i]["delay"])
	return anim


func _content_type(headers: PackedStringArray) -> String:
	for h in headers:
		if h.to_lower().begins_with("content-type:"):
			return h.substr(13).strip_edges().to_lower()
	return ""


## true, если это JPEG, который встроенный декодер Godot (jpgd) не осилит:
## одна компонента (grayscale) с фактором сэмплинга ≠ 1×1. Сканируем маркеры до SOF
## и смотрим число компонент и H/V первой. Сомневаемся (не нашли SOF, обрезано) — false:
## пусть декодер пробует сам.
func _jpeg_unsupported(body: PackedByteArray) -> bool:
	var n := body.size()
	if n < 4 or body[0] != 0xFF or body[1] != 0xD8:
		return false   # не JPEG — не наша забота
	var i := 2
	while i + 1 < n:
		if body[i] != 0xFF:
			i += 1
			continue
		var marker := body[i + 1]
		# Маркеры без полей длины: SOI/EOI, RSTn, TEM.
		if marker == 0xD8 or marker == 0xD9 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7):
			i += 2
			continue
		if i + 3 >= n:
			return false
		var seg_len := (body[i + 2] << 8) | body[i + 3]
		# SOF0..SOF15, кроме DHT(C4)/JPG(C8)/DAC(CC).
		if marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC:
			# Поля SOF: len(2) prec(1) height(2) width(2) Nf(1), затем по 3 байта на компоненту.
			if i + 9 >= n:
				return false
			var nf := body[i + 9]
			if nf != 1:
				return false   # цветной (3) jpgd тянет
			if i + 11 >= n:
				return false
			var hv := body[i + 11]   # байт (Hi<<4 | Vi) первой компоненты
			return (hv >> 4) > 1 or (hv & 0x0F) > 1
		i += 2 + seg_len
	return false
