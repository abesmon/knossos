extends Node

## Клиент домашнего сервера (autoload «HomeServer») — «Слой 3» федеративной идентичности,
## см. docs/home-server.md. Отвечает за:
##  - discovery своего сервера (/.well-known/vrweb): features, анонс конфигурации (сигналинг);
##  - аккаунт: логин/регистрация/логаут, Bearer-токен;
##  - ключ клиента (RSA-2048 в user://identity_key.pem — приватная половина НИКОГДА не
##    покидает устройство) и сертификат идентичности, выданный сервером;
##  - проверку ЧУЖИХ сертификатов: подпись сервера над канонической строкой + кэш
##    signing_keys доменов (память + user://known_servers.cfg — работает и офлайн).
##
## Криптография — RSA-2048, подпись PKCS#1 v1.5 + SHA-256 (алгоритм "rsa-sha256" в
## signing_keys): ровно то, что умеют Crypto/CryptoKey Godot (Ed25519/SHA-512 в движке нет).
## Challenge–response с пирами делает NetworkManager, отсюда он берёт sign_challenge /
## verify_signature / certificate_payload.
##
## БЕЗОПАСНОСТЬ ключей доменов (см. docs/home-server.md → «Строгая проверка»): ключи домена
## считаются авторитетными, только если получены с КАНОНИЧЕСКОГО источника — `https://<домен>`,
## чей хост совпадает с доменом. Это не даёт домашнему серверу (даже своему, если он врёт про
## `domain`, или скомпрометированному) присвоить себе чужой домен и отравить кэш. Строгий режим —
## по умолчанию; для локальной разработки/тестов (http, self-host, домен ≠ хост) его смягчает
## insecure_identity() — тогда неканоничный источник не отклоняется, а лишь предупреждает.

## Любое изменение состояния (discovery / аккаунт / сертификат) — UI перечитывает всё.
signal state_changed
## Появился/обновился наш сертификат — NetworkManager рассылает его пирам.
signal certificate_changed
## Очередной refresh() дошёл до конца (успех или ошибка — смотреть discovery/discovery_error).
## Прерванные по поколению refresh НЕ сигналят — сигнал даст тот, кто их прервал.
## На него ждёт loading screen перед переходом в main.
signal refresh_finished

const SETTINGS_PATH := "user://homeserver.cfg"
const KEY_PATH := "user://identity_key.pem"
const KNOWN_SERVERS_PATH := "user://known_servers.cfg"

## Небезопасный режим идентичности (только для локальной разработки/тестов): снимает
## требование канонического HTTPS-источника ключей и сверку «домен == хост». Источник —
## cmdline `--insecure-identity` ИЛИ env `VRWEB_INSECURE_IDENTITY` (1/true), как у Sandbox.
## По умолчанию ВЫКЛ (строгая проверка). НИКОГДА не включать в проде.
const INSECURE_ARG := "--insecure-identity"
const INSECURE_ENV := "VRWEB_INSECURE_IDENTITY"
static var _insecure_checked := false
static var _insecure := false

## Не static (зовётся через автолоад HomeServer.insecure_identity()); кэш — в static-переменных.
func insecure_identity() -> bool:
	if not _insecure_checked:
		_insecure_checked = true
		if OS.get_cmdline_user_args().has(INSECURE_ARG) or OS.get_cmdline_args().has(INSECURE_ARG):
			_insecure = true
		else:
			var e := OS.get_environment(INSECURE_ENV).strip_edges().to_lower()
			_insecure = e == "1" or e == "true" or e == "yes"
	return _insecure

## Капабилити, которые поддерживает ЭТОТ клиент; с сервером работает пересечение
## (см. «features» в docs/home-server.md). personal-spaces.v1 — персональные
## пространства (docs/personal-spaces.md); presence.v1 — сводка «где люди»
## (docs/presence.md).
const CLIENT_FEATURES := ["identity.v1", "signaling.v1", "personal-spaces.v1", "presence.v1"]
## Единственный поддерживаемый алгоритм подписи (см. шапку).
const ALGORITHM := "rsa-sha256"
## Кэш signing_keys домена считается свежим сутки; протухший используется как fallback,
## если домен недоступен (сертификат самодостаточен — см. docs/home-server.md).
const KEYS_TTL := 86400
## За сколько секунд до истечения сертификата перезапрашиваем его при refresh (7 дней).
const CERT_RENEW_MARGIN := 7 * 86400
const HTTP_TIMEOUT := 10.0

