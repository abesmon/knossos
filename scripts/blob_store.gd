extends Node

## Хранилище realtime-ресурсов (autoload «BlobStore»): контент-адресуемые бинарные блобы,
## создаваемые во время сессии (картинки инструмента размещения и будущие типы). Адресация,
## лимиты и проверка контента — в чистом контракте BlobProtocol
## (scripts/ephemeral/blob_protocol.gd); здесь — хранение и асинхронная выдача.
## Полное описание — docs/network/realtime-resources.md.
##
## В эфемерный слой и props уходит только КОРОТКАЯ ссылка vrwebblob://sha256/<hex> (~75 байт);
## байты передаются отдельным p2p-протоколом (NetworkManager.request_blob) и проверяются по
## хэшу при приёме И при чтении дискового кэша — доверять источнику не нужно.
##
## Хранение: память (LRU, кап MAX_MEM_BYTES) + дисковый кэш user://blob_cache/<hex>
## (кап MAX_DISK_BYTES, вытеснение по mtime; чистится вместе с остальными кэшами — scripts/cache.gd).
## Store персистентный (autoload): блобы переживают навигацию и перезапуск — тот же блоб
## в новой комнате не качается заново.

const CACHE_DIR := "user://blob_cache/"

## Капы хранилища — защита от флуда чужими блобами (см. «Безопасность» в
## docs/network/realtime-resources.md): слой может сослаться на 256 объектов × 2 МиБ.
const MAX_MEM_BYTES := 64 * 1024 * 1024
const MAX_DISK_BYTES := 256 * 1024 * 1024

# --- Импорт картинок (инструмент размещения) ---
## Оригинал мельче этого порога кладём как есть (родной формат, GIF-анимация живёт);
## крупнее — перекодируем в WebP с ужатием стороны до IMPORT_MAX_SIDE.
const IMPORT_KEEP_BYTES := 512 * 1024
const IMPORT_MAX_SIDE := 1280
const IMPORT_WEBP_QUALITY := 0.85

var _mem := {}         # hex -> PackedByteArray; порядок вставки = LRU (переставляем при чтении)
var _mem_bytes := 0
var _waiters := {}     # hex -> Array[Callable(bytes: PackedByteArray)]


# --- Адресация (делегаты BlobProtocol — чтобы вызывающим не импортировать два имени) ---

func is_blob_url(url: String) -> bool:
	return BlobProtocol.is_blob_url(url)


func hex_of(url: String) -> String:
	return BlobProtocol.hex_of(url)


func url_of(hex: String) -> String:
	return BlobProtocol.url_of(hex)


# ============================================================================
#  Хранилище
# ============================================================================

## Положить локально созданный блоб. Возвращает ссылку vrwebblob://…; "" — пусто/сверх лимита.
func add(bytes: PackedByteArray) -> String:
	if bytes.is_empty() or bytes.size() > BlobProtocol.MAX_BLOB_BYTES:
		return ""
	var hex := BlobProtocol.hash_bytes(bytes)
	_store(hex, bytes)
	return BlobProtocol.url_of(hex)


func has_hex(hex: String) -> bool:
	return _mem.has(hex) or FileAccess.file_exists(_disk_path(hex))


## Байты блоба (пустой массив — нет локально). Диск сверяется по хэшу и поднимается в память.
func bytes_by_hex(hex: String) -> PackedByteArray:
	if _mem.has(hex):
		# LRU: свежепрочитанный — в хвост порядка вставки.
		var bytes: PackedByteArray = _mem[hex]
		_mem.erase(hex)
		_mem[hex] = bytes
		return bytes
	var path := _disk_path(hex)
	if FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		# Кэш мог побиться/быть подменён — байты, не совпадающие с адресом, не отдаём.
		if not bytes.is_empty() and bytes.size() <= BlobProtocol.MAX_BLOB_BYTES \
				and BlobProtocol.hash_bytes(bytes) == hex:
			_mem_put(hex, bytes)
			return bytes
	return PackedByteArray()


## Попросить блоб по ссылке. Есть локально — on_ready(bytes) отложенно (единый async-контракт);
## нет — ждун + запрос у пиров комнаты. Таймаута нет: блоб может приехать позже (автор
## переподключился, пришёл новый пир) — умершие консьюмеры отсеиваются по is_valid.
func request(url: String, on_ready: Callable) -> void:
	var hex := BlobProtocol.hex_of(url)
	if hex == "":
		on_ready.call_deferred(PackedByteArray())
		return
	var local := bytes_by_hex(hex)
	if not local.is_empty():
		on_ready.call_deferred(local)
		return
	if _waiters.has(hex):
		_waiters[hex].append(on_ready)
	else:
		_waiters[hex] = [on_ready]
	NetworkManager.request_blob(hex)


## Блоб приехал (из сети хэш уже сверен транспортом; из документа сверяет вызывающий —
## всё равно перепроверяем: это дёшево, а инвариант «в store только честные байты» дороже).
func ingest(hex: String, bytes: PackedByteArray) -> void:
	if bytes.is_empty() or bytes.size() > BlobProtocol.MAX_BLOB_BYTES \
			or BlobProtocol.hash_bytes(bytes) != hex:
		return
	_store(hex, bytes)
	for cb in _waiters.get(hex, []):
		if cb.is_valid():
			cb.call(bytes)
	_waiters.erase(hex)


