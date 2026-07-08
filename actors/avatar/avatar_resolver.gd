class_name AvatarResolver
extends Node

## Резолвит идентификатор аватара (строку из identity-карточки игрока) в PackedScene.
## Две схемы:
##
##   vrwebavatar://N  — аватар №N из бандл-пака приложения (res://avatars/avatar_N.tscn).
##                      N — 1,2,3…; если N больше числа аватаров в паке, список
##                      ЗАКОЛЬЦОВЫВАЕТСЯ (по модулю). Грузится синхронно из res://.
##   http(s)://…tscn  — внешний аватар: качаем байты, кладём в кэш user:// и грузим как
##                      PackedScene. Самодостаточные сцены/ресурсы (или ссылающиеся только на
##                      ресурсы приложения) — ок; свои внешние ассеты не подтянутся.
##
## ВНИМАНИЕ (безопасность): внешний .tscn может нести скрипты/произвольные классы — его
## инстанцирование = выполнение чужого кода. Это тот же принятый риск, что и у VRWeb-страниц;
## до выхода на реальные URL источник аватаров должен быть доверенным. См. docs/avatars.md.

const PACK_DIR := "res://avatars/"
const SCHEME_BUNDLED := "vrwebavatar://"
const DEFAULT_URI := "vrwebavatar://1"
const CACHE_DIR := "user://avatar_cache/"
const MAX_BYTES := 32 * 1024 * 1024   # потолок размера внешнего аватара, байт
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"

# --- Манифест прав (см. docs/avatars.md → «Защита владения аватаром») ---
const MANIFEST_SUFFIX := ".manifest.json"
const MANIFEST_MAX_BYTES := 256 * 1024
const MANIFEST_TTL_MS := 5 * 60 * 1000   # манифест мутабелен — перечитываем по TTL
const MANIFEST_RETRIES := 1              # ретраи при СЕТЕВОЙ ошибке свежего фетча

# uri аватара -> { "m": AvatarManifest|null, "at": int(ms) } — TTL-кэш + last-known-good.
var _manifest_cache := {}


## Резолвит uri в PackedScene и зовёт on_ready(PackedScene). null — если не удалось.
## Бандл-схема отвечает синхронно (в этом же кадре), внешняя — после докачки.
func resolve(uri: String, on_ready: Callable) -> void:
	uri = uri.strip_edges()
	if uri.begins_with(SCHEME_BUNDLED):
		on_ready.call(_resolve_bundled(uri))
	elif uri.begins_with("http://") or uri.begins_with("https://"):
		_resolve_remote(uri, on_ready)
	else:
		# Неизвестная/пустая схема — дефолтный аватар из пака.
		on_ready.call(_resolve_bundled(DEFAULT_URI))


# --- vrwebavatar://N ---

func _resolve_bundled(uri: String) -> PackedScene:
	var n := int(uri.substr(SCHEME_BUNDLED.length()))
	var count := _pack_count()
	if count <= 0:
		return null
	# Закольцовка: 1-based индекс по модулю числа аватаров в паке.
	var idx := ((n - 1) % count + count) % count + 1
	return load(PACK_DIR + "avatar_%d.tscn" % idx) as PackedScene


## Сколько аватаров в паке: считаем подряд avatar_1, avatar_2, … пока существуют.
func _pack_count() -> int:
	var c := 0
	while ResourceLoader.exists(PACK_DIR + "avatar_%d.tscn" % (c + 1)):
		c += 1
	return c


# --- http(s)://…tscn ---

func _resolve_remote(uri: String, on_ready: Callable) -> void:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	http.body_size_limit = MAX_BYTES
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			on_ready.call(_scene_from_bytes(uri, result, code, body))
	)
	if http.request(uri, ["User-Agent: " + USER_AGENT]) != OK:
		http.queue_free()
		on_ready.call(null)