## --- Состояние аккаунта (персистится в user://homeserver.cfg) ---
## URL сервера, которому принадлежат токен/сертификат. Смена адреса в настройках = смена
## провайдера идентичности: старые токен и сертификат сбрасываются.
var _account_url := ""
## Адрес домашнего сервера, ПРОТИВ КОТОРОГО мы последний раз запускали discovery (успешно или
## нет). Отдельно от _account_url (тот заполняется только при логине): по нему решаем, надо ли
## пере-открывать discovery при сохранении настроек. Иначе любое сохранение (ник, лицо…) у
## незалогиненного пользователя дёргало бы refresh, а тот транзиентно меняет announced_signaling_url
## и заставляет клиента зря переподключаться к сигналингу — роняя капсулу у остальных.
var _discovered_from := ""
var access_token := ""
## Полный федеративный адрес (nick@domain); "" — не залогинены.
var address := ""
## Сертификат: каноническая JSON-строка (ровно та, что подписана) + подпись (base64).
var cert_json := ""
var cert_signature := ""
var _cert: Dictionary = {}  # распарсенный cert_json (кэш)

## --- Discovery нашего сервера ---
var discovery: Dictionary = {}       # весь ответ /.well-known/vrweb ({} — не получен)
var discovery_error := ""            # текст последней ошибки discovery ("" — ок/не пробовали)
## Адрес сигналинга, анонсированный домашним сервером ("" — нет). Учитывается в
## Settings.effective_signaling_url(), если пользователь не задал свой.
var announced_signaling_url := ""
## Хотя бы один refresh() дошёл до конца (см. refresh_finished). Пока false — анонс
## сигналинга ещё «неизвестен», а не «отсутствует».
var refresh_done := false

## Идёт сетевая операция логина/регистрации/сертификации — UI блокирует кнопки.
var busy := false

var _crypto := Crypto.new()
var _key: CryptoKey = null           # наш RSA-ключ (лениво: с диска или генерация)
var _domain_keys: Dictionary = {}    # domain -> {fetched_at: int, keys: {key_id: pub_b64}, origin: url}
var _path := SETTINGS_PATH
var _key_path := KEY_PATH
var _servers_path := KNOWN_SERVERS_PATH


func _ready() -> void:
	_path = Sandbox.resolve(SETTINGS_PATH)
	_key_path = Sandbox.resolve(KEY_PATH)
	_servers_path = Sandbox.resolve(KNOWN_SERVERS_PATH)
	_load_state()
	_load_known_servers()
	if insecure_identity():
		Log.warn("home", "небезопасный режим идентичности ВКЛЮЧЁН (%s / %s). "
			% [INSECURE_ARG, INSECURE_ENV] + "Строгая проверка источника ключей отключена — "
			+ "только для локальной разработки/тестов, НЕ для прода.")
	Settings.changed.connect(_on_settings_changed)
	# Стартовый refresh: discovery + валидация токена + продление сертификата.
	refresh()


## Фактический URL нашего домашнего сервера (нормализованный; "" — не настроен).
func server_url() -> String:
	return _normalize_base(Settings.effective_home_server_url())


func is_logged_in() -> bool:
	return access_token != "" and address != ""


## Есть действующий (непросроченный) сертификат идентичности.
func has_certificate() -> bool:
	return cert_json != "" and cert_signature != "" \
		and int(_cert.get("expires_at", 0)) > int(Time.get_unix_time_from_system())


## Наш сертификат для предъявления пирам: [каноническая строка, подпись base64].
func certificate_payload() -> Array:
	return [cert_json, cert_signature] if has_certificate() else []


## Когда истекает сертификат (unix-время; 0 — сертификата нет).
func certificate_expires_at() -> int:
	return int(_cert.get("expires_at", 0))


## Поддерживают ли фичу ОБЕ стороны (пересечение наших и серверных features).
func supports(feature: String) -> bool:
	return feature in CLIENT_FEATURES \
		and feature in discovery.get("features", [])


