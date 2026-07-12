extends Node

## Глобальные настройки приложения (autoload «Settings»).
## Хранит онлайн-режим, адрес сигнального сервера, ник и текстуру «лица»; персистит в
## user://. Экран настроек (scenes/settings) редактирует значения и зовёт save();
## NetworkManager и main слушают сигнал changed.

signal changed

const PATH := "user://settings.cfg"
## Лицо аватара. Всегда храним в user:// как 256×256 PNG (с альфой) — это и отдаётся по
## сети другим игрокам. При первом запуске копируем сюда дефолт.
const FACE_PATH := "user://face.png"
const DEFAULT_FACE := "res://resources/default_face.png"
const FACE_SIZE := 256
## Идентификатор аватара по умолчанию — первый из бандл-пака. Передаётся другим игрокам в
## карточке идентичности; они резолвят его через AvatarResolver. Схемы: vrwebavatar://N
## (пак приложения) или http(s)://…tscn (внешний). См. actors/avatar/avatar_resolver.gd.
const DEFAULT_AVATAR_URI := "vrwebavatar://1"

## Звуковые шины с отдельными ползунками громкости (см. default_bus_layout.tres, docs/audio.md).
## Master — общий, World — звуки мира/страниц (видео, <audio>), Voice — голос пиров.
const AUDIO_BUSES := ["Master", "World", "Voice"]

## Онлайн по умолчанию. В настройках переключатель инвертирован — это «Оффлайн-режим»
## (включён → online_enabled = false, соединения нет). Персистим инвертированный ключ
## offline_enabled, чтобы «нет настройки» = онлайн.
var online_enabled: bool = true
## Режим микрофона. Микрофон захватывается всегда (когда онлайн), а в сеть звук уходит по политике
## режима — см. VoiceManager:
##   VOICE_MODE_PTT — push-to-talk: голос идёт, только пока зажата клавиша V;
##   VOICE_MODE_VAD — voice-activated: голос идёт по детектору речи (VAD), пока не заглушено (V — mute).
## По умолчанию PTT.
const VOICE_MODE_PTT := "ptt"
const VOICE_MODE_VAD := "vad"
var voice_mode: String = VOICE_MODE_PTT
## Имя входного аудиоустройства (как в AudioServer.get_input_device_list()). "Default" —
## следовать системному выбору. Явный выбор помогает обойти кривые маршруты (например,
## Bluetooth-микрофон в HFP-режиме на macOS — см. docs/voice-chat.md).
var input_device: String = "Default"
## Усиление микрофона (линейный множитель). 1.0 — без изменений, <1 тише, >1 громче. Применяется
## до VAD и кодирования — см. VoiceManager._downmix.
var mic_gain: float = 1.0
## Порог активации голоса (RMS открытия VAD). Выше — нужно говорить громче, чтобы началась
## передача. Порог закрытия VoiceManager держит вдвое ниже (гистерезис). См. VoiceManager.
var vad_threshold: float = 0.04
## Шумоподавление микрофона (RNNoise в twovoip) на передаче. Требует OPUS_RATE 48 кГц (см.
## VoiceCodec). Применяется через VoiceManager.set_denoise; отключаемо в настройках звука.
var voice_denoise: bool = true
## Имя выходного аудиоустройства (как в AudioServer.get_output_device_list()). "Default" —
## следовать системному выбору. ВНИМАНИЕ: на macOS смена выхода в рантайме не переключает
## конфигурацию входа для голоса — см. ограничение Bluetooth в docs/voice-chat.md.
var output_device: String = "Default"
## Громкости шин, линейные [0..1]. Имя шины → множитель. Применяются к AudioServer в apply_audio().
var bus_volumes := {"Master": 1.0, "World": 1.0, "Voice": 1.0}
## Адрес сигнального сервера, ЯВНО заданный пользователем в настройках. Пусто — авторежим:
## берём адрес, анонсированный домашним сервером (HomeServer.announced_signaling_url), а без
## него — дефолт из приватного конфига сборки. Резолвит effective_signaling_url().
var signaling_url: String = ""
## Адрес домашнего сервера (идентичность, см. HomeServer и docs/home-server.md), ЯВНО заданный
## пользователем. Пусто — дефолт из конфига сборки (BuildConfig.home_server_url); резолвит
## effective_home_server_url().
var home_server_url: String = ""
## Домашняя страница: адрес, который грузится автоматически при запуске (см. main._ready).
## Пусто — без автозагрузки: стартуем на пустом экране с фокусом в адресной строке.
var home_page: String = ""
## Угол обзора камеры игрока (вертикальный FOV, градусы). 75 — дефолт Camera3D в Godot.
## Применяется в Player._ready() и по Settings.changed (см. docs/settings.md).
const FOV_MIN := 30.0
const FOV_MAX := 120.0
const DEFAULT_FOV := 75.0
var fov: float = DEFAULT_FOV
var nick: String = ""
var avatar_uri: String = DEFAULT_AVATAR_URI
## Постоянный идентификатор этого пользователя (UUID-подобная hex-строка), генерится один раз
## и персистится в user://. Стабилен между перезапусками и переходами по страницам — служит
## ключом таблицы рангов (см. NetworkManager.set_rank, docs/ranks.md), чтобы ранг переживал
## перезаход (в отличие от эфемерного peer_id). ВНИМАНИЕ: это самозаявленный id БЕЗ подписи —
## его можно подделать (скопировать чужой). Осознанный временный компромисс: настоящая
## проверка идентичности появится позже через центры авторизации. Подробно — в docs/ranks.md.
var user_id: String = ""

