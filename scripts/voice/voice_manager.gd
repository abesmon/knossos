extends Node

## Голосовой чат — отправляющая сторона (autoload «VoiceManager»).
##
## Тракт: микрофон → шина с AudioEffectCapture → даунмикс в моно → VAD (детектор речи) →
## ресемпл к VoiceCodec.RATE → нарезка на кадры → кодирование → NetworkManager.send_voice.
## Приём и пространственное воспроизведение — на капсулах (RemotePlayer/VoicePlayback),
## поэтому здесь только захват и локальное состояние.
##
## Помимо сетевого захвата есть режим МОНИТОРИНГА — проверка микрофона в настройках без сети:
## считает уровень входного сигнала (input_level) и может проигрывать его обратно (loopback,
## «слышать себя»). Захват микрофона включается, если нужен сети ИЛИ идёт мониторинг; иначе
## устройство отпускается.
##
## Полностью на GDScript, без зависимостей; ограничения и расчёты — в docs/voice-chat.md.

## Локальная речь открылась/закрылась (по VAD) — для индикации в UI.
signal local_speaking_changed(speaking: bool)

const BUS_NAME := "VoiceCapture"
## Длина буфера эффекта захвата (с). С запасом перекрывает интервал кадра, чтобы не терять
## семплы между опросами в _process.
const CAPTURE_BUFFER := 0.1
## Множитель входного усиления перед VAD/кодированием.
const INPUT_GAIN := 1.0

## VAD с гистерезисом: речь «открывается» выше OPEN_RMS и держится, пока громкость не упадёт
## ниже CLOSE_RMS дольше HOLD_SEC. Два порога и удержание не дают «дребезга» на паузах между
## словами и не режут тихие хвосты фраз. Пороги по RMS амплитуды [-1;1].
const OPEN_RMS := 0.04
const CLOSE_RMS := 0.02
const HOLD_SEC := 0.35
## Скорость спада индикатора уровня (ед./с): атака мгновенная (пик), спад плавный.
const LEVEL_DECAY := 6.0

var muted := false:
	set(value):
		muted = value
		if value and _speaking:
			_set_speaking(false)

# Захват держим без статической типизации классов, которые могут отсутствовать на платформе.
var _bus_idx := -1
var _capture: AudioEffectCapture = null
var _mic_player: AudioStreamPlayer = null
var _codec := VoiceCodec.new()
var _resampler: LinearResampler = null
var _send_accum := PackedFloat32Array()
var _speaking := false
var _silence_sec := 0.0

# Мониторинг (проверка в настройках).
var _monitoring := false
var _loopback := false
var _monitor_pb: AudioStreamGeneratorPlayback = null
var _level := 0.0   # сглаженный уровень входа [0..1] для индикатора


func _ready() -> void:
	_setup_capture()
	apply_input_device(Settings.input_device)


func is_speaking() -> bool:
	return _speaking


# --- Выбор входного устройства ---

## Список доступных входных устройств (включая "Default" — следовать системному выбору).
func input_device_list() -> PackedStringArray:
	return AudioServer.get_input_device_list()


## Текущее активное входное устройство.
func current_input_device() -> String:
	return AudioServer.input_device


## Переключить вход на устройство по имени. Пустое/неизвестное → "Default".
func apply_input_device(device_name: String) -> void:
	AudioServer.input_device = device_name if device_name != "" else "Default"


# --- Мониторинг (проверка микрофона) ---

## Включить/выключить проверку микрофона. loopback — проигрывать вход обратно («слышать себя»).
func set_monitoring(enabled: bool, loopback: bool = false) -> void:
	_monitoring = enabled
	_loopback = loopback
	if not enabled:
		_level = 0.0


func is_monitoring() -> bool:
	return _monitoring


## Текущий уровень входного сигнала [0..1] — для индикатора в настройках. 0, если захвата нет.
func input_level() -> float:
	return _level


# --- Захват ---

