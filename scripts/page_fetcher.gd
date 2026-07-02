class_name PageFetcher
extends Node

## Сервис загрузки HTML по URL через HTTPRequest (без исполнения JS — Phase 1).
## Сам нормализует адрес и резолвит относительные ссылки.

signal fetched(html: String, final_url: String)
signal failed(message: String, url: String)

var _http: HTTPRequest
var _requested_url: String = ""

const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"

## Локальные схемы для тестового/офлайн-запуска (см. docs/local-resources.md).
## vrweblocal://<абсолютный путь ФС>  — файл из операционной системы.
## vrwebresource://<относительный путь> — файл из бандла приложения (RESOURCE_ROOT).
## Обе ведут себя как обычный origin: относительные ссылки/картинки резолвятся
## внутри той же схемы, так что локальная страница со своими img/href работает целиком.
const LOCAL_SCHEME := "vrweblocal://"
const RESOURCE_SCHEME := "vrwebresource://"
## Корень бандл-ресурсов, куда отображается vrwebresource://.
const RESOURCE_ROOT := "res://test_pages/"


func _ready() -> void:
	_http = HTTPRequest.new()
	# Многие сайты отдают gzip — пусть Godot распакует сам.
	_http.accept_gzip = true
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


## Загружает страницу. base_url — для разрешения относительного url.
func fetch(url: String, base_url: String = "") -> void:
	var resolved := resolve_url(url, base_url)
	if resolved == "":
		failed.emit("Пустой или некорректный адрес", url)
		return
	_requested_url = resolved
	if is_local(resolved):
		_fetch_local(resolved)
		return
	var headers := [
		"User-Agent: " + USER_AGENT,
		"Accept: text/html,application/xhtml+xml",
	]
	var err := _http.request(resolved, headers)
	if err != OK:
		failed.emit("Не удалось начать запрос (код %d)" % err, resolved)


## Прерывает текущий сетевой запрос (если он идёт). Локальный фетч синхронен — отменять нечего.
## После отмены request_completed не эмитится, так что fetched/failed не придут.
func cancel() -> void:
	if _http != null:
		_http.cancel_request()


## Читает локальный файл синхронно через FileAccess (без сети) и эмитит fetched/failed.
## final_url — та же vrweb-схема, чтобы относительные ссылки страницы резолвились дальше.
func _fetch_local(url: String) -> void:
	var path := to_file_path(url)
	if path == "":
		failed.emit("Некорректный локальный адрес", url)
		return
	if not FileAccess.file_exists(path):
		failed.emit("Файл не найден: %s" % path, url)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		failed.emit("Не удалось открыть файл (код %d)" % FileAccess.get_open_error(), url)
		return
	fetched.emit(f.get_as_text(), url)


func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		failed.emit("Сетевая ошибка (result %d)" % result, _requested_url)
		return
	if response_code >= 400:
		failed.emit("HTTP %d" % response_code, _requested_url)
		return
	# Редирект на финальный URL (для корректного резолва относительных ссылок далее).
	var final_url := _requested_url
	for h in headers:
		if h.to_lower().begins_with("location:"):
			final_url = h.substr(9).strip_edges()
	var html := body.get_string_from_utf8()
	if html == "":
		html = body.get_string_from_ascii()
	fetched.emit(html, final_url)


## Приводит адрес к абсолютному. Поддерживает: абсолютные http(s), локальные
## схемы (vrweblocal/vrwebresource), //host, /path, относительные пути и якоря.
static func resolve_url(url: String, base_url: String = "") -> String:
	url = url.strip_edges()
	if url == "":
		return ""

	if url.begins_with("http://") or url.begins_with("https://"):
		return _escape_http_url(url)
	# Локальные схемы абсолютны сами по себе, независимо от base.
	if is_local(url):
		return _normalize_local(url)
	# Относительная ссылка/картинка на локальной странице — резолвим внутри той же схемы.
	if is_local(base_url):
		return _join_local(_scheme_of(base_url), base_url, url)
	if url.begins_with("//"):
		var scheme := "https:"
		if base_url.begins_with("http://"):
			scheme = "http:"
		return _escape_http_url(scheme + url)

	if base_url == "":
		# Нет базы — трактуем ввод как домен.
		if url.contains(".") and not url.contains(" "):
			return "https://" + url
		return ""

	var base := _split_base(base_url)
	var origin: String = base["origin"]
	var dir: String = base["dir"]

	if url.begins_with("/"):
		return _escape_http_url(origin + url)
	if url.begins_with("#"):
		return base_url.get_slice("#", 0) + url
	return _escape_http_url(_normalize_path(origin + dir + url))