## Политика исполнения page scripts. ask — безопасный default: неизвестный exact hash требует
## preflight; allow_all/block_all — явные глобальные режимы. Постоянные решения привязаны к
## origin страницы + id модуля + hash, поэтому обновившийся код не наследует старое доверие.
const SCRIPT_POLICY_ASK := "ask"
const SCRIPT_POLICY_ALLOW_ALL := "allow_all"
const SCRIPT_POLICY_BLOCK_ALL := "block_all"
var page_script_policy: String = SCRIPT_POLICY_ASK
## key -> {decision, origin, module_id, resource_url, hash, updated_at}; decision allow|block.
var page_script_rules: Dictionary = {}

## Фактические пути с учётом dev-песочницы (Sandbox): без --sandbox равны константам, с ним —
## уходят под user://<id>/. Резолвим один раз в _ready.
var _path := PATH
var _face_path := FACE_PATH


func _ready() -> void:
	_path = Sandbox.resolve(PATH)
	_face_path = Sandbox.resolve(FACE_PATH)
	load_settings()
	if nick.strip_edges() == "":
		nick = random_nick()
	if user_id.strip_edges() == "":
		# Первый запуск (или апгрейд без id) — генерим постоянный id и сразу персистим.
		user_id = _new_user_id()
		save()
	_ensure_face()
	apply_audio()


## Случайный постоянный id пользователя: 16 криптослучайных байт в hex. Crypto — core-класс,
## доступен и без webrtc-аддона (офлайн).
static func _new_user_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


## Переиздать user_id: сгенерировать новый и сразу персистить (точечно — только секцию
## identity, не трогая прочие настройки и не эмитя changed). Старые выданные нам ранги
## привязаны к прежнему id и будут потеряны — см. docs/ranks.md. Возвращает новый id.
func regenerate_user_id() -> String:
	user_id = _new_user_id()
	var cfg := ConfigFile.new()
	cfg.load(_path)  # сохраняем уже записанные значения; отсутствие файла не критично
	cfg.set_value("identity", "user_id", user_id)
	cfg.save(_path)
	return user_id