func _setup_capture() -> void:
	# Отдельная шина с эффектом захвата; muted — чтобы не слышать собственный микрофон.
	_bus_idx = AudioServer.bus_count
	AudioServer.add_bus(_bus_idx)
	AudioServer.set_bus_name(_bus_idx, BUS_NAME)
	AudioServer.set_bus_mute(_bus_idx, true)
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = CAPTURE_BUFFER
	AudioServer.add_bus_effect(_bus_idx, _capture)

	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = BUS_NAME
	add_child(_mic_player)

	_resampler = LinearResampler.new(AudioServer.get_mix_rate(), float(VoiceCodec.RATE))

	# Локальный loopback-плеер (для «слышать себя»): генератор на частоте микшера, на Master.
	# Играет всегда, но кадры в него кладём только при включённом мониторинге с loopback.
	var monitor := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.1
	monitor.stream = gen
	add_child(monitor)
	monitor.play()
	_monitor_pb = monitor.get_stream_playback()


## Нужно ли захватывать ради сети: онлайн, голос включён, не заглушены и есть кому слать.
func _want_network_capture() -> bool:
	return Settings.voice_enabled \
		and not muted \
		and NetworkManager.is_online() \
		and NetworkManager.peer_count() > 0


func _process(delta: float) -> void:
	if _mic_player == null:
		return
	var net := _want_network_capture()
	var want := net or _monitoring
	if want != _mic_player.playing:
		# Старт/стоп микрофона по необходимости. На остановке чистим хвосты сессии.
		if want:
			_mic_player.play()
		else:
			_mic_player.stop()
			_send_accum.clear()
			_set_speaking(false)
			_level = 0.0
	if not want or _capture == null:
		return

	var avail := _capture.get_frames_available()
	if avail <= 0:
		_decay_level(delta)
		return
	var stereo := _capture.get_buffer(avail)
	var mono := _downmix(stereo)
	_update_level(mono, delta)
	_update_vad(mono, delta)

	# «Слышать себя»: кладём вход в loopback-плеер (на частоте микшера, без ресемпла).
	if _monitoring and _loopback and _monitor_pb != null:
		var room := _monitor_pb.get_frames_available()
		var m := mini(mono.size(), room)
		for i in m:
			_monitor_pb.push_frame(Vector2(mono[i], mono[i]))

	# Сетевой путь: ресемплим всегда (непрерывная фаза), в эфир кладём только во время речи.
	if net:
		_resampler.process(mono, _send_accum)
		if _speaking:
			while _send_accum.size() >= VoiceCodec.FRAME_SAMPLES:
				var frame := _send_accum.slice(0, VoiceCodec.FRAME_SAMPLES)
				NetworkManager.send_voice(_codec.encode(frame))
				_send_accum = _send_accum.slice(VoiceCodec.FRAME_SAMPLES)
		else:
			_send_accum.clear()
	else:
		_send_accum.clear()


## Стерео-буфер захвата → моно с усилением. Микрофон обычно моно (L==R), но усредняем честно.
func _downmix(stereo: PackedVector2Array) -> PackedFloat32Array:
	var mono := PackedFloat32Array()
	mono.resize(stereo.size())
	for i in stereo.size():
		var f := stereo[i]
		mono[i] = (f.x + f.y) * 0.5 * INPUT_GAIN
	return mono


## Уровень входа для индикатора: атака по пику мгновенная, спад плавный (LEVEL_DECAY).
func _update_level(mono: PackedFloat32Array, delta: float) -> void:
	var peak := 0.0
	for s in mono:
		peak = maxf(peak, absf(s))
	if peak >= _level:
		_level = peak
	else:
		_level = maxf(peak, _level - LEVEL_DECAY * delta)


func _decay_level(delta: float) -> void:
	_level = maxf(0.0, _level - LEVEL_DECAY * delta)


## VAD: считаем RMS кадра и ведём состояние речи с гистерезисом и удержанием.
func _update_vad(mono: PackedFloat32Array, delta: float) -> void:
	if mono.is_empty():
		return
	var sum_sq := 0.0
	for s in mono:
		sum_sq += s * s
	var rms := sqrt(sum_sq / float(mono.size()))
	if _speaking:
		if rms < CLOSE_RMS:
			_silence_sec += delta
			if _silence_sec >= HOLD_SEC:
				_set_speaking(false)
		else:
			_silence_sec = 0.0
	elif rms >= OPEN_RMS:
		_set_speaking(true)
		_silence_sec = 0.0


func _set_speaking(value: bool) -> void:
	if _speaking == value:
		return
	_speaking = value
	local_speaking_changed.emit(value)