# --- Аккаунт: логин / регистрация / логаут ---

## Логин на домашнем сервере; после успеха сразу запрашивает сертификат. Возвращает ""
## при успехе или человекочитаемую ошибку.
func login(nickname: String, password: String) -> String:
	return await _authenticate("/api/v1/login", nickname, password)


## Регистрация нового аккаунта (если сервер разрешает); дальше — как логин.
func register_account(nickname: String, password: String) -> String:
	return await _authenticate("/api/v1/register", nickname, password)


func _authenticate(endpoint: String, nickname: String, password: String) -> String:
	var base := server_url()
	if base == "":
		return "Адрес домашнего сервера не задан."
	if busy:
		return "Уже идёт операция — подождите."
	busy = true
	state_changed.emit()
	var res := await _http(HTTPClient.METHOD_POST, base + endpoint, [],
		JSON.stringify({"nickname": nickname, "password": password}))
	var err := ""
	if res.code == 200 and typeof(res.data) == TYPE_DICTIONARY:
		_account_url = base
		access_token = str(res.data.get("access_token", ""))
		address = str(res.data.get("address", ""))
		_save_state()
		# Ник по умолчанию (Guest-XXXX) заменяем на имя аккаунта — но пользовательский
		# выбор не трогаем.
		if Settings.nick.begins_with("Guest-"):
			Settings.nick = address.get_slice("@", 0)
			Settings.save()
		err = await _certify()
		if err != "":
			err = "Вошли, но сертификат не получен: " + err
	else:
		err = _err_msg(res, "Не удалось связаться с сервером.")
	busy = false
	state_changed.emit()
	return err


## Выйти: отозвать токен на сервере (best effort) и забыть аккаунт с сертификатом.
func logout() -> void:
	var base := _account_url
	var token := access_token
	_clear_account()
	state_changed.emit()
	if base != "" and token != "":
		await _http(HTTPClient.METHOD_POST, base + "/api/v1/logout",
			["Authorization: Bearer " + token], "")


## Обновить состояние: discovery сервера; если есть токен — проверить его и продлить
## сертификат (при отсутствии/скором истечении). Зовётся на старте и при смене адреса.
## Параллельные refresh (смена адреса во время запроса) — старый прерывается по поколению.
var _refresh_gen := 0

func refresh() -> void:
	_refresh_gen += 1
	var gen := _refresh_gen
	var base := server_url()
	# Фиксируем адрес попытки СРАЗУ (до await): по нему _on_settings_changed решает, что
	# discovery для этого адреса уже запускался, и не дёргает refresh на каждом сохранении.
	_discovered_from = base
	# Аккаунт привязан к конкретному серверу: адрес сменился — старая сессия не наша.
	if _account_url != "" and _account_url != base:
		_clear_account()
	discovery = {}
	discovery_error = ""
	announced_signaling_url = ""
	state_changed.emit()
	if base == "":
		refresh_done = true
		refresh_finished.emit()
		return
	var res := await _http(HTTPClient.METHOD_GET, base + "/.well-known/vrweb", [])
	if gen != _refresh_gen:
		return  # за время запроса начался новый refresh (сменили адрес) — не перетираем
	if res.code == 200 and typeof(res.data) == TYPE_DICTIONARY:
		discovery = res.data
		announced_signaling_url = str(discovery.get("config", {}).get("signaling_url", ""))
		# Ключи своего сервера — в кэш доменов (пригодятся для проверки соседей), НО только как
		# авторитетные для домена, который сервер про себя заявил, если этот домен канонично
		# совпадает с хостом, куда мы реально ходили. Иначе сервер присваивает себе чужой домен
		# (или врёт про свой) — в строгом режиме не кэшируем. См. шапку и docs/home-server.md.
		var domain := str(discovery.get("server", {}).get("domain", ""))
		if domain != "" and _accept_key_origin(base, domain, "домашний сервер"):
			_cache_domain_keys(domain, discovery.get("signing_keys", []), base)
	else:
		discovery_error = _err_msg(res, "Сервер недоступен.")
	if access_token != "":
		var acc := await _http(HTTPClient.METHOD_GET, _account_url + "/api/v1/account",
			["Authorization: Bearer " + access_token], "")
		if gen != _refresh_gen:
			return
		if acc.code == 401:
			# Токен истёк/отозван — мы разлогинены (сертификат остаётся: он самодостаточен).
			access_token = ""
			_save_state()
		elif acc.code == 200 and is_logged_in() and not has_certificate():
			await _certify()
		elif acc.code == 200 and is_logged_in() \
				and certificate_expires_at() - int(Time.get_unix_time_from_system()) < CERT_RENEW_MARGIN:
			await _certify()
	refresh_done = true
	refresh_finished.emit()
	state_changed.emit()