## Применяет аудионастройки к AudioServer: выходное устройство и громкости шин. Зовётся на
## старте и при сохранении настроек; экран настроек ещё дёргает её при движении ползунков
## (живой отклик). Громкость 0 → шина в mute (linear_to_db(0) дал бы -inf).
func apply_audio() -> void:
	AudioServer.output_device = output_device if output_device != "" else "Default"
	for bus_name in AUDIO_BUSES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			continue
		var v := float(bus_volumes.get(bus_name, 1.0))
		AudioServer.set_bus_mute(idx, v <= 0.0)
		if v > 0.0:
			AudioServer.set_bus_volume_db(idx, linear_to_db(v))


## Фактический адрес сигналинга: явный пользовательский > анонс домашнего сервера > дефолт
## сборки. Пусто — онлайн фактически недоступен.
func effective_signaling_url() -> String:
	if signaling_url.strip_edges() != "":
		return signaling_url.strip_edges()
	if HomeServer.announced_signaling_url != "":
		return HomeServer.announced_signaling_url
	return BuildConfig.signaling_url


## Фактический адрес домашнего сервера: явный пользовательский > дефолт сборки.
## Пусто — домашний сервер не настроен (аноним без сертификата).
func effective_home_server_url() -> String:
	if home_server_url.strip_edges() != "":
		return home_server_url.strip_edges()
	return BuildConfig.home_server_url


## Случайный ник по умолчанию (когда поле ника очищено).
func random_nick() -> String:
	return "Guest-%04d" % (randi() % 10000)


## Гарантирует, что user://face.png существует — при первом запуске кладёт дефолт.
func _ensure_face() -> void:
	if FileAccess.file_exists(_face_path):
		return
	reset_face()


## Сбрасывает лицо к дефолту (resources/default_face.png), перезаписывая user://face.png.
func reset_face() -> void:
	var tex := load(DEFAULT_FACE) as Texture2D
	if tex != null:
		tex.get_image().save_png(_face_path)


## PNG-байты текущего лица (256×256, с альфой) — то, что уходит другим игрокам по сети.
func face_png() -> PackedByteArray:
	if FileAccess.file_exists(_face_path):
		return FileAccess.get_file_as_bytes(_face_path)
	return PackedByteArray()


## Текстура текущего лица для превью в настройках.
func face_texture() -> Texture2D:
	var img := Image.new()
	if FileAccess.file_exists(_face_path) and img.load(_face_path) == OK:
		return ImageTexture.create_from_image(img)
	return load(DEFAULT_FACE) as Texture2D


## Загружает выбранный пользователем файл как лицо: ресайз до 256×256 (сохраняя альфу)
## и запись в user://face.png. Возвращает успех.
func set_face_from_file(path: String) -> bool:
	var img := Image.new()
	if img.load(path) != OK:
		return false
	img.convert(Image.FORMAT_RGBA8)   # гарантируем канал альфы (прозрачность)
	img.resize(FACE_SIZE, FACE_SIZE, Image.INTERPOLATE_LANCZOS)
	return img.save_png(_face_path) == OK


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_path) != OK:
		return
	online_enabled = not cfg.get_value("net", "offline_enabled", not online_enabled)
	voice_mode = cfg.get_value("voice", "mode", voice_mode)
	if voice_mode != VOICE_MODE_PTT and voice_mode != VOICE_MODE_VAD:
		voice_mode = VOICE_MODE_PTT
	input_device = cfg.get_value("voice", "input_device", input_device)
	mic_gain = maxf(0.0, cfg.get_value("voice", "mic_gain", mic_gain))
	vad_threshold = maxf(0.0, cfg.get_value("voice", "vad_threshold", vad_threshold))
	voice_denoise = cfg.get_value("voice", "denoise", voice_denoise)
	output_device = cfg.get_value("audio", "output_device", output_device)
	for bus_name in AUDIO_BUSES:
		bus_volumes[bus_name] = clampf(cfg.get_value("audio", "vol_" + bus_name, bus_volumes[bus_name]), 0.0, 1.0)
	signaling_url = cfg.get_value("net", "signaling_url", signaling_url)
	# Миграция со старой семантики: раньше в cfg всегда лежал полный адрес (дефолт из
	# BuildConfig копировался при первом же сохранении). Значение, равное дефолту сборки,
	# считаем «не переопределял» — авторежим (анонс домашнего сервера сможет его заменить).
	if signaling_url == BuildConfig.signaling_url:
		signaling_url = ""
	home_server_url = cfg.get_value("net", "home_server_url", home_server_url)
	home_page = cfg.get_value("browser", "home_page", home_page)
	fov = clampf(cfg.get_value("graphics", "fov", fov), FOV_MIN, FOV_MAX)
	nick = cfg.get_value("net", "nick", nick)
	user_id = cfg.get_value("identity", "user_id", user_id)
	avatar_uri = cfg.get_value("avatar", "uri", avatar_uri)
	page_script_policy = str(cfg.get_value("security", "page_script_policy", page_script_policy))
	if page_script_policy not in [SCRIPT_POLICY_ASK, SCRIPT_POLICY_ALLOW_ALL, SCRIPT_POLICY_BLOCK_ALL]:
		page_script_policy = SCRIPT_POLICY_ASK
	var stored_rules = cfg.get_value("security", "page_script_rules", {})
	page_script_rules = stored_rules if typeof(stored_rules) == TYPE_DICTIONARY else {}
	if avatar_uri.strip_edges() == "":
		avatar_uri = DEFAULT_AVATAR_URI


