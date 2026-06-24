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
# Размер чанка чтения тела HTTPRequest. Дефолтные 64 КБ при use_threads дают массу итераций
# потока и режут пропускную способность в разы: при параллельной загрузке нескольких крупных
# картинок (фон-панорама + спрайты) скачивание 2–3 МБ тянулось ~11 с вместо ~3 с, и небо-
# панорама (последний крупный ресурс) подменялась с большой задержкой — выглядело как
# «залипание перед сменой скайбокса». 1 МБ упирает скачивание в скорость сети.
# См. docs/performance-streaming.md.
const DOWNLOAD_CHUNK_SIZE := 1 << 20

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
	# Локальные картинки (vrweblocal/vrwebresource) читаем без сети и пула HTTPRequest
	# (см. docs/local-resources.md). Но чтение+декод тяжёлые: на странице с кучей локальных
	# картинок синхронная цепочка _deliver→_pump→_start повесила бы кадр. Выносим за кадр —
	# тогда декодится не больше MAX_CONCURRENT картинок за кадр (слот занят, пока ждём).
	if PageFetcher.is_local(url):
		_start_local(url)
		return
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	http.download_chunk_size = DOWNLOAD_CHUNK_SIZE
	add_child(http)
	http.request_completed.connect(
		func(result, code, headers, body): _on_done(url, http, result, code, headers, body)
	)
	var err := http.request(url, ["User-Agent: " + USER_AGENT])
	if err != OK:
		_on_done(url, http, HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray())


## Локальный декод за кадр (см. _start). Слот _active занят, пока ждём, поэтому за кадр
## декодится не больше MAX_CONCURRENT картинок; _deliver освободит слот и подтянет очередь.
## Бандл-ресурс (vrwebresource://) в билде лежит импортированным (.ctex), сырых байтов по
## res://-пути нет — берём готовую текстуру через ResourceLoader. Файл ОС (vrweblocal://) или
## неимпортированный файл читаем сырыми байтами и декодируем сами (GIF — в фоновом потоке).
func _start_local(url: String) -> void:
	if is_inside_tree():
		await get_tree().process_frame
		# Навигация снесла мир вместе с лоадером, пока ждали кадр — выходим.
		if not is_instance_valid(self):
			return
	var path := PageFetcher.to_file_path(url)
	if path == "":
		_deliver(url, null)
		return
	if PageFetcher.is_bundle_resource(url) and ResourceLoader.exists(path):
		_deliver(url, ResourceLoader.load(path) as Texture2D)
		return
	if not FileAccess.file_exists(path):
		_deliver(url, null)
		return
	_finish(url, FileAccess.get_file_as_bytes(path), PackedStringArray())


func _on_done(url: String, http: HTTPRequest, result: int, code: int,
		headers: PackedStringArray, body: PackedByteArray) -> void:
	http.queue_free()
	var ok := result == HTTPRequest.RESULT_SUCCESS and code < 400 and not body.is_empty()
	_finish(url, body if ok else PackedByteArray(), headers)


## Декодирует байты и отдаёт текстуру дальше. GIF (распознаём по сигнатуре) уносим в фоновый
## поток — его самописный LZW-декод тяжёлый (сотни кадров -> секунды) и на главном потоке
## морозит приложение; _deliver_gif_async сам позовёт _deliver по готовности. Прочее декодим
## синхронно (быстро) прямо здесь.
func _finish(url: String, body: PackedByteArray, headers: PackedStringArray) -> void:
	if body.is_empty():
		_deliver(url, null)
		return
	if _is_gif(body):
		_deliver_gif_async(url, body)
		return
	_deliver(url, _decode(url, body, headers))


## true, если байты начинаются с сигнатуры GIF ("GIF87a"/"GIF89a" -> первые три "GIF").
static func _is_gif(body: PackedByteArray) -> bool:
	return body.size() >= 3 and body[0] == 0x47 and body[1] == 0x49 and body[2] == 0x46


## Кэширует готовую текстуру, будит ожидающих и подкручивает очередь. Освобождает один
## активный слот. Общая точка выхода для сетевых и локальных загрузок.
func _deliver(url: String, tex: Texture2D) -> void:
	_active -= 1
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


## Декод GIF без фриза: тяжёлую часть (самописный LZW-декод + ресайз кадров, потокобезопасная
## работа с Image) уносим в WorkerThreadPool, а на главном потоке держим только сборку текстур
## (RenderingServer). Слот _active занят на всё время, поэтому параллельно декодится не больше
## MAX_CONCURRENT картинок; по готовности — обычный _deliver. Навигация снесла лоадер, пока
## ждали поток -> молча выходим (дождавшись задачу, чтобы не утёк поток). См. docs/gif-support.md.
func _deliver_gif_async(url: String, body: PackedByteArray) -> void:
	var holder: Array = []  # потокобезопасно: поток дописывает, главный читает после ожидания
	var task := WorkerThreadPool.add_task(func(): holder.append(_gif_prepare(body)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
		if not is_instance_valid(self):
			WorkerThreadPool.wait_for_task_completion(task)
			return
	WorkerThreadPool.wait_for_task_completion(task)
	var prep: Array = holder[0] if not holder.is_empty() else []
	_deliver(url, _gif_build(prep))


## [Фоновый поток] GIF-байты -> массив подготовленных кадров [{image: Image, delay: float}],
## уже ужатых (анимация * N кадров — это память, режем сильнее статики до 512). Только Image-
## операции, без RenderingServer — безопасно вне главного потока. См. _deliver_gif_async.
static func _gif_prepare(body: PackedByteArray) -> Array:
	var frames := GifDecoder.decode(body)
	if frames.is_empty():
		return []

	var first: Image = frames[0]["image"]
	var w := first.get_width()
	var h := first.get_height()
	var max_side := 512
	var scale := 1.0
	if max(w, h) > max_side:
		scale = float(max_side) / float(max(w, h))
	var dst_w := maxi(1, int(w * scale))
	var dst_h := maxi(1, int(h * scale))

	# AnimatedTexture держит максимум 256 кадров — длинные гифки подрезаем (один кадр оставляем
	# как есть). Ресайз и mipmap'ы (для статики) — здесь, на потоке.
	var count := 1 if frames.size() == 1 else mini(frames.size(), 256)
	var out: Array = []
	for i in range(count):
		var fimg: Image = frames[i]["image"]
		if scale < 1.0:
			fimg.resize(dst_w, dst_h, Image.INTERPOLATE_BILINEAR)
		if frames.size() == 1:
			fimg.generate_mipmaps()
		out.append({"image": fimg, "delay": float(frames[i]["delay"])})
	return out


## [Главный поток] Подготовленные кадры -> текстура. Один кадр -> обычный ImageTexture (дёшево,
## как статичная картинка). Несколько -> самопроигрывающийся AnimatedTexture, который, будучи
## Texture2D, без правок встаёт в albedo_texture у потребителей. См. _deliver_gif_async.
func _gif_build(prep: Array) -> Texture2D:
	if prep.is_empty():
		return null
	if prep.size() == 1:
		return ImageTexture.create_from_image(prep[0]["image"])

	var anim := AnimatedTexture.new()
	anim.frames = prep.size()
	anim.one_shot = false
	for i in range(prep.size()):
		anim.set_frame_texture(i, ImageTexture.create_from_image(prep[i]["image"]))
		anim.set_frame_duration(i, prep[i]["delay"])
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
