class_name VrwebVideoPlayer
extends Node

## Логический видео-плеер VRWeb (как в VRChat): декодирует видео по ссылке в текстуру
## («рендер-буфер»), которую затем можно натянуть на любое число поверхностей
## (VrwebVideoScreen). Сам невидим — это «движок» воспроизведения. Размещается кастомным
## тегом <VRWebVideoPlayer id=... src=...> (см. scripts/vrweb_builder.gd, docs/video-player.md).
##
## Декодер: нативный аддон FFmpeg (класс FFmpegVideoStream, ставится в addons/ffmpeg/ как
## webrtc-native). Штатный VideoStreamPlayer умеет только Ogg Theora, поэтому mp4/H.264
## требует аддона. Без аддона плеер не стартует (is_available() == false), а поверхности
## показывают заглушку.
##
## Кадр доступен через get_video_texture() штатного VideoStreamPlayer — он обновляется на
## месте каждый кадр, поэтому одну текстуру можно раздать многим материалам (как
## AnimatedTexture у гифок). Сам VideoStreamPlayer живёт в скрытом CanvasLayer — он не
## рисуется на экране, но декодирует, пока играет.
##
## Транспорт (play/pause/seek) бывает локальный (клик по экрану → эмитит transport_changed,
## VrwebVideoManager ретранслирует в сеть) и удалённый (apply_remote из сети — БЕЗ эмита,
## чтобы не зациклить). Синхронизацию между клиентами ведёт менеджер.

const FFMPEG_STREAM_CLASS := "FFmpegVideoStream"
const CACHE_DIR := "user://video_cache"
const USER_AGENT := "VRWeb/0.1 (Godot; +knossos)"
const DRIFT_THRESHOLD := 0.5   # с; большее расхождение с таймкодом таймкипера → seek
const SYNC_GRACE_MS := 1000    # мс; игнорируем heartbeat после явного действия (анти-дребезг)

# --- Прогрессивная загрузка (буферизация) ---
const START_BUFFER_BYTES := 2 << 20    # старт декода после ~2 МБ — не дожидаясь полной загрузки
const REOPEN_AHEAD_BYTES := 512 << 10  # на сколько докачка должна уйти вперёд, чтобы перезапустить после underrun
const PROBE_TIMEOUT_MS := 3000         # ждём первый кадр при раннем открытии; нет — значит moov в хвосте файла → ждём полную загрузку
const RETRY_INTERVAL := 0.3            # период проверки буфера/перезапуска при ожидании докачки, с
const DEBUG := true                    # печатать ход загрузки/декода в Output (отладка плеера)

## Текстура кадра готова (обновляется на месте) — поверхности привязываются к ней.
signal texture_ready(texture: Texture2D)
## Локальное транспортное действие игрока — менеджер рассылает его в сеть.
signal transport_changed(action: String, position: float)

var id: String = ""

var _src_url := ""
var _autoplay := false
var _loop := false
var _volume := 1.0

var _vsp: VideoStreamPlayer = null
var _texture: Texture2D = null
var _ignore_sync_until_ms := 0   # до этого времени (ticks_msec) heartbeat игнорируется

# Состояние прогрессивной загрузки (см. _process — там вся машина состояний).
var _http: HTTPRequest = null
var _download_path := ""         # файл, из которого декодируем; во время скачивания это .part (растёт по ходу)
var _downloading := false        # HTTP-запрос ещё в полёте
var _download_done := false      # данных больше не будет (успешно докачали ИЛИ обрыв)
var _opened := false             # FFmpegVideoStream уже открыт хоть раз
var _ever_started := false       # декодер хоть раз выдал кадр → прогрессив возможен (faststart-видео)
var _want_playing := false       # целевое состояние транспорта — восстанавливаем после перезапуска
var _waiting_buffer := false     # упёрлись в конец докачки (ложный EOF) — ждём новых байт
var _early_open_blocked := false # ранний старт не удался (moov в хвосте) — ждём полной загрузки
var _probe_deadline_ms := 0      # до этого момента ждём первый кадр после раннего открытия
var _resume_pos := 0.0           # позиция, на которую вернёмся после перезапуска
var _resume_size := 0            # размер файла на момент underrun — ждём прироста от него
var _retry_accum := 0.0          # таймер перезапросов в _waiting_buffer
var _progress_accum := 0.0       # таймер логирования прогресса докачки (DEBUG)