# --- Локальные схемы (vrweblocal / vrwebresource) ---

## true, если адрес относится к локальной схеме (файл ОС или бандл-ресурс).
static func is_local(url: String) -> bool:
	return url.begins_with(LOCAL_SCHEME) or url.begins_with(RESOURCE_SCHEME)


## true, если адрес указывает на ресурс внутри бандла приложения (vrwebresource:// -> res://).
## Такие в билде проходят через импорт Godot и физически лежат как .ctex/.remap — сырых байтов
## по res://-пути нет, поэтому их грузят через ResourceLoader, а не FileAccess/побайтово.
static func is_bundle_resource(url: String) -> bool:
	return url.begins_with(RESOURCE_SCHEME)


static func _scheme_of(url: String) -> String:
	return LOCAL_SCHEME if url.begins_with(LOCAL_SCHEME) else RESOURCE_SCHEME


## Преобразует vrweb-адрес в путь для FileAccess. "" — если адрес не локальный.
## vrweblocal://  -> абсолютный путь ОС (с гарантированным ведущим "/").
## vrwebresource:// -> RESOURCE_ROOT + относительный путь (внутри бандла).
## query (?...) и fragment (#...) к файлу не относятся — они уходят скриптам страницы.
static func to_file_path(url: String) -> String:
	if url.begins_with(LOCAL_SCHEME):
		var p := _strip_query_fragment(url.substr(LOCAL_SCHEME.length()))
		return p if p.begins_with("/") else "/" + p
	if url.begins_with(RESOURCE_SCHEME):
		var rel := _strip_query_fragment(url.substr(RESOURCE_SCHEME.length()))
		if rel.begins_with("/"):
			rel = rel.substr(1)
		return RESOURCE_ROOT + rel
	return ""


## Отрезает query (?...) и fragment (#...), оставляя только путь к файлу.
static func _strip_query_fragment(path: String) -> String:
	return path.get_slice("?", 0).get_slice("#", 0)


## Канонизирует локальный адрес: схлопывает "." и ".." в пути, сохраняя префикс схемы
## и абсолютность (ведущий "/") пути ОС.
static func _normalize_local(url: String) -> String:
	var scheme := _scheme_of(url)
	return scheme + _collapse_dots(url.substr(scheme.length()))


## Резолвит относительный url внутри локальной схемы относительно base_url.
static func _join_local(scheme: String, base_url: String, url: String) -> String:
	var base_path := base_url.substr(scheme.length())
	if url.begins_with("#"):
		return scheme + base_path.get_slice("#", 0) + url
	if url.begins_with("/"):
		return scheme + _collapse_dots(url)
	return scheme + _collapse_dots(_local_dir(base_path) + url)


## Директория пути (с хвостовым "/"), без query/fragment и имени файла.
static func _local_dir(path: String) -> String:
	path = path.get_slice("?", 0).get_slice("#", 0)
	var last_slash := path.rfind("/")
	return "" if last_slash == -1 else path.substr(0, last_slash + 1)


## Схлопывает сегменты "." и ".." в пути, сохраняя ведущий "/" если он был.
## ".." за пределы корня отбрасывается (нельзя выйти из песочницы ресурсов).
static func _collapse_dots(path: String) -> String:
	var lead := path.begins_with("/")
	var out: Array = []
	for p in path.split("/"):
		if p == "" or p == ".":
			continue
		if p == "..":
			if not out.is_empty():
				out.pop_back()
			continue
		out.append(p)
	return ("/" if lead else "") + "/".join(out)


static func _split_base(base_url: String) -> Dictionary:
	var scheme_end := base_url.find("://")
	if scheme_end == -1:
		return {"origin": "https://" + base_url, "dir": "/"}
	var after := base_url.substr(scheme_end + 3)
	var slash := after.find("/")
	var host := after if slash == -1 else after.substr(0, slash)
	var path := "/" if slash == -1 else after.substr(slash)
	# Отрезаем query/fragment и имя файла, оставляя директорию.
	path = path.get_slice("?", 0).get_slice("#", 0)
	var last_slash := path.rfind("/")
	var dir := "/" if last_slash <= 0 else path.substr(0, last_slash + 1)
	return {"origin": base_url.substr(0, scheme_end + 3) + host, "dir": dir}


