class_name BlobProtocol
extends RefCounted

## Движок-агностичный контракт realtime-ресурсов (блобов): адресация, лимиты и сборка
## бинарной передачи. Как SceneChanges — чистая логика без сети/Godot-сцены, чтобы тот же
## контракт могла реализовать не-Godot сторона; тестируется headless (tests/test_blob_transfer.gd).
## Полное описание — docs/network/realtime-resources.md.
##
## Блоб — НЕИЗМЕНЯЕМЫЕ байты, адрес — хэш содержимого: `vrwebblob://sha256/<64 hex>`.
## Контент проверяется хэшем, а не отправителем: качать можно у любого пира без доверия
## и без авторитета, подменить байты по ссылке нельзя.

const SCHEME := "vrwebblob://"
const ALGO := "sha256"

## Жёсткий потолок размера одного блоба — общий для импорта, p2p-передачи и флаша.
const MAX_BLOB_BYTES := 2 * 1024 * 1024
## Размер чанка бинарной передачи: безопасно мал для WebRTC-сообщения, достаточно велик,
## чтобы блоб-максимум уложился в 128 сообщений.
const CHUNK_BYTES := 16 * 1024


# ============================================================================
#  Адресация
# ============================================================================

static func is_blob_url(url: String) -> bool:
	return hex_of(url) != ""


## hex-хэш из ссылки; "" — не блоб-ссылка / кривой формат. Нормализуется к lowercase.
static func hex_of(url: String) -> String:
	if not url.begins_with(SCHEME):
		return ""
	var rest := url.substr(SCHEME.length())
	if not rest.begins_with(ALGO + "/"):
		return ""
	var hex := rest.substr(ALGO.length() + 1).to_lower()
	if not valid_hex(hex):
		return ""
	return hex


static func url_of(hex: String) -> String:
	return SCHEME + ALGO + "/" + hex


## 64 символа [0-9a-f] (hex sha256, lowercase).
static func valid_hex(hex: String) -> bool:
	if hex.length() != 64:
		return false
	for c in hex:
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
			return false
	return true


## sha256 байтов в hex — адрес блоба.
static func hash_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():   # update() пустым буфером — ошибка движка; пусто = хэш пустого
		ctx.update(bytes)
	return ctx.finish().hex_encode()


# ============================================================================
#  Передача: чанкование (сторона отправителя)
# ============================================================================

## Число чанков для блоба данного размера.
static func chunk_count(size: int) -> int:
	return int(ceil(float(size) / float(CHUNK_BYTES)))


## i-й чанк байтов (пустой — вне диапазона).
static func chunk_at(bytes: PackedByteArray, index: int) -> PackedByteArray:
	var from := index * CHUNK_BYTES
	if from < 0 or from >= bytes.size():
		return PackedByteArray()
	return bytes.slice(from, mini(from + CHUNK_BYTES, bytes.size()))


# ============================================================================
#  Передача: сборка (сторона получателя)
# ============================================================================

## Аккумулятор одного входящего блоба. Валидирует каждый чанк против заявленного размера
## и в конце сверяет sha256 с адресом — мусор от провайдера не может стать блобом.
class Rx:
	extends RefCounted

	var hex := ""          # ожидаемый адрес (hex sha256)
	var size := 0          # заявленный полный размер, байт
	var total := 0         # ожидаемое число чанков (выводится из size)
	var _chunks := {}      # index -> PackedByteArray
	var _received := 0     # суммарно принятых байт (защита от переполнения)

	## Начать приём. false — заявка невалидна (кривой hex / размер вне лимитов).
	func begin(blob_hex: String, blob_size: int) -> bool:
		if not BlobProtocol.valid_hex(blob_hex):
			return false
		if blob_size <= 0 or blob_size > BlobProtocol.MAX_BLOB_BYTES:
			return false
		hex = blob_hex
		size = blob_size
		total = BlobProtocol.chunk_count(blob_size)
		_chunks = {}
		_received = 0
		return true

	## Принять чанк. false — чанк невалиден (индекс/размер не сходятся с заявкой);
	## дубликат валидного индекса — true (идемпотентно, повторно не считается).
	func put_chunk(index: int, bytes: PackedByteArray) -> bool:
		if hex == "" or index < 0 or index >= total or bytes.is_empty():
			return false
		# Все чанки, кроме последнего, — ровно CHUNK_BYTES; последний — остаток.
		var expected := BlobProtocol.CHUNK_BYTES if index < total - 1 \
				else size - (total - 1) * BlobProtocol.CHUNK_BYTES
		if bytes.size() != expected:
			return false
		if _chunks.has(index):
			return true
		_chunks[index] = bytes
		_received += bytes.size()
		return true

	func is_complete() -> bool:
		return hex != "" and _chunks.size() == total and _received == size

	## Собрать и сверить с адресом. Пустой массив — не всё принято или хэш не сошёлся
	## (мусорный провайдер) — вызывающий сбрасывает приём и ретраит у другого пира.
	func assemble() -> PackedByteArray:
		if not is_complete():
			return PackedByteArray()
		var out := PackedByteArray()
		for i in range(total):
			out.append_array(_chunks[i])
		if BlobProtocol.hash_bytes(out) != hex:
			return PackedByteArray()
		return out