## Сохраняет текущие значения на диск и оповещает подписчиков.
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "offline_enabled", not online_enabled)
	cfg.set_value("voice", "mode", voice_mode)
	cfg.set_value("voice", "input_device", input_device)
	cfg.set_value("voice", "mic_gain", mic_gain)
	cfg.set_value("voice", "vad_threshold", vad_threshold)
	cfg.set_value("voice", "denoise", voice_denoise)
	cfg.set_value("audio", "output_device", output_device)
	for bus_name in AUDIO_BUSES:
		cfg.set_value("audio", "vol_" + bus_name, bus_volumes[bus_name])
	cfg.set_value("net", "signaling_url", signaling_url)
	cfg.set_value("net", "home_server_url", home_server_url)
	cfg.set_value("browser", "home_page", home_page)
	cfg.set_value("graphics", "fov", fov)
	cfg.set_value("net", "nick", nick)
	cfg.set_value("identity", "user_id", user_id)
	cfg.set_value("avatar", "uri", avatar_uri)
	cfg.set_value("security", "page_script_policy", page_script_policy)
	cfg.set_value("security", "page_script_rules", page_script_rules)
	cfg.save(_path)
	apply_audio()
	changed.emit()


## Стабильный ключ exact-code правила. URL ресурса намеренно не входит: redirect/CDN может
## меняться, но доверие всё равно ограничено origin страницы, module id и проверенным hash.
func page_script_rule_key(origin: String, module_id: String, hash: String) -> String:
	return (origin + "\n" + module_id + "\n" + hash).sha256_text()


func page_script_decision(origin: String, module_id: String, hash: String) -> String:
	if page_script_policy == SCRIPT_POLICY_ALLOW_ALL:
		return "allow"
	if page_script_policy == SCRIPT_POLICY_BLOCK_ALL:
		return "block"
	var rule = page_script_rules.get(page_script_rule_key(origin, module_id, hash), {})
	return str(rule.get("decision", "")) if typeof(rule) == TYPE_DICTIONARY else ""


func remember_page_script_decision(origin: String, module: Dictionary, decision: String) -> void:
	if decision not in ["allow", "block"]:
		return
	var hash := str(module.get("hash", ""))
	var id := str(module.get("id", ""))
	page_script_rules[page_script_rule_key(origin, id, hash)] = {
		"decision": decision, "origin": origin, "module_id": id,
		"resource_url": str(module.get("resolved_url", "inline")), "hash": hash,
		"updated_at": int(Time.get_unix_time_from_system()),
	}
	save()


func forget_page_script_rule(key: String) -> void:
	page_script_rules.erase(key)
	save()


func clear_page_script_rules() -> void:
	page_script_rules.clear()
	save()