## Доступен ли нативный декодер (аддон FFmpeg в addons/ffmpeg/).
static func is_available() -> bool:
	return ClassDB.class_exists(FFMPEG_STREAM_CLASS)


## Отладочный лог хода загрузки/декода (DEBUG). Тег включает id плеера, чтобы различать
## несколько плееров на сцене.
func _vlog(msg: String) -> void:
	if DEBUG:
		Log.info("video", "%s: %s" % [id if id != "" else _src_url, msg])


## Параметры из тега. Зовётся билдером до add_child (до _ready), как VrwebMirror.setup.
func setup(p_id: String, p_src_url: String, p_autoplay: bool, p_loop: bool, p_volume: float) -> void:
	id = p_id
	_src_url = p_src_url
	_autoplay = p_autoplay
	_loop = p_loop
	_volume = clampf(p_volume, 0.0, 1.0)


func _ready() -> void:
	if _src_url == "" or not is_available():
		if _src_url != "":
			Log.warn("video", "видео недоступно: положите аддон FFmpeg в addons/ffmpeg/")
		return
	_want_playing = _autoplay
	_vsp = VideoStreamPlayer.new()
	_vsp.expand = false
	_vsp.size = Vector2.ZERO
	_vsp.volume = _volume
	# Звук видео — на шину «World» (звуки мира/страницы), регулируется ползунком «Мир»
	# в настройках (см. default_bus_layout.tres, docs/audio.md).
	_vsp.bus = &"World"
	# Штатный loop включаем ТОЛЬКО когда файл скачан целиком (_maybe_enable_loop): иначе
	# ложный EOF на конце докачки зациклил бы видео на начало вместо ожидания докачки.
	# visible=false: VideoStreamPlayer (это Control) не рисуется на экране, но продолжает
	# декодировать. ВАЖНО: его НЕЛЬЗЯ класть в невидимый CanvasLayer — там проигрывание
	# замирает (pos не растёт). Невидимый сам по себе VSP играет нормально.
	_vsp.visible = false
	add_child(_vsp)
	_vlog("init: src=%s autoplay=%s loop=%s" % [_src_url, _autoplay, _loop])
	_resolve_source()


# --- Источник (скачивание / локальный файл) ---

## Готовит файл для FFmpegVideoStream: локальные схемы читаем как путь напрямую, http(s)
## качаем в user://-кэш (через Sandbox, как все user://-пути — см. docs/multiplayer.md).
## Локальный/уже-кэшированный файл целый → открываем сразу; иначе качаем прогрессивно
## (декод стартует, не дожидаясь полной загрузки — см. _process).
func _resolve_source() -> void:
	if PageFetcher.is_local(_src_url):
		var path := PageFetcher.to_file_path(_src_url)
		if path != "" and FileAccess.file_exists(path):
			_vlog("локальный файл: " + path)
			_use_complete_file(path)
		else:
			_vlog("локальный файл не найден: %s (path=%s)" % [_src_url, path])
		return
	var cache_path := _cache_path_for(_src_url)
	if FileAccess.file_exists(cache_path):
		_vlog("из кэша: %s (%d Б)" % [cache_path, _file_size(cache_path)])
		_use_complete_file(cache_path)
		return
	# Качаем во временный .part и переименуем в cache_path только при успехе — иначе
	# оборванный файл закэшировался бы как целый и подхватился следующим запуском.
	_download(_src_url, cache_path + ".part", cache_path)


## Файл уже целиком на диске (локальный или кэш) — данных больше не будет, можно открыть
## с полным набором (в т.ч. штатным loop) сразу.
func _use_complete_file(path: String) -> void:
	_download_path = path
	_download_done = true
	_maybe_enable_loop()
	_open_file(path)