func _clear_account() -> void:
	_account_url = ""
	access_token = ""
	address = ""
	cert_json = ""
	cert_signature = ""
	_cert = {}
	_save_state()
	certificate_changed.emit()


# --- Персональное пространство (personal-spaces.v1, docs/personal-spaces.md) ---

## Актуальный адрес СВОЕГО пространства с домашнего сервера. Клиент URL не хранит —
## спрашивает каждый раз: так «кнопка домой» переживает ротацию адреса незаметно.
## Возвращает { ok, url, name, error }.
func fetch_home_space() -> Dictionary:
	if not is_logged_in():
		return {"ok": false, "url": "", "name": "", "error": "Не залогинены на домашнем сервере."}
	if not supports("personal-spaces.v1"):
		return {"ok": false, "url": "", "name": "", "error": "Сервер не поддерживает персональные пространства."}
	var res := await _http(HTTPClient.METHOD_GET, _account_url + "/api/v1/spaces/home",
		["Authorization: Bearer " + access_token], "")
	if res.code == 200 and typeof(res.data) == TYPE_DICTIONARY:
		return {"ok": true, "url": str(res.data.get("url", "")),
			"name": str(res.data.get("name", "")), "error": ""}
	return {"ok": false, "url": "", "name": "", "error": _err_msg(res, "Сервер не ответил.")}


# --- Presence «где люди» (presence.v1, docs/presence.md) ---

## Сводка занятых страниц с домашнего сервера: { ok, rooms, total, error }, где rooms —
## [{url, count, tags}] по убыванию людности (url — канонический ключ страницы, без схемы —
## навигация подставит https), total — размер выдачи ДО пагинации (rooms.size() < total —
## выдача обрезана). Аргументы (все опциональны):
##   url    — точечный запрос «сколько людей на этой странице?» (выдача только по ней);
##   limit  — не больше N записей (<= 0 — без ограничения);
##   offset — пропустить первые N (страницы режутся по живым данным — между запросами
##            выдача может сдвинуться).
## Контракт не обещает ни точных count, ни полной картины — только то, что видно этому
## серверу (docs/presence.md). Логин не обязателен: публичный сервер отвечает и анониму;
## когда залогинены на этом же сервере — шлём Bearer (сервер с access=authenticated
## иначе ответит 401, а персонализированная выдача — на его усмотрение).
func fetch_presence(url := "", limit := 0, offset := 0) -> Dictionary:
	var base := server_url()
	if base == "":
		return {"ok": false, "rooms": [], "total": 0, "error": "Адрес домашнего сервера не задан."}
	if not supports("presence.v1"):
		return {"ok": false, "rooms": [], "total": 0, "error": "Сервер не поддерживает presence."}
	var params := PackedStringArray()
	if url != "":
		params.append("url=" + url.uri_encode())
	if limit > 0:
		params.append("limit=%d" % limit)
	if offset > 0:
		params.append("offset=%d" % offset)
	var endpoint := base + "/api/v1/presence"
	if not params.is_empty():
		endpoint += "?" + "&".join(params)
	var headers := PackedStringArray()
	var auth := auth_header_for(base)
	if auth != "":
		headers.append(auth)
	var res := await _http(HTTPClient.METHOD_GET, endpoint, headers)
	if res.code == 200 and typeof(res.data) == TYPE_DICTIONARY \
			and typeof(res.data.get("rooms")) == TYPE_ARRAY:
		var rooms: Array = res.data["rooms"]
		return {"ok": true, "rooms": rooms, "total": int(res.data.get("total", rooms.size())), "error": ""}
	return {"ok": false, "rooms": [], "total": 0, "error": _err_msg(res, "Сервер не ответил.")}


