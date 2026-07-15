class_name AvatarResolver
extends Node

## Резолвит идентификатор аватара (строку из identity-карточки игрока) в PackedScene.
## Две схемы:
##
##   vrwebavatar://N  — аватар №N из бандл-пака приложения (avatar_N.vrwml; локальный .tscn
##                      остаётся только dev fallback authoring-проекта).
##                      N — 1,2,3…; если N больше числа аватаров в паке, список
##                      ЗАКОЛЬЦОВЫВАЕТСЯ (по модулю). Грузится синхронно из res://.
##   http(s)://…vrwml — внешний data-only аватар: существующие HtmlParser/VrwebBuilder,
##                      контекстная allowlist, затем упаковка результата в PackedScene.
## Другие HTTP-форматы, включая `.tscn`, отклоняются и не обходят data-only policy через
## движковый PackedScene loader.

const PACK_DIR := "res://avatars/"
const SCHEME_BUNDLED := "vrwebavatar://"
const DEFAULT_URI := "vrwebavatar://1"
const MAX_BYTES := 32 * 1024 * 1024   # потолок размера внешнего аватара, байт
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"

var _image_loader: ImageLoader

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
		_resolve_bundled(uri, on_ready)
	elif uri.begins_with("http://") or uri.begins_with("https://"):
		_resolve_remote(uri, on_ready)
	else:
		# Неизвестная/пустая схема — дефолтный аватар из пака.
		_resolve_bundled(DEFAULT_URI, on_ready)


# --- vrwebavatar://N ---

func _resolve_bundled(uri: String, on_ready: Callable) -> void:
	var n := int(uri.substr(SCHEME_BUNDLED.length()))
	var count := _pack_count()
	if count <= 0:
		on_ready.call(null)
		return
	# Закольцовка: 1-based индекс по модулю числа аватаров в паке.
	var idx := ((n - 1) % count + count) % count + 1
	var vrwml_path := PACK_DIR + "avatar_%d.vrwml" % idx
	if FileAccess.file_exists(vrwml_path):
		_resolve_vrwml_text(FileAccess.get_file_as_string(vrwml_path), vrwml_path, on_ready)
		return
	on_ready.call(load(PACK_DIR + "avatar_%d.tscn" % idx) as PackedScene)


## Сколько аватаров в паке: считаем подряд avatar_1, avatar_2, … пока существуют.
func _pack_count() -> int:
	var c := 0
	while FileAccess.file_exists(PACK_DIR + "avatar_%d.vrwml" % (c + 1)) \
			or ResourceLoader.exists(PACK_DIR + "avatar_%d.tscn" % (c + 1)):
		c += 1
	return c


# --- http(s)://…vrwml ---

func _resolve_remote(uri: String, on_ready: Callable) -> void:
	if _uri_extension(uri) != "vrwml":
		Log.warn("avatar", "внешний аватар должен иметь расширение .vrwml: %s" % uri)
		on_ready.call(null)
		return
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	http.body_size_limit = MAX_BYTES
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code >= 400 or body.is_empty():
				Log.warn("avatar", "не удалось скачать VRWML-аватар: %s (result %d, code %d)" \
						% [uri, result, code])
				on_ready.call(null)
			else:
				_resolve_vrwml_text(body.get_string_from_utf8(), uri, on_ready)
	)
	if http.request(uri, ["User-Agent: " + USER_AGENT]) != OK:
		http.queue_free()
		on_ready.call(null)


# --- VRWML -> Avatar -> PackedScene ---

func _resolve_vrwml_text(text: String, base_url: String, on_ready: Callable) -> void:
	var doc := HtmlParser.parse(text)
	var policy := AvatarVrwmlPolicy.new()
	var built := VrwebBuilder.build(doc, base_url, null, policy)
	var holder := built.get("root") as Node3D
	if policy.has_errors():
		Log.warn("avatar", "части VRWML-аватара пропущены policy (%s): %s" % \
				[policy.summary(), base_url])
	if not bool(built.get("found", false)) or holder == null \
			or holder.get_child_count() != 1:
		Log.warn("avatar", "VRWML не создал единственный пригодный корень аватара: %s" % base_url)
		if holder != null:
			holder.free()
		on_ready.call(null)
		return
	var avatar := holder.get_child(0) as Avatar
	if avatar == null:
		Log.warn("avatar", "корень VRWML-документа не является Avatar: %s" % base_url)
		holder.free()
		on_ready.call(null)
		return
	holder.remove_child(avatar)
	holder.free()

	var finish := func() -> void:
		on_ready.call(_pack_avatar(avatar, base_url))
	var ext: Dictionary = built.get("ext", {})
	if ext.get("targets", []).is_empty():
		finish.call()
		return
	_ensure_image_loader()
	VrwebExtInjector.inject(ext, _image_loader, self, finish)


func _pack_avatar(avatar: Avatar, source: String) -> PackedScene:
	_set_owner_recursive(avatar, avatar)
	var packed := PackedScene.new()
	var err := packed.pack(avatar)
	avatar.free()
	if err != OK:
		Log.warn("avatar", "не удалось упаковать VRWML-аватар %s (код %d)" % [source, err])
		return null
	return packed


func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_owner_recursive(child, root)


func _ensure_image_loader() -> void:
	if _image_loader != null:
		return
	_image_loader = ImageLoader.new()
	_image_loader.name = "AvatarImageLoader"
	add_child(_image_loader)


func _uri_extension(uri: String) -> String:
	return uri.get_slice("?", 0).get_extension().to_lower()


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