func _cache_path_for(url: String) -> String:
	var dir := Sandbox.resolve(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir + "/" + str(hash(url)) + _ext_of(url)


func _ext_of(url: String) -> String:
	var clean := url.split("?")[0].split("#")[0]
	var dot := clean.rfind(".")
	if dot > clean.rfind("/") and dot >= 0:
		var ext := clean.substr(dot)
		if ext.length() <= 5:
			return ext
	return ".mp4"


## Прогрессивное скачивание: HTTPRequest.download_file пишет тело в part_path по мере приёма,
## а _process открывает декод по этому растущему файлу, не дожидаясь завершения. По успеху
## переименовываем part_path → final_path (целый файл в кэше).
func _download(url: String, part_path: String, final_path: String) -> void:
	_download_path = part_path
	_downloading = true
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.download_file = part_path
	add_child(_http)
	_http.request_completed.connect(
		func(result, code, _headers, _body):
			_on_download_done(result, code, part_path, final_path))
	_vlog("старт докачки %s → %s" % [url, part_path])
	if _http.request(url, ["User-Agent: " + USER_AGENT]) != OK:
		_downloading = false
		_http.queue_free()
		_http = null
		Log.warn("video", "не удалось запросить видео: " + url)
		_vlog("HTTPRequest.request() != OK — запрос не ушёл")
		return
	set_process(true)   # пуллим размер файла для раннего старта декода


func _on_download_done(result: int, code: int, part_path: String, final_path: String) -> void:
	_downloading = false
	_download_done = true   # данных больше не будет (успех или обрыв) — _process перестанет ждать докачку
	if _http != null:
		_http.queue_free()
		_http = null
	var ok := result == HTTPRequest.RESULT_SUCCESS and code < 400 and FileAccess.file_exists(part_path)
	_vlog("докачка завершена: result=%d code=%d ok=%s размер=%d opened=%s started=%s"
		% [result, code, ok, _file_size(part_path), _opened, _ever_started])
	if ok:
		# Частичный файл стал целым — фиксируем в кэше под финальным именем. Декодер уже мог
		# открыть .part; на POSIX переименование не рвёт открытый дескриптор, а новые открытия
		# (перезапуск/первый старт) пойдут по обновлённому _download_path.
		if final_path != part_path:
			DirAccess.rename_absolute(part_path, final_path)
		_download_path = final_path
		_maybe_enable_loop()
		if not _opened:   # мелкий файл или moov в хвосте — не стартовали раньше, открываем сейчас
			_vlog("открываю файл целиком (ранний старт не случился)")
			_open_file(_download_path)
	else:
		Log.warn("video", "видео не докачалось: %s (код %d)" % [_src_url, code])
		# Если успели стартовать прогрессивно — оставляем .part (доиграется до реального конца).
		# Иначе чистим заглушку 403/404, чтобы битый файл не закэшировался.
		if not _ever_started and FileAccess.file_exists(part_path):
			DirAccess.remove_absolute(part_path)


## Штатный loop VideoStreamPlayer — только когда файл целиком на диске (иначе ложный EOF
## зациклил бы видео вместо ожидания докачки). Свойство есть не во всех сборках аддона.
func _maybe_enable_loop() -> void:
	if _vsp != null and _loop and "loop" in _vsp:
		_vsp.loop = true


## Текущий размер файла на диске (сколько байт декодер реально может прочитать).
func _file_size(path: String) -> int:
	if path == "":
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	return f.get_length()


## Создаёт FFmpegVideoStream из файла и запускает декод. Кадр-текстуру отдаём через
## texture_ready, как только появится первый кадр (поллим в _process — get_video_texture
## становится валидным не сразу). При (пере)открытии растущего файла можно задать resume_pos —
## позицию, на которую вернёмся после докачки (см. _process: ложный EOF).
func _open_file(path: String, resume_pos := 0.0) -> void:
	if _vsp == null:
		return
	var stream := ClassDB.instantiate(FFMPEG_STREAM_CLASS) as VideoStream
	if stream == null:
		return
	stream.file = path
	# Перезапуск создаёт НОВЫЙ playback → новый объект текстуры. Сбрасываем _texture, чтобы
	# _process поймал его заново и переэмитнул texture_ready (экраны перепривяжут albedo).
	_texture = null
	_vsp.stream = stream
	_opened = true
	_vsp.play()   # пауза (если не _want_playing) — после появления первого кадра-постера
	if resume_pos > 0.0:
		_do_seek(resume_pos)
	_probe_deadline_ms = Time.get_ticks_msec() + PROBE_TIMEOUT_MS
	_vlog("открыл декод: %s (resume=%.2f, играет=%s)" % [path, resume_pos, _vsp.is_playing()])
	set_process(true)


## Машина состояний прогрессивной загрузки. Гоняется, пока файл качается или ещё нет кадра;
## после полной загрузки и получения кадра выключается.
##   1. Ранний старт: открыть декод, накопив START_BUFFER_BYTES (для faststart-видео).
##   2. Первый/новый кадр: поймать текстуру; нет первого кадра дольше PROBE_TIMEOUT → moov,
##      видимо, в хвосте файла — закрыть и ждать полной загрузки.
##   3. Ложный EOF: воспроизведение встало, хотя паузу не ставили и докачка не кончилась —
##      это конец докачанного куска, не конец видео. Запоминаем позицию.
##   4. Перезапуск: дождавшись новых байт, переоткрываем файл и возвращаемся на позицию.
func _process(delta: float) -> void:
	if _vsp == null:
		set_process(false)
		return

	# Прогресс докачки в Output ~раз в секунду — видно, что файл реально качается.
	if DEBUG and _downloading:
		_progress_accum += delta
		if _progress_accum >= 1.0:
			_progress_accum = 0.0
			var total := _http.get_body_size() if _http != null else -1
			var got := _http.get_downloaded_bytes() if _http != null else -1
			_vlog("качается: HTTP %d/%d Б, на диске %d Б, opened=%s" % [got, total, _file_size(_download_path), _opened])

	# 1. ранний старт декода, как только накопили буфер
	if not _opened and not _early_open_blocked and _downloading \
			and _file_size(_download_path) >= START_BUFFER_BYTES:
		_vlog("ранний старт: на диске %d Б ≥ порога %d" % [_file_size(_download_path), START_BUFFER_BYTES])
		_open_file(_download_path)

	# 2. первый/новый кадр после (пере)открытия
	if _opened and _texture == null:
		var t := _vsp.get_video_texture()
		if t != null:
			_texture = t
			_ever_started = true
			if not _want_playing:
				_vsp.paused = true
			_vlog("первый кадр: %s, играет=%s" % [t.get_size(), _vsp.is_playing()])
			texture_ready.emit(t)
		elif not _ever_started and not _download_done and Time.get_ticks_msec() > _probe_deadline_ms:
			# рано открыли, а кадра всё нет → moov, видимо, в хвосте. Закрываем и больше не
			# пробуем ранний старт — ждём полной загрузки (откроем в _on_download_done).
			_vlog("нет первого кадра за %d мс → moov, видимо, в хвосте; жду полной загрузки" % PROBE_TIMEOUT_MS)
			_vsp.stream = null
			_opened = false
			_early_open_blocked = true

	# 3. ложный EOF: играли (намерение _want_playing), не на паузе, но playback встал, а
	#    докачка ещё идёт — это конец докачанного куска. Ждём новых байт и перезапускаем.
	if _opened and _ever_started and not _waiting_buffer and _want_playing \
			and not _vsp.paused and not _vsp.is_playing() and not _download_done:
		_waiting_buffer = true
		_resume_pos = _vsp.stream_position
		_resume_size = _file_size(_download_path)
		_retry_accum = 0.0
		_vlog("ложный EOF на %.2f c (на диске %d Б) — жду докачки" % [_resume_pos, _resume_size])

	# 4. ждём прироста файла (или полной загрузки) и переоткрываем с сохранённой позиции
	if _waiting_buffer:
		_retry_accum += delta
		if _retry_accum >= RETRY_INTERVAL:
			_retry_accum = 0.0
			if _download_done or _file_size(_download_path) >= _resume_size + REOPEN_AHEAD_BYTES:
				_vlog("докачалось до %d Б — перезапуск с %.2f c" % [_file_size(_download_path), _resume_pos])
				_waiting_buffer = false
				_open_file(_download_path, _resume_pos)

	# делать в _process больше нечего, когда всё скачано и кадр получен
	if _download_done and _texture != null and not _waiting_buffer:
		set_process(false)


# --- Текстура ---

func current_texture() -> Texture2D:
	return _texture


# --- Транспорт ---

func is_playing() -> bool:
	return _vsp != null and _vsp.is_playing() and not _vsp.paused


func position() -> float:
	return _vsp.stream_position if _vsp != null else 0.0


## Длительность видео, с (0 — пока неизвестна, например, до старта декода).
func duration() -> float:
	return _vsp.get_stream_length() if _vsp != null else 0.0


## Доля файла, уже скачанная и доступная декодеру (0..1) — это и есть «буфер» для UI экрана.
## Пока качаем, считаем от ожидаемого размера тела (Content-Length); после докачки — целиком.
func buffered_fraction() -> float:
	if _download_done:
		return 1.0
	var total := _http.get_body_size() if _http != null else 0
	if total > 0:
		return clampf(float(_file_size(_download_path)) / float(total), 0.0, 1.0)
	return 0.0


## Плеер упёрся в конец докачанного куска и ждёт новых байт (underrun) — UI показывает «…».
func is_buffering() -> bool:
	return _waiting_buffer


## Поток уже открыт (есть смысл слать по нему heartbeat) — таймкипер шлёт только такие.
func has_started() -> bool:
	return _vsp != null and _vsp.stream != null


## Локальные методы — меняют состояние И эмитят transport_changed (уйдёт в сеть).
func toggle() -> void:
	if is_playing():
		pause()
	else:
		play()


func play() -> void:
	_bump_grace()
	_do_play()
	transport_changed.emit("play", position())


func pause() -> void:
	_bump_grace()
	_do_pause()
	transport_changed.emit("pause", position())


func seek(t: float) -> void:
	_bump_grace()
	_do_seek(t)
	transport_changed.emit("seek", t)


## Применить удалённое состояние — БЕЗ эмита (иначе сетевой цикл).
##   play/pause/seek — явные события (reliable), last-writer-wins; ставят grace-окно, чтобы
##     устаревший heartbeat не перебил свежее действие.
##   sync_play/sync_pause — heartbeat таймкипера (позиция + состояние): синхронизируют и
##     play/pause, И позицию (это и решает late-join). В grace-окне игнорируются.
func apply_remote(action: String, pos: float) -> void:
	match action:
		"play":
			_bump_grace()
			_do_seek(pos)
			_do_play()
		"pause":
			_bump_grace()
			_do_seek(pos)
			_do_pause()
		"seek":
			_bump_grace()
			_do_seek(pos)
		"sync_play":
			if Time.get_ticks_msec() < _ignore_sync_until_ms:
				return
			if not is_playing():
				_do_play()
			if absf(position() - pos) > DRIFT_THRESHOLD:
				_do_seek(pos)
		"sync_pause":
			if Time.get_ticks_msec() < _ignore_sync_until_ms:
				return
			if is_playing():
				_do_pause()
			if absf(position() - pos) > DRIFT_THRESHOLD:
				_do_seek(pos)


## Окно, в течение которого игнорируем heartbeat (sync_*) после явного действия — чтобы
## устаревший таймкод от таймкипера не «откатил» свежий play/pause/seek (он/гость сойдутся
## после распространения reliable-события).
func _bump_grace() -> void:
	_ignore_sync_until_ms = Time.get_ticks_msec() + SYNC_GRACE_MS


func _do_play() -> void:
	if _vsp == null:
		return
	_want_playing = true   # запомнить намерение — восстановим после перезапуска при докачке
	if not _vsp.is_playing():
		_vsp.play()
	_vsp.paused = false


func _do_pause() -> void:
	_want_playing = false
	if _vsp != null:
		_vsp.paused = true


func _do_seek(t: float) -> void:
	if _vsp != null:
		_vsp.stream_position = maxf(0.0, t)