## Заголовок Authorization для запроса к URL — только если это НАШ домашний сервер
## (хост совпадает) и мы залогинены; иначе "". Так владелец входит в свой закрытый дом:
## presence-gate пространств пускает по Bearer (см. docs/personal-spaces.md).
func auth_header_for(url: String) -> String:
	if not is_logged_in() or _account_url == "" or _host_of(url) != _host_of(_account_url):
		return ""
	return "Authorization: Bearer " + access_token


## Подписанные заголовки identity для защищённого GET внешнего ресурса. Сертификат публичен,
## но proof подтверждает владение его приватным ключом и привязан к точному URL. Timestamp и
## nonce дают серверу обычную anti-replay проверку с коротким окном.
const DATA_REQUEST_PROOF_PREFIX := "vrweb-data-request.v1"


func data_identity_headers_for(url: String) -> PackedStringArray:
	if not has_certificate() or not url.begins_with("https://") \
			or url.contains("\r") or url.contains("\n"):
		return PackedStringArray()
	var timestamp := int(Time.get_unix_time_from_system())
	var nonce := Marshalls.raw_to_base64(Crypto.new().generate_random_bytes(16))
	var payload := data_request_proof_payload("GET", url, timestamp, nonce)
	var proof := sign_challenge(payload.to_utf8_buffer())
	if proof.is_empty():
		return PackedStringArray()
	return PackedStringArray([
		"X-VRWeb-Identity-Certificate: " + Marshalls.raw_to_base64(cert_json.to_utf8_buffer()),
		"X-VRWeb-Identity-Certificate-Signature: " + cert_signature,
		"X-VRWeb-Identity-Timestamp: " + str(timestamp),
		"X-VRWeb-Identity-Nonce: " + nonce,
		"X-VRWeb-Identity-Proof: " + Marshalls.raw_to_base64(proof),
	])


static func data_request_proof_payload(method: String, url: String, timestamp: int,
		nonce: String) -> String:
	return "%s\n%s\n%s\n%d\n%s" % [DATA_REQUEST_PROOF_PREFIX, method, url, timestamp, nonce]


## access_token для join сигналинга — только когда сигналинг живёт на нашем же домашнем
## сервере (монолит): токен привязывает WS-сессию к аккаунту, по ней сервер видит
## «хозяин дома» (presence-gate). Чужому сигналингу токен не показываем.
func signaling_token() -> String:
	if not is_logged_in() or _account_url == "" \
			or _host_of(Settings.effective_signaling_url()) != _host_of(_account_url):
		return ""
	return access_token


## Префикс подписи флаша персистенции (см. docs/page-persistence.md).
const FLUSH_PROOF_PREFIX := "vrweb-flush.v1:"

## Подписать payload флаша нашим ключом идентичности (base64; "" — ключа нет).
func sign_flush_payload(payload: String) -> String:
	var sig := sign_challenge((FLUSH_PROOF_PREFIX + payload).to_utf8_buffer())
	return Marshalls.raw_to_base64(sig) if not sig.is_empty() else ""


# --- Сертификат ---

## Запросить у сервера сертификат на наш публичный ключ. Возвращает "" или ошибку.
func _certify() -> String:
	if not is_logged_in():
		return "Не залогинены."
	if not await _ensure_key():
		return "Не удалось создать ключ клиента."
	var res := await _http(HTTPClient.METHOD_POST, _account_url + "/api/v1/identity/certify",
		["Authorization: Bearer " + access_token],
		JSON.stringify({"public_key": _public_key_b64()}))
	if res.code != 200 or typeof(res.data) != TYPE_DICTIONARY:
		return _err_msg(res, "Сервер не выдал сертификат.")
	var cj := str(res.data.get("certificate_json", ""))
	var sig := str(res.data.get("signature", ""))
	var parsed = JSON.parse_string(cj)
	if cj == "" or sig == "" or typeof(parsed) != TYPE_DICTIONARY:
		return "Некорректный ответ сервера (нет certificate_json)."
	cert_json = cj
	cert_signature = sig
	_cert = parsed
	_save_state()
	certificate_changed.emit()
	state_changed.emit()
	return ""