func _scene_from_bytes(uri: String, result: int, code: int, body: PackedByteArray) -> PackedScene:
	if result != HTTPRequest.RESULT_SUCCESS or code >= 400 or body.is_empty():
		Log.warn("avatar", "не удалось скачать аватар: %s (result %d, code %d)" % [uri, result, code])
		return null
	var cache_dir := Sandbox.resolve(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var ext := uri.get_slice("?", 0).get_file().get_extension()
	if ext == "":
		ext = "tscn"
	var path := cache_dir + str(hash(uri)) + "." + ext
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return null
	f.store_buffer(body)
	f.close()
	return ResourceLoader.load(path, "PackedScene") as PackedScene


# --- Манифест прав ---

## Резолвит манифест прав для uri аватара и зовёт on_manifest(AvatarManifest|null).
## null — манифеста нет / не достать (политика fail-state, см. docs/avatars.md). Бандл —
## синхронно; http — с TTL-кэшем, ретраем и last-known-good.
func resolve_manifest(uri: String, on_manifest: Callable) -> void:
	uri = uri.strip_edges()
	if uri.begins_with(SCHEME_BUNDLED):
		on_manifest.call(_manifest_bundled(uri))
	elif uri.begins_with("http://") or uri.begins_with("https://"):
		_manifest_remote(uri, on_manifest)
	else:
		on_manifest.call(_manifest_bundled(DEFAULT_URI))


## Адрес манифеста ВЫВОДИМ из адреса аватара (security-critical: не берём от пира). Файл
## аватара → сиблинг с расширением, заменённым на .manifest.json.
func _manifest_uri(uri: String) -> String:
	var q := uri.get_slice("?", 0)
	var dot := q.rfind(".")
	if dot > q.rfind("/"):
		return q.substr(0, dot) + MANIFEST_SUFFIX
	return q + MANIFEST_SUFFIX


func _manifest_bundled(uri: String) -> AvatarManifest:
	var n := int(uri.substr(SCHEME_BUNDLED.length()))
	var count := _pack_count()
	if count <= 0:
		return null
	var idx := ((n - 1) % count + count) % count + 1
	var path := PACK_DIR + "avatar_%d%s" % [idx, MANIFEST_SUFFIX]
	if not FileAccess.file_exists(path):
		return null
	return AvatarManifest.parse(FileAccess.get_file_as_string(path))


func _manifest_remote(uri: String, on_manifest: Callable, attempt: int = 0) -> void:
	var entry: Variant = _manifest_cache.get(uri)
	if entry != null and Time.get_ticks_msec() - int(entry["at"]) < MANIFEST_TTL_MS:
		on_manifest.call(entry["m"])
		return
	var http := HTTPRequest.new()
	http.use_threads = true
	http.body_size_limit = MANIFEST_MAX_BYTES
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result == HTTPRequest.RESULT_SUCCESS and code < 400 and not body.is_empty():
				var m := AvatarManifest.parse(body.get_string_from_utf8())
				_manifest_cache[uri] = {"m": m, "at": Time.get_ticks_msec()}
				on_manifest.call(m)
			elif result == HTTPRequest.RESULT_SUCCESS and code == 404:
				# Сервер ответил «нет манифеста» — валидный результат, кэшируем отсутствие.
				_manifest_cache[uri] = {"m": null, "at": Time.get_ticks_msec()}
				on_manifest.call(null)
			elif attempt < MANIFEST_RETRIES:
				_manifest_remote(uri, on_manifest, attempt + 1)   # ретрай при сетевой ошибке
			else:
				# Не достать. Last-known-good, если был; иначе null (→ UNCONFIRMED у вызывающего).
				on_manifest.call(entry["m"] if entry != null else null)
	)
	if http.request(_manifest_uri(uri), ["User-Agent: " + USER_AGENT]) != OK:
		http.queue_free()
		if attempt < MANIFEST_RETRIES:
			_manifest_remote(uri, on_manifest, attempt + 1)
		else:
			on_manifest.call(entry["m"] if entry != null else null)
