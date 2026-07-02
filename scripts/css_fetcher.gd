class_name CssFetcher
extends Node

## Загрузка внешних таблиц стилей для мини-каскада (docs/css-cascade.md). Пул HTTPRequest
## с кэшем по URL — по образцу ImageLoader, но живёт ПОСТОЯННО (не внутри мира): стили
## нужны ДО сборки мира, а кэш переживает навигацию — переходы по одному сайту не качают
## таблицы заново. @import разворачивается на месте (глубина <= IMPORT_DEPTH), так что
## наружу уходит уже плоский текст.
##
## Сбои — не ошибка пайплайна: по дедлайну fetch_all отдаёт то, что успело прийти
## (недоступные таблицы -> ""), мир строится с частичными стилями.

const MAX_CONCURRENT := 4
const REQUEST_TIMEOUT := 4.0      # сек на один запрос
const MAX_BODY_BYTES := 1_500_000 # тело больше — обрезается лимитом HTTPRequest
const IMPORT_DEPTH := 2
const CACHE_CAP_BYTES := 8_000_000
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"

var _cache: Dictionary = {}   # url -> String (текст со свёрнутыми @import; "" = не удалось)
var _cache_bytes := 0
var _waiters: Dictionary = {} # url -> Array[Callable], ждут текст
var _queue: Array = []        # [{url, depth, chain}]
var _active := 0

# Текущий fetch_all. Поколение отсекает поздние завершения после новой навигации:
# старый on_done не зовётся, но пришедшие тексты оседают в кэше.
var _generation := 0
var _top_results: Dictionary = {}
var _top_pending := 0
var _on_done := Callable()


## Качает все hrefs (абсолютные URL) параллельно; on_done(css_by_url) зовётся, когда всё
## пришло ИЛИ по дедлайну — что раньше. Недоступные URL в результате отсутствуют/пустые.
## Может завершиться синхронно (всё в кэше/локальное).
func fetch_all(hrefs: Array, deadline_sec: float, on_done: Callable) -> void:
	_generation += 1
	var gen := _generation
	_top_results = {}
	_on_done = on_done
	var uniq := {}
	for h in hrefs:
		if String(h) != "":
			uniq[String(h)] = true
	_top_pending = uniq.size()
	if _top_pending == 0:
		_finalize(gen)
		return
	for url in uniq:
		_fetch_sheet(url, 0, [url],
				func(text: String): _on_top_done(gen, url, text))
	if _on_done.is_valid() and gen == _generation:
		get_tree().create_timer(deadline_sec).timeout.connect(
				func(): _finalize(gen))


func _on_top_done(gen: int, url: String, text: String) -> void:
	if gen != _generation:
		return
	_top_results[url] = text
	_top_pending -= 1
	if _top_pending <= 0:
		_finalize(gen)


func _finalize(gen: int) -> void:
	if gen != _generation or not _on_done.is_valid():
		return
	var cb := _on_done
	_on_done = Callable()
	cb.call(_top_results)


## Один лист (с разворачиванием его @import). chain — цепочка предков для защиты от
## циклов импорта (a.css -> b.css -> a.css).
func _fetch_sheet(url: String, depth: int, chain: Array, cb: Callable) -> void:
	if _cache.has(url):
		cb.call(_cache[url])
		return
	if _waiters.has(url):
		(_waiters[url] as Array).append(cb)
		return
	_waiters[url] = [cb]
	_queue.append({"url": url, "depth": depth, "chain": chain})
	_pump()


func _pump() -> void:
	while _active < MAX_CONCURRENT and not _queue.is_empty():
		_start(_queue.pop_front())


func _start(item: Dictionary) -> void:
	_active += 1
	var url: String = item["url"]
	# Локальные схемы (vrweblocal/vrwebresource) — чтение без сети; текст лёгкий,
	# синхронно допустимо.
	if PageFetcher.is_local(url):
		var text := ""
		var path := PageFetcher.to_file_path(url)
		if path != "" and FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			if f != null:
				text = f.get_as_text()
		_got_body(item, text)
		return
	var http := HTTPRequest.new()
	http.use_threads = true
	http.accept_gzip = true
	http.timeout = REQUEST_TIMEOUT
	http.body_size_limit = MAX_BODY_BYTES
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
			http.queue_free()
			var ok := result == HTTPRequest.RESULT_SUCCESS and code < 400
			_got_body(item, body.get_string_from_utf8() if ok else ""))
	var err := http.request(url, ["User-Agent: " + USER_AGENT, "Accept: text/css,*/*;q=0.1"])
	if err != OK:
		http.queue_free()
		_got_body(item, "")


## Тело пришло: сетевой слот свободен сразу (ожидание дочерних @import слот не держит,
## иначе родители, ждущие детей, выели бы весь пул — дедлок).
func _got_body(item: Dictionary, raw: String) -> void:
	_active -= 1
	_pump()
	var url: String = item["url"]
	var depth: int = item["depth"]
	var text := CssParser.strip_comments(raw)
	if text == "" or depth >= IMPORT_DEPTH:
		_deliver(url, text)
		return
	var imports := CssParser.extract_imports(text)
	if imports.is_empty():
		_deliver(url, text)
		return
	var need: Array = []
	for imp in imports:
		var abs_url := PageFetcher.resolve_url(imp["href"], url)
		imp["abs"] = abs_url
		# use — подставлять ли текст: один URL может импортироваться дважды с разными
		# media (screen и print) — сплайс различает их по этому флагу, а не по URL.
		imp["use"] = abs_url != "" and CssParser.media_matches(imp["media"]) \
				and not (item["chain"] as Array).has(abs_url)
		if imp["use"]:
			need.append(imp)
	if need.is_empty():
		_deliver(url, _splice(text, imports, {}))
		return
	var waiting := {"count": need.size(), "texts": {}}
	for imp in need:
		var abs_url: String = imp["abs"]
		var child_chain: Array = (item["chain"] as Array).duplicate()
		child_chain.append(abs_url)
		_fetch_sheet(abs_url, depth + 1, child_chain,
			func(child_text: String):
				(waiting["texts"] as Dictionary)[abs_url] = child_text
				waiting["count"] -= 1
				if waiting["count"] <= 0:
					_deliver(url, _splice(text, imports, waiting["texts"])))


## Сплайс дочерних текстов на место @import-стейтментов (справа налево, чтобы позиции
## не поплыли). Импорты без текста (не совпал media / цикл / сбой) заменяются пустым.
static func _splice(text: String, imports: Array, texts: Dictionary) -> String:
	for i in range(imports.size() - 1, -1, -1):
		var imp: Dictionary = imports[i]
		var repl := ""
		if imp.get("use", false):
			repl = texts.get(imp.get("abs", ""), "")
		text = text.substr(0, imp["start"]) + repl + text.substr(imp["end"])
	return text


func _deliver(url: String, text: String) -> void:
	_cache[url] = text
	_cache_bytes += text.length()
	if _cache_bytes > CACHE_CAP_BYTES:
		# Грубый сброс: кэш — оптимизация same-site навигаций, не хранилище.
		_cache = {url: text}
		_cache_bytes = text.length()
	var ws: Array = _waiters.get(url, [])
	_waiters.erase(url)
	for cb in ws:
		(cb as Callable).call(text)