## Наш RSA-ключ: с диска или генерация (в отдельном потоке — RSA-2048 занимает секунды).
func _ensure_key() -> bool:
	if _key != null:
		return true
	if FileAccess.file_exists(_key_path):
		var loaded := CryptoKey.new()
		if loaded.load(_key_path) == OK:
			_key = loaded
			return true
		Log.warn("home", "%s не читается — генерирую новый ключ" % _key_path)
	var thread := Thread.new()
	thread.start(func(): return Crypto.new().generate_rsa(2048))
	while thread.is_alive():
		await get_tree().process_frame
	_key = thread.wait_to_finish()
	if _key == null:
		return false
	_key.save(_key_path)
	return true


## Публичная половина нашего ключа в формате сервера: base64(DER SubjectPublicKeyInfo).
func _public_key_b64() -> String:
	return _pem_body(_key.save_to_string(true))


# --- Криптография (общая с проверкой чужих сертификатов) ---

## Подписать челлендж пира нашим приватным ключом (см. NetworkManager). Пустой массив —
## ключа нет (аноним) или подпись не удалась.
func sign_challenge(payload: PackedByteArray) -> PackedByteArray:
	if _key == null and FileAccess.file_exists(_key_path):
		var loaded := CryptoKey.new()
		if loaded.load(_key_path) == OK:
			_key = loaded
	if _key == null:
		return PackedByteArray()
	return _crypto.sign(HashingContext.HASH_SHA256, _sha256(payload), _key)


## Проверить подпись RSA-SHA256 по публичному ключу base64(DER SPKI).
func verify_signature(public_key_b64: String, data: PackedByteArray, signature: PackedByteArray) -> bool:
	if public_key_b64 == "" or signature.is_empty():
		return false
	var key := CryptoKey.new()
	if key.load_from_string(_b64_to_pem(public_key_b64), true) != OK:
		return false
	return _crypto.verify(HashingContext.HASH_SHA256, _sha256(data), signature, key)


## Проверка ЧУЖОГО сертификата — «шаг 1» из docs/home-server.md: подпись сервера домена
## над канонической строкой. Возвращает словарь:
##   { ok: bool, error: String, address: String, public_key: String, expires_at: int }
## public_key — ключ пира из сертификата: им NetworkManager проверяет челлендж («шаг 2»).
func verify_peer_certificate(peer_cert_json: String, signature_b64: String) -> Dictionary:
	var fail := func(err: String) -> Dictionary:
		return {"ok": false, "error": err, "address": "", "public_key": "", "expires_at": 0}
	if peer_cert_json.length() > 8192 or signature_b64.length() > 4096:
		return fail.call("Сертификат подозрительно велик.")
	var parsed = JSON.parse_string(peer_cert_json)
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("v", 0)) != 1:
		return fail.call("Не сертификат (v != 1).")
	var expires := int(parsed.get("expires_at", 0))
	if expires <= int(Time.get_unix_time_from_system()):
		return fail.call("Сертификат истёк.")
	var peer_address := str(parsed.get("address", ""))
	var domain := peer_address.get_slice("@", 1)
	if not peer_address.contains("@") or domain == "" or peer_address.get_slice("@", 0) == "":
		return fail.call("Некорректный адрес в сертификате.")
	var keys: Dictionary = await _signing_keys_for(domain)
	var key_id := str(parsed.get("key_id", ""))
	if not keys.has(key_id):
		return fail.call("Ключ %s домена %s недоступен." % [key_id, domain])
	if not verify_signature(str(keys[key_id]), peer_cert_json.to_utf8_buffer(),
			Marshalls.base64_to_raw(signature_b64)):
		return fail.call("Подпись сервера не сходится.")
	return {"ok": true, "error": "", "address": peer_address,
		"public_key": str(parsed.get("public_key", "")), "expires_at": expires}


