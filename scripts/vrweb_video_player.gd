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


## Доступен ли нативный декодер (аддон FFmpeg в addons/ffmpeg/).
static func is_available() -> bool:
	return ClassDB.class_exists(FFMPEG_STREAM_CLASS)


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
			push_warning("[VRWeb] видео недоступно: положите аддон FFmpeg в addons/ffmpeg/")
		return
	_vsp = VideoStreamPlayer.new()
	_vsp.expand = false
	_vsp.size = Vector2.ZERO
	_vsp.volume = _volume
	if "loop" in _vsp:   # VideoStreamPlayer.loop появился не во всех сборках
		_vsp.loop = _loop
	# visible=false: VideoStreamPlayer (это Control) не рисуется на экране, но продолжает
	# декодировать. ВАЖНО: его НЕЛЬЗЯ класть в невидимый CanvasLayer — там проигрывание
	# замирает (pos не растёт). Невидимый сам по себе VSP играет нормально.
	_vsp.visible = false
	add_child(_vsp)
	_resolve_source()


# --- Источник (скачивание / локальный файл) ---

## Готовит файл для FFmpegVideoStream: локальные схемы читаем как путь напрямую, http(s)
## качаем в user://-кэш (через Sandbox, как все user://-пути — см. docs/multiplayer.md).
func _resolve_source() -> void:
	if PageFetcher.is_local(_src_url):
		var path := PageFetcher.to_file_path(_src_url)
		if path != "" and FileAccess.file_exists(path):
			_open_file(path)
		return
	var cache_path := _cache_path_for(_src_url)
	if FileAccess.file_exists(cache_path):
		_open_file(cache_path)
		return
	_download(_src_url, cache_path)


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


func _download(url: String, dest: String) -> void:
	var http := HTTPRequest.new()
	http.use_threads = true
	http.download_file = dest
	add_child(http)
	http.request_completed.connect(
		func(result, code, _headers, _body):
			http.queue_free()
			if result == HTTPRequest.RESULT_SUCCESS and code < 400 and FileAccess.file_exists(dest):
				_open_file(dest)
			else:
				# HTTPRequest пишет тело в файл даже при ошибке (403/404 → заглушка). Удаляем,
				# чтобы битый файл не закэшировался и не подхватился следующим запуском.
				if FileAccess.file_exists(dest):
					DirAccess.remove_absolute(dest)
				push_warning("[VRWeb] видео не скачалось: %s (код %d)" % [url, code]))
	if http.request(url, ["User-Agent: " + USER_AGENT]) != OK:
		http.queue_free()
		push_warning("[VRWeb] не удалось запросить видео: " + url)


## Создаёт FFmpegVideoStream из файла и запускает декод. Кадр-текстуру отдаём через
## texture_ready, как только появится первый кадр (поллим в _process — get_video_texture
## становится валидным не сразу).
func _open_file(path: String) -> void:
	if _vsp == null:
		return
	var stream := ClassDB.instantiate(FFMPEG_STREAM_CLASS) as VideoStream
	if stream == null:
		return
	stream.file = path
	_vsp.stream = stream
	_vsp.play()   # пауза (если не autoplay) — после появления первого кадра-постера
	set_process(true)


func _process(_delta: float) -> void:
	if _vsp == null or _texture != null:
		set_process(false)
		return
	var t := _vsp.get_video_texture()
	if t != null:
		_texture = t
		if not _autoplay:
			_vsp.paused = true
		texture_ready.emit(t)
		set_process(false)


# --- Текстура ---

func current_texture() -> Texture2D:
	return _texture


# --- Транспорт ---

func is_playing() -> bool:
	return _vsp != null and _vsp.is_playing() and not _vsp.paused


func position() -> float:
	return _vsp.stream_position if _vsp != null else 0.0


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
	if not _vsp.is_playing():
		_vsp.play()
	_vsp.paused = false


func _do_pause() -> void:
	if _vsp != null:
		_vsp.paused = true


func _do_seek(t: float) -> void:
	if _vsp != null:
		_vsp.stream_position = maxf(0.0, t)
