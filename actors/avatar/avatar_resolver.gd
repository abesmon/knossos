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
		push_warning("[Avatar] не удалось скачать аватар: %s (result %d, code %d)" % [uri, result, code])
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