## signing_keys домена: свежий кэш → сеть → протухший кэш (лучше, чем ничего: сервер
## пира может быть временно недоступен, а сертификат самодостаточен). Кэш и сетевой ответ
## принимаются, только если их источник канонический для домена (строгий режим) — иначе
## отравленный/downgrade-источник не подставится под проверку. См. шапку.
func _signing_keys_for(domain: String) -> Dictionary:
	var entry: Dictionary = _domain_keys.get(domain, {})
	var now := int(Time.get_unix_time_from_system())
	# Свежий кэш используем, только если его источник канонический (в insecure — любой). Так
	# запись, отравленная в insecure-сессии, не «переживает» до истечения TTL в строгом режиме.
	if not entry.is_empty() and now - int(entry.get("fetched_at", 0)) < KEYS_TTL \
			and (insecure_identity() or _origin_is_canonical(str(entry.get("origin", "")), domain)):
		return entry.get("keys", {})
	var url := _well_known_url(domain)
	if not _accept_key_origin(url, domain, "домен сертификата"):
		return entry.get("keys", {}) if insecure_identity() else {}
	var res := await _http(HTTPClient.METHOD_GET, url, [])
	if res.code == 200 and typeof(res.data) == TYPE_DICTIONARY:
		return _cache_domain_keys(domain, res.data.get("signing_keys", []), url)
	return entry.get("keys", {})


## Запомнить signing_keys домена (память + диск) вместе с origin (откуда взяты — для проверки
## каноничности при чтении кэша). Возвращает {key_id: pub_b64}.
func _cache_domain_keys(domain: String, signing_keys: Variant, origin: String) -> Dictionary:
	var keys := {}
	if typeof(signing_keys) == TYPE_ARRAY:
		for k in signing_keys:
			if typeof(k) == TYPE_DICTIONARY and str(k.get("algorithm", "")) == ALGORITHM:
				var kid := str(k.get("key_id", ""))
				if kid != "":
					keys[kid] = str(k.get("public_key", ""))
	_domain_keys[domain] = {"fetched_at": int(Time.get_unix_time_from_system()), "keys": keys, "origin": origin}
	_save_known_servers()
	return keys


## URL discovery для домена. Федерация ходит по https://<домен>; исключение — наш собственный
## сервер по тому же хосту: для него берём наш base URL как есть (локальная разработка по http
## работает только в insecure-режиме — строгий отклонит не-https источник).
func _well_known_url(domain: String) -> String:
	var base := server_url()
	if base != "" and _host_of(base) == domain:
		return base + "/.well-known/vrweb"
	return "https://" + domain + "/.well-known/vrweb"


## Канонический ли источник `url` для ключей `domain`: только https и хост == домен. Это
## единственный источник, которому мы верим как авторитетному в строгом режиме.
static func _origin_is_canonical(url: String, domain: String) -> bool:
	return url.begins_with("https://") and _host_of(url) == domain


## Принять ли ключи домена из источника `url`. Канонический — да, молча. Неканонический —
## в insecure-режиме да, но с мягким предупреждением («подозрительно»); в строгом — нет.
## what — что за источник (для текста предупреждения). Общий гейт для discovery и проверки пиров.
func _accept_key_origin(url: String, domain: String, what: String) -> bool:
	if _origin_is_canonical(url, domain):
		return true
	if insecure_identity():
		Log.warn("home", "%s заявляет домен «%s», но ключи взяты из неканоничного "
			% [what, domain] + "источника %s (не https://%s). Подозрительно; принято только "
			% [url, domain] + "из-за insecure-режима — в проде было бы отклонено.")
		return true
	Log.warn("home", "%s заявляет домен «%s», но ключи доступны только с https://%s "
		% [what, domain, domain] + "(строгий режим). Источник %s отклонён. Для локалки: %s / %s=1."
		% [url, INSECURE_ARG, INSECURE_ENV])
	return false


# --- Реакция на настройки ---

func _on_settings_changed() -> void:
	# Пере-открываем discovery ТОЛЬКО при смене адреса домашнего сервера. Прочие сохранения
	# (ник, лицо, аватар, громкость…) сети не касаются — иначе refresh транзиентно сбрасывает
	# announced_signaling_url, эффективный адрес сигналинга «скачет», и клиент зря
	# переподключается, роняя свою капсулу у остальных. discovery уже отработал на старте и
	# при последней смене адреса (см. _discovered_from). Неудавшийся discovery повторяется на
	# следующем запуске или при новой смене адреса, а не на каждом сохранении.
	if server_url() != _discovered_from:
		refresh()


# --- Персистентность ---