## Хэши, которых ждут живые консьюмеры, — NetworkManager перезапрашивает их у новых пиров.
## Заодно чистим ожидания без живых колбэков (мир снесён навигацией).
func pending_hashes() -> Array:
	var out: Array = []
	for hex in _waiters.keys():
		var alive: Array = _waiters[hex].filter(func(cb: Callable) -> bool: return cb.is_valid())
		if alive.is_empty():
			_waiters.erase(hex)
		else:
			_waiters[hex] = alive
			out.append(hex)
	return out


func _store(hex: String, bytes: PackedByteArray) -> void:
	if not _mem.has(hex):
		_mem_put(hex, bytes)
	var dir := Sandbox.resolve(CACHE_DIR)
	var path := dir.path_join(hex)
	if FileAccess.file_exists(path):
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(bytes)
		f.close()
	_evict_disk(dir)


func _mem_put(hex: String, bytes: PackedByteArray) -> void:
	_mem[hex] = bytes
	_mem_bytes += bytes.size()
	# LRU-вытеснение из памяти: диск-копия остаётся, повторное чтение поднимет обратно.
	while _mem_bytes > MAX_MEM_BYTES and _mem.size() > 1:
		var oldest: String = _mem.keys()[0]
		if oldest == hex:
			break
		_mem_bytes -= (_mem[oldest] as PackedByteArray).size()
		_mem.erase(oldest)


## Вытеснение с диска по mtime (старые первыми), пока каталог не влезет в кап.
func _evict_disk(dir: String) -> void:
	var files: Array = []
	var total := 0
	var da := DirAccess.open(dir)
	if da == null:
		return
	da.list_dir_begin()
	var entry_name := da.get_next()
	while entry_name != "":
		if not da.current_is_dir():
			var full := dir.path_join(entry_name)
			var size := _file_size(full)
			total += size
			files.append({"path": full, "size": size, "mtime": FileAccess.get_modified_time(full)})
		entry_name = da.get_next()
	da.list_dir_end()
	if total <= MAX_DISK_BYTES:
		return
	files.sort_custom(func(a, b) -> bool: return int(a["mtime"]) < int(b["mtime"]))
	for rec in files:
		if total <= MAX_DISK_BYTES:
			break
		DirAccess.remove_absolute(str(rec["path"]))
		total -= int(rec["size"])


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := int(f.get_length())
	f.close()
	return size


func _disk_path(hex: String) -> String:
	return Sandbox.resolve(CACHE_DIR).path_join(hex)


# ============================================================================
#  Импорт картинок: файл пользователя -> компактный платформонезависимый блоб
# ============================================================================

## Превращает байты файла-изображения в блоб, возвращает ссылку ("" — не осилили).
## Мелкий оригинал (≤ IMPORT_KEEP_BYTES) сохраняем как есть — формат остаётся родным
## (в т.ч. GIF-анимация); крупный — декодируем, ужимаем сторону до IMPORT_MAX_SIDE и
## пережимаем в WebP (компактен и одинаково читается всеми платформами клиента).
func import_image(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var kind := _sniff(bytes)
	if kind == "":
		return ""
	if bytes.size() <= IMPORT_KEEP_BYTES:
		return add(bytes)
	var img := _decode(bytes, kind)
	if img == null or img.is_empty():
		return ""
	# Ужимаем до вменяемой стороны и пережимаем; всё ещё больше лимита — половиним
	# разрешение, пока не влезет (guard от вырождения).
	_shrink(img, IMPORT_MAX_SIDE)
	var packed := img.save_webp_to_buffer(true, IMPORT_WEBP_QUALITY)
	var guard := 0
	while packed.size() > BlobProtocol.MAX_BLOB_BYTES and guard < 4 and img.get_width() > 64:
		_shrink(img, maxi(64, floori(img.get_width() / 2.0)))
		packed = img.save_webp_to_buffer(true, IMPORT_WEBP_QUALITY)
		guard += 1
	if packed.is_empty() or packed.size() > BlobProtocol.MAX_BLOB_BYTES:
		return ""
	return add(packed)


## Формат по сигнатуре байтов ("" — не распознали). MIME/расширению не доверяем — как ImageLoader.
func _sniff(b: PackedByteArray) -> String:
	if b.size() >= 8 and b[0] == 0x89 and b[1] == 0x50 and b[2] == 0x4E and b[3] == 0x47:
		return "png"
	if b.size() >= 3 and b[0] == 0xFF and b[1] == 0xD8:
		return "jpg"
	if b.size() >= 3 and b[0] == 0x47 and b[1] == 0x49 and b[2] == 0x46:
		return "gif"
	if b.size() >= 12 and b[0] == 0x52 and b[1] == 0x49 and b[2] == 0x46 and b[3] == 0x46 \
			and b[8] == 0x57 and b[9] == 0x45 and b[10] == 0x42 and b[11] == 0x50:
		return "webp"
	return ""


func _decode(bytes: PackedByteArray, kind: String) -> Image:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match kind:
		"png":
			err = img.load_png_from_buffer(bytes)
		"jpg":
			err = img.load_jpg_from_buffer(bytes)
		"webp":
			err = img.load_webp_from_buffer(bytes)
		"gif":
			# Крупный GIF пережимаем ПЕРВЫМ КАДРОМ (статика): анимация сохраняется только
			# у мелких оригиналов (ветка «как есть» в import_image).
			var frames := GifDecoder.decode(bytes)
			if frames.is_empty():
				return null
			return frames[0]["image"]
	return img if err == OK else null


func _shrink(img: Image, max_side: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if maxi(w, h) <= max_side:
		return
	var k := float(max_side) / float(maxi(w, h))
	img.resize(maxi(1, int(w * k)), maxi(1, int(h * k)), Image.INTERPOLATE_BILINEAR)