static func _normalize_path(url: String) -> String:
	# Схлопываем "/./" и "/../" в пути.
	var scheme_end := url.find("://")
	if scheme_end == -1:
		return url
	var origin := url.substr(0, scheme_end + 3)
	var rest := url.substr(scheme_end + 3)
	var slash := rest.find("/")
	if slash == -1:
		return url
	var host := rest.substr(0, slash)
	var path := rest.substr(slash)
	var parts := path.split("/")
	var out: Array = []
	for p in parts:
		if p == "" or p == ".":
			continue
		if p == "..":
			if not out.is_empty():
				out.pop_back()
			continue
		out.append(p)
	return origin + host + "/" + "/".join(out)


## HTML допускает пробелы в атрибутах URL, браузер перед запросом кодирует их.
## Godot HTTPRequest ожидает уже корректный URL, поэтому делаем минимальную нормализацию здесь.
static func _escape_http_url(url: String) -> String:
	if not (url.begins_with("http://") or url.begins_with("https://")):
		return url
	return url.replace(" ", "%20")


## Канонический ключ страницы для сидирования генерации.
## Один и тот же сайт должен давать один и тот же мир, поэтому НЕ влияют на сид:
## схема (http/https), регистр хоста, хвостовой слеш пути и фрагмент (#...).
## ВЛИЯЮТ: хост, путь и query (?...) — это разные страницы.
static func seed_key(url: String) -> String:
	url = url.strip_edges()
	# Фрагмент (#anchor) — навигация внутри той же страницы, на сид не влияет.
	var hash_pos := url.find("#")
	if hash_pos != -1:
		url = url.substr(0, hash_pos)
	# Отделяем query, чтобы нормализация пути её не задела.
	var query := ""
	var q_pos := url.find("?")
	if q_pos != -1:
		query = url.substr(q_pos)
		url = url.substr(0, q_pos)
	# Убираем схему.
	var scheme_end := url.find("://")
	if scheme_end != -1:
		url = url.substr(scheme_end + 3)
	# Хост (до первого "/") — в нижний регистр; путь регистрозависим.
	var slash := url.find("/")
	if slash == -1:
		url = url.to_lower()
	else:
		url = url.substr(0, slash).to_lower() + url.substr(slash)
	# Убираем хвостовые слеши пути.
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url + query


## Глобальный сид сети knossos. Общая основа всей генерации: подмешивается в сид каждого
## пространства, так что «форма мира» у всех клиентов одна. Смена этого числа перекраивает
## ВСЕ миры сразу (namespace/версия генерации). На то, кто с кем встречается (инстанс
## мультиплеера = seed_key(url)), он не влияет — это отдельная ось.
const GLOBAL_SEED := 0x6B6E6F73  # "knos"


## Хост страницы (basepath) в нижнем регистре, без схемы/пути/query/фрагмента. Один хост —
## одна «палитра» пространств; путь и query на сид пространства НЕ влияют (в отличие от
## seed_key, который различает страницы для инстансов мультиплеера).
static func host_key(url: String) -> String:
	url = url.strip_edges()
	var hash_pos := url.find("#")
	if hash_pos != -1:
		url = url.substr(0, hash_pos)
	var q_pos := url.find("?")
	if q_pos != -1:
		url = url.substr(0, q_pos)
	var scheme_end := url.find("://")
	if scheme_end != -1:
		url = url.substr(scheme_end + 3)
	var slash := url.find("/")
	if slash != -1:
		url = url.substr(0, slash)
	return url.to_lower()


## Сид ПРОСТРАНСТВА (геометрии) = f(глобальный сид, host, подпись топологии). Топологически
## одинаковые страницы одного хоста дают идентичный мир; разная топология или другой хост —
## другой мир. См. TopologyBuilder.signature и docs/geometry-lab.md.
##   hostA + топология1 → мир A;  hostA + топология2 → мир B;  hostB + топология1 → мир C.
static func space_seed(url: String, topology_signature: String) -> int:
	return int(hash("%d|%s|%s" % [GLOBAL_SEED, host_key(url), topology_signature]))