func _load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_path) != OK:
		return
	_account_url = cfg.get_value("account", "server_url", "")
	access_token = cfg.get_value("account", "token", "")
	address = cfg.get_value("account", "address", "")
	cert_json = cfg.get_value("certificate", "json", "")
	cert_signature = cfg.get_value("certificate", "signature", "")
	var parsed = JSON.parse_string(cert_json) if cert_json != "" else null
	_cert = parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("account", "server_url", _account_url)
	cfg.set_value("account", "token", access_token)
	cfg.set_value("account", "address", address)
	cfg.set_value("certificate", "json", cert_json)
	cfg.set_value("certificate", "signature", cert_signature)
	cfg.save(_path)


func _load_known_servers() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_servers_path) != OK:
		return
	for domain in cfg.get_sections():
		_domain_keys[domain] = {
			"fetched_at": int(cfg.get_value(domain, "fetched_at", 0)),
			"keys": cfg.get_value(domain, "keys", {}),
			# origin отсутствует у старых записей → "" (неканоничный) → строгий режим их не
			# использует и перезапросит канонично. Безопасный дефолт при апгрейде.
			"origin": str(cfg.get_value(domain, "origin", "")),
		}


func _save_known_servers() -> void:
	var cfg := ConfigFile.new()
	for domain in _domain_keys:
		cfg.set_value(domain, "fetched_at", _domain_keys[domain]["fetched_at"])
		cfg.set_value(domain, "keys", _domain_keys[domain]["keys"])
		cfg.set_value(domain, "origin", _domain_keys[domain].get("origin", ""))
	cfg.save(_servers_path)


# --- Вспомогательное ---

## Один HTTP-запрос через временный HTTPRequest. Возвращает
## { result: int, code: int, data: Variant } (data — распарсенный JSON или null).
func _http(method: int, url: String, extra_headers: PackedStringArray, body := "") -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = HTTP_TIMEOUT
	add_child(req)
	var headers := PackedStringArray(["Accept: application/json"])
	if body != "":
		headers.append("Content-Type: application/json")
	headers.append_array(extra_headers)
	if req.request(url, headers, method, body) != OK:
		req.queue_free()
		return {"result": HTTPRequest.RESULT_CANT_CONNECT, "code": 0, "data": null}
	var res: Array = await req.request_completed
	req.queue_free()
	# Пустое тело (сервер недоступен и т.п.) не гоняем через парсер — он пушит ошибку в лог.
	var body_str := (res[3] as PackedByteArray).get_string_from_utf8()
	var data = JSON.parse_string(body_str) if body_str.strip_edges() != "" else null
	return {"result": int(res[0]), "code": int(res[1]), "data": data}


## Ошибка запроса для UI: message из {"error": ...} сервера или fallback.
static func _err_msg(res: Dictionary, fallback: String) -> String:
	if typeof(res.data) == TYPE_DICTIONARY and typeof(res.data.get("error")) == TYPE_DICTIONARY:
		var msg := str(res.data["error"].get("message", ""))
		if msg != "":
			return msg
	if int(res.code) != 0:
		return fallback + " (HTTP %d)" % int(res.code)
	return fallback


## Нормализует базовый URL сервера: без хвостового "/", со схемой (дефолт — https).
static func _normalize_base(url: String) -> String:
	url = url.strip_edges().rstrip("/")
	if url == "":
		return ""
	if not url.contains("://"):
		url = "https://" + url
	return url


## Хост (с портом) из URL: "https://a.b:8080/x" -> "a.b:8080".
static func _host_of(url: String) -> String:
	var rest := url.get_slice("://", 1)
	return rest.get_slice("/", 0)


static func _sha256(data: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(data)
	return h.finish()


## Тело PEM (base64 DER без армирования) — формат public_key на сервере.
static func _pem_body(pem: String) -> String:
	var out := ""
	for line in pem.split("\n"):
		var t := line.strip_edges()
		if t != "" and not t.begins_with("-----"):
			out += t
	return out


## base64 DER (SPKI) -> публичный PEM для CryptoKey.load_from_string.
static func _b64_to_pem(b64: String) -> String:
	var body := ""
	var i := 0
	while i < b64.length():
		body += b64.substr(i, 64) + "\n"
		i += 64
	return "-----BEGIN PUBLIC KEY-----\n" + body + "-----END PUBLIC KEY-----\n"
