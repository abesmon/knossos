extends SceneTree

## Юнит-тест чистого контракта realtime-ресурсов (BlobProtocol) — адресация, sha256,
## чанкование и сборка с проверкой хэша. Без сети/автолоадов. Запуск:
##   godot --headless --path . --script res://tests/test_blob_transfer.gd
## Выход 0 — все проверки прошли, иначе 1.

var _failed := false

## sha256 известных векторов (hex).
const SHA_EMPTY := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const SHA_ABC := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


func _initialize() -> void:
	_test_addressing()
	_test_hash()
	_test_chunking()
	_test_rx_roundtrip()
	_test_rx_rejects()
	quit(1 if _failed else 0)


func _test_addressing() -> void:
	var url := BlobProtocol.url_of(SHA_ABC)
	_eq(url, "vrwebblob://sha256/" + SHA_ABC, "url_of собирает схему")
	_eq(BlobProtocol.hex_of(url), SHA_ABC, "hex_of разбирает обратно")
	_eq(BlobProtocol.is_blob_url(url), true, "is_blob_url на валидной ссылке")
	_eq(BlobProtocol.hex_of("vrwebblob://sha256/" + SHA_ABC.to_upper()), SHA_ABC,
		"hex нормализуется к lowercase")
	_eq(BlobProtocol.hex_of("https://example.org/x.png"), "", "чужая схема — не блоб")
	_eq(BlobProtocol.hex_of("vrwebblob://md5/" + SHA_ABC), "", "чужой алгоритм — отказ")
	_eq(BlobProtocol.hex_of("vrwebblob://sha256/deadbeef"), "", "короткий hex — отказ")
	_eq(BlobProtocol.hex_of("vrwebblob://sha256/" + SHA_ABC.substr(1) + "g"), "",
		"не-hex символ — отказ")


func _test_hash() -> void:
	_eq(BlobProtocol.hash_bytes(PackedByteArray()), SHA_EMPTY, "sha256 пустых байтов")
	_eq(BlobProtocol.hash_bytes("abc".to_utf8_buffer()), SHA_ABC, "sha256(\"abc\")")


func _test_chunking() -> void:
	_eq(BlobProtocol.chunk_count(1), 1, "1 байт — 1 чанк")
	_eq(BlobProtocol.chunk_count(BlobProtocol.CHUNK_BYTES), 1, "ровно чанк — 1")
	_eq(BlobProtocol.chunk_count(BlobProtocol.CHUNK_BYTES + 1), 2, "чанк+1 — 2")
	var bytes := _make_bytes(BlobProtocol.CHUNK_BYTES + 100)
	_eq(BlobProtocol.chunk_at(bytes, 0).size(), BlobProtocol.CHUNK_BYTES, "первый чанк полный")
	_eq(BlobProtocol.chunk_at(bytes, 1).size(), 100, "последний чанк — остаток")
	_eq(BlobProtocol.chunk_at(bytes, 2).size(), 0, "за диапазоном — пусто")
	_eq(BlobProtocol.chunk_at(bytes, -1).size(), 0, "отрицательный индекс — пусто")


func _test_rx_roundtrip() -> void:
	var bytes := _make_bytes(BlobProtocol.CHUNK_BYTES * 2 + 777)
	var hex := BlobProtocol.hash_bytes(bytes)
	var rx := BlobProtocol.Rx.new()
	_eq(rx.begin(hex, bytes.size()), true, "begin принимает валидную заявку")
	_eq(rx.total, 3, "3 чанка")
	# Не по порядку + дубликат: сборка не зависит от порядка, дубликат идемпотентен.
	_eq(rx.put_chunk(2, BlobProtocol.chunk_at(bytes, 2)), true, "последний чанк принят")
	_eq(rx.put_chunk(0, BlobProtocol.chunk_at(bytes, 0)), true, "первый чанк принят")
	_eq(rx.put_chunk(0, BlobProtocol.chunk_at(bytes, 0)), true, "дубликат — идемпотентно")
	_eq(rx.is_complete(), false, "без среднего чанка не собран")
	_eq(rx.put_chunk(1, BlobProtocol.chunk_at(bytes, 1)), true, "средний чанк принят")
	_eq(rx.is_complete(), true, "все чанки на месте")
	_eq(rx.assemble(), bytes, "сборка воспроизводит байты и сходится по хэшу")


func _test_rx_rejects() -> void:
	var rx := BlobProtocol.Rx.new()
	_eq(rx.begin("xyz", 100), false, "кривой hex — отказ")
	_eq(rx.begin(SHA_ABC, 0), false, "нулевой размер — отказ")
	_eq(rx.begin(SHA_ABC, BlobProtocol.MAX_BLOB_BYTES + 1), false, "сверх лимита — отказ")

	var bytes := _make_bytes(BlobProtocol.CHUNK_BYTES + 5)
	var rx2 := BlobProtocol.Rx.new()
	_eq(rx2.begin(BlobProtocol.hash_bytes(bytes), bytes.size()), true, "заявка ок")
	_eq(rx2.put_chunk(0, PackedByteArray([1, 2, 3])), false, "неполный не-последний чанк — отказ")
	_eq(rx2.put_chunk(5, BlobProtocol.chunk_at(bytes, 0)), false, "индекс за диапазоном — отказ")
	_eq(rx2.put_chunk(1, _make_bytes(6)), false, "последний чанк не того размера — отказ")

	# Мусорный провайдер: чанки правильной ФОРМЫ, но не те байты — ловится финальным хэшем.
	var rx3 := BlobProtocol.Rx.new()
	rx3.begin(BlobProtocol.hash_bytes(bytes), bytes.size())
	var fake := _make_bytes(bytes.size())
	fake[0] = 255 - fake[0]
	_eq(rx3.put_chunk(0, BlobProtocol.chunk_at(fake, 0)), true, "форма чанка валидна")
	_eq(rx3.put_chunk(1, BlobProtocol.chunk_at(fake, 1)), true, "форма чанка валидна")
	_eq(rx3.is_complete(), true, "формально собран")
	_eq(rx3.assemble(), PackedByteArray(), "хэш не сошёлся — сборка отвергнута")


func _make_bytes(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	for i in range(n):
		out[i] = (i * 31 + 7) % 256
	return out


func _eq(actual, expected, msg: String) -> void:
	if actual != expected:
		_failed = true
		push_error("FAIL: %s (got %s, expected %s)" % [msg, str(actual), str(expected)])
