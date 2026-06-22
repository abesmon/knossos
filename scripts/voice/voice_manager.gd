extends Node

## Голосовой чат — отправляющая сторона (autoload «VoiceManager»).
##
## ЗАХВАТ ЧЕРЕЗ ШИНУ: AudioStreamMicrophone → шина с AudioEffectCapture. Ресемплингом
## устройства к частоте микшера занимается сам движок, поэтому захваченные кадры всегда на
## ИЗВЕСТНОЙ частоте get_mix_rate(). Развязанный get_input_frames-API (Godot 4.6) для голоса
## НЕ используем: при подключённых Bluetooth-наушниках он отдаёт не-BT микрофон с неверной
## заявленной частотой и рваным потоком (talkbox/робовойс). Подробности и известное ограничение
## Bluetooth — в docs/voice-chat.md.
##
## Тракт: микрофон → шина (get_mix_rate) → даунмикс в моно → VAD → Opus-энкодер (twovoip,
## сам ресемплит к VoiceCodec.OPUS_RATE) → NetworkManager.send_voice. Энкодер stateful и принимает
## кадры порциями фиксированного размера (calc_audio_chunk_size), поэтому моно копится в
## _enc_accum и скармливается ровно по чанку: process_pre_encoded_chunk (ресемпл+буфер), затем —
## пока открыт VAD — encode_chunk. Приём и пространственное воспроизведение — на капсулах
## (RemotePlayer/VoicePlayback, через AudioStreamOpus). Подробно — docs/voice-chat.md.
## Есть режим МОНИТОРИНГА (проверка микрофона в настройках): уровень входа + опциональный loopback.

## Локальная речь открылась/закрылась (по VAD) — для индикации в UI.
signal local_speaking_changed(speaking: bool)

## Только что выбранный вход не отдаёт звук: за INPUT_CHECK_GRACE при активном микрофоне не
## пришло ни кадра захвата. Признак бага драйвера CoreAudio на macOS (краш -10863: входной
## AudioUnit нельзя переконфигурировать под частоту/режим, отличные от инициализации). UI ловит
## и просит перезапуск. Подробно — docs/godot-coreaudio-input-rate-bug.md.
signal input_device_failed(device_name: String)

const BUS_NAME := "VoiceCapture"
## Длина буфера эффекта захвата (с). С запасом перекрывает интервал кадра.
const CAPTURE_BUFFER := 0.1
## Множитель входного усиления по умолчанию (рантайм-значение — _input_gain, из Settings.mic_gain).
const DEFAULT_INPUT_GAIN := 1.0

## VAD с гистерезисом: речь «открывается» выше порога OPEN и держится, пока громкость не упадёт
## ниже порога CLOSE дольше HOLD_SEC. Два порога и удержание не дают «дребезга» на паузах между
## словами и не режут тихие хвосты фраз. Пороги по RMS амплитуды [-1;1]. Дефолты; рантайм-порог
## открытия — из Settings.vad_threshold, порог закрытия держим вдвое ниже (тот же гистерезис).
const DEFAULT_OPEN_RMS := 0.04
const CLOSE_TO_OPEN_RATIO := 0.5
const HOLD_SEC := 0.35
## Скорость спада индикатора уровня (ед./с): атака мгновенная (пик), спад плавный.
const LEVEL_DECAY := 6.0
## Окно проверки только что выбранного входа (с): сколько ждём первых кадров захвата, прежде чем
## счесть устройство «молчащим» (вход сломан, см. input_device_failed). С запасом на раскрутку
## Bluetooth-устройства, чтобы не было ложного срабатывания на медленном подключении.
const INPUT_CHECK_GRACE := 2.0

var muted := false:
	set(value):
		muted = value
		if value and _speaking:
			_set_speaking(false)

## Тюнинг входа (из Settings, регулируется в настройках живьём — см. set_input_gain/set_vad_threshold).
var _input_gain := DEFAULT_INPUT_GAIN
var _vad_open := DEFAULT_OPEN_RMS
var _vad_close := DEFAULT_OPEN_RMS * CLOSE_TO_OPEN_RATIO

var _bus_idx := -1
var _capture: AudioEffectCapture = null
var _mic_player: AudioStreamPlayer = null
# Opus-энкодер аддона twovoip (TwovoipOpusEncoder). Untyped: класс приходит из GDExtension и в
# сборке без аддона отсутствует — статическая типизация сломала бы парсинг автолоада. null, если
# аддон недоступен (VoiceCodec.opus_available()). Создаётся в _setup_capture.
var _encoder = null
var _rate := 0.0   # частота захвата (= get_mix_rate), под которую собран энкодер/монитор
var _denoise := false   # включён ли RNNoise-денойз (под этот флаг собран энкодер); из Settings
# Сколько кадров ВХОДА (на _rate) энкодер съедает за один Opus-кадр (calc_audio_chunk_size).
var _enc_chunk_in := 0
# Накопитель захвата для энкодера: моно как Vector2(m,m) на _rate, скармливается ровно по _enc_chunk_in.
var _enc_accum := PackedVector2Array()
# Префикс Opus-пакета. Пустой — без порядковых номеров (lenchunkprefix 0 на приёме): осознанно
# простое воспроизведение без переупорядочивания/FEC, как было на PCM (см. docs/voice-chat.md).
var _OPUS_PREFIX := PackedByteArray()
var _speaking := false
var _silence_sec := 0.0

# Проверка только что выбранного входа (детект «молчащего» устройства, см. input_device_failed).
var _check_device := ""   # имя проверяемого устройства; "" — проверка не идёт
var _check_elapsed := 0.0  # сколько уже ждём кадры (с, копится только при активном захвате)
var _check_frames := 0     # сколько кадров захвата пришло за окно проверки

# Мониторинг (проверка в настройках).
var _monitoring := false
var _loopback := false
var _monitor_player: AudioStreamPlayer = null
var _monitor_pb: AudioStreamGeneratorPlayback = null
var _level := 0.0   # сглаженный уровень входа [0..1] для индикатора


func _ready() -> void:
	_setup_capture()
	apply_input_device(Settings.input_device)
	apply_tuning()


# --- Тюнинг входа (усиление и порог активации) ---

## Подтягивает усиление и порог из Settings (на старте; настройки зовут сеттеры живьём).
func apply_tuning() -> void:
	set_input_gain(Settings.mic_gain)
	set_vad_threshold(Settings.vad_threshold)


## Множитель входного усиления (перед VAD и кодированием). <1 — тише, >1 — громче.
func set_input_gain(gain: float) -> void:
	_input_gain = maxf(0.0, gain)


## Порог активации речи (RMS открытия VAD). Порог закрытия держим вдвое ниже (гистерезис).
func set_vad_threshold(open_rms: float) -> void:
	_vad_open = maxf(0.0, open_rms)
	_vad_close = _vad_open * CLOSE_TO_OPEN_RATIO


## Включить/выключить шумоподавление (RNNoise) на передаче, живьём. RNNoise-состояние заводится
## в семплере энкодера (create_sampler), поэтому смену флага делаем пересозданием энкодера.
## Накопитель сбрасываем — у нового энкодера свой ресемпл/состояние. Работает только при
## OPUS_RATE == 48000 (см. VoiceCodec); иначе аддон просто не применит денойз.
func set_denoise(enabled: bool) -> void:
	if _denoise == enabled:
		return
	_denoise = enabled
	if _encoder == null:
		return
	_encoder = VoiceCodec.make_encoder(_rate, _denoise)
	if _encoder != null:
		_enc_chunk_in = _encoder.calc_audio_chunk_size(VoiceCodec.OPUS_CHUNK_SIZE)
	_enc_accum.clear()


func is_speaking() -> bool:
	return _speaking


# --- Выбор входного устройства ---

func input_device_list() -> PackedStringArray:
	return AudioServer.get_input_device_list()


func current_input_device() -> String:
	return AudioServer.input_device


func input_mix_rate() -> float:
	return _rate


## Переключить вход на устройство по имени. Пустое/неизвестное → "Default".
func apply_input_device(device_name: String) -> void:
	AudioServer.input_device = device_name if device_name != "" else "Default"
	# Запускаем проверку нового входа: ждём первых кадров захвата. Их отсутствие при активном
	# микрофоне = драйвер не отдаёт звук с этого устройства (краш -10863 под частотой/режимом,
	# отличными от инициализации). Тогда _check_input_device шлёт input_device_failed → UI просит
	# перезапуск. Частоту устройства из GDScript достоверно не прочитать (get_input_mix_rate
	# баговый), поэтому ловим следствие — «тишину». См. docs/godot-coreaudio-input-rate-bug.md.
	_check_device = AudioServer.input_device
	_check_elapsed = 0.0
	_check_frames = 0


# --- Мониторинг (проверка микрофона) ---

func set_monitoring(enabled: bool, loopback: bool = false) -> void:
	_monitoring = enabled
	_loopback = loopback
	if not enabled:
		_level = 0.0


func is_monitoring() -> bool:
	return _monitoring


func input_level() -> float:
	return _level


# --- Захват ---

func _setup_capture() -> void:
	_rate = AudioServer.get_mix_rate()
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

	# Opus-энкодер: сам ресемплит захват (_rate) → VoiceCodec.OPUS_RATE, поэтому свой LinearResampler
	# на передаче больше не нужен. _enc_chunk_in — сколько кадров входа уходит на один Opus-кадр.
	# denoise (RNNoise) зашит в семплер энкодера — читаем стартовое значение из Settings.
	_denoise = Settings.voice_denoise
	_encoder = VoiceCodec.make_encoder(_rate, _denoise)
	if _encoder != null:
		_enc_chunk_in = _encoder.calc_audio_chunk_size(VoiceCodec.OPUS_CHUNK_SIZE)
	else:
		push_warning("Opus недоступен: положите аддон twovoip в addons/twovoip — голос не будет кодироваться")

	# Локальный loopback-плеер (для «слышать себя»): генератор на частоте микшера.
	# Буфер с запасом (0.4 с) — Bluetooth-вывод даёт высокую/рваную задержку, на коротком
	# буфере генератор недобирает (underrun).
	_monitor_player = AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _rate
	gen.buffer_length = 0.4
	_monitor_player.stream = gen
	add_child(_monitor_player)
	_monitor_player.play()
	_monitor_pb = _monitor_player.get_stream_playback()


## Нужно ли вообще захватывать микрофон: онлайн, голос включён, не заглушены. БЕЗ требования
## пира — захват нужен и в одиночку, чтобы VAD и уровень входа кормили «рот» аватара в зеркале
## (LocalAvatar). В эфир при этом не шлём (см. _want_send).
func _want_capture() -> bool:
	return Settings.voice_enabled \
		and not muted \
		and NetworkManager.is_online()


## Нужно ли слать кадры в сеть: захват плюс есть кому слать. В одиночку захватываем (для
## зеркала), но не кодируем/не отправляем.
func _want_send() -> bool:
	return _want_capture() and NetworkManager.peer_count() > 0


func _process(delta: float) -> void:
	if _mic_player == null:
		return
	var send := _want_send()
	var want := _want_capture() or _monitoring
	if want != _mic_player.playing:
		if want:
			_mic_player.play()
		else:
			_mic_player.stop()
			_enc_accum.clear()
			_set_speaking(false)
			_level = 0.0
			_check_device = ""   # захват остановлен — проверку входа отменяем
	if not want or _capture == null:
		return

	var avail := _capture.get_frames_available()
	_check_input_device(avail, delta)
	if avail <= 0:
		_decay_level(delta)
		return
	var stereo := _capture.get_buffer(avail)
	var mono := _downmix(stereo)
	_update_level(mono, delta)
	_update_vad(mono, delta)

	# «Слышать себя»: вход в loopback-плеер (на частоте микшера, без ресемпла).
	if _monitoring and _loopback and _monitor_pb != null:
		var room := _monitor_pb.get_frames_available()
		var m := mini(mono.size(), room)
		for i in m:
			_monitor_pb.push_frame(Vector2(mono[i], mono[i]))

	# Сетевой путь: пока есть кому слать (непрерывная фаза) — кормим энкодер кадрами захвата,
	# в эфир кладём Opus-пакеты только во время речи. В одиночку (send=false) не кодируем —
	# захват идёт лишь ради зеркала. Энкодер сам ресемплит и буферизует, см. _feed_encoder.
	if send and _encoder != null:
		_feed_encoder(mono)
	else:
		_enc_accum.clear()


## Кормит Opus-энкодер моно-кадрами захвата (как Vector2(m,m) на _rate — усиление уже в mono).
## Энкодер принимает вход ровно по _enc_chunk_in кадров на один Opus-кадр: копим в _enc_accum и
## отдаём порциями. process_pre_encoded_chunk ресемплит и буферизует ВСЕГДА (непрерывность ресемпла
## и lead-in), а encode_chunk/отправку делаем только пока открыт VAD. Перед первым кадром речи
## энкодер сброшен в _set_speaking — приёмник начинает поток «с чистого листа».
func _feed_encoder(mono: PackedFloat32Array) -> void:
	for s in mono:
		_enc_accum.push_back(Vector2(s, s))
	while _enc_accum.size() >= _enc_chunk_in:
		var chunk := _enc_accum.slice(0, _enc_chunk_in)
		_enc_accum = _enc_accum.slice(_enc_chunk_in)
		_encoder.process_pre_encoded_chunk(chunk, VoiceCodec.OPUS_CHUNK_SIZE, _denoise, false)
		if _speaking:
			var pkt: PackedByteArray = _encoder.encode_chunk(_OPUS_PREFIX, 1.0)
			if not pkt.is_empty():
				NetworkManager.send_voice(pkt)


## Стерео-буфер захвата → моно с усилением.
func _downmix(stereo: PackedVector2Array) -> PackedFloat32Array:
	var mono := PackedFloat32Array()
	mono.resize(stereo.size())
	for i in stereo.size():
		var f := stereo[i]
		mono[i] = (f.x + f.y) * 0.5 * _input_gain
	return mono


## Уровень входа для индикатора. Берём RMS (та же величина, с которой VAD сравнивает порог) —
## чтобы индикатор и метка порога были в одной шкале, а усиление сказывалось линейно (а не
## упиралось в потолок, как пик). Атака мгновенная, спад плавный (LEVEL_DECAY).
func _update_level(mono: PackedFloat32Array, delta: float) -> void:
	var rms := _rms(mono)
	if rms >= _level:
		_level = rms
	else:
		_level = maxf(rms, _level - LEVEL_DECAY * delta)


## RMS амплитуды буфера [0..]. Усиление уже учтено (mono приходит из _downmix).
func _rms(mono: PackedFloat32Array) -> float:
	if mono.is_empty():
		return 0.0
	var sum_sq := 0.0
	for s in mono:
		sum_sq += s * s
	return sqrt(sum_sq / float(mono.size()))


func _decay_level(delta: float) -> void:
	_level = maxf(0.0, _level - LEVEL_DECAY * delta)


## Проверка только что выбранного входа: ждём кадры захвата. Отсутствие кадров за INPUT_CHECK_GRACE
## при активном микрофоне = драйвер не отдаёт звук с устройства (краш -10863 в CoreAudio под
## частотой/режимом, отличными от инициализации). Таймер копится только пока идёт захват (вызов из
## _process после проверки want) — иначе «тишина» от неактивного микрофона дала бы ложное
## срабатывание. Ловим следствие, а не сам rate: частоту устройства из GDScript достоверно не
## прочитать (get_input_mix_rate баговый). NB: кейс «робовойса» сюда не попадает — там кадры идут,
## просто искажённые. Подробно — docs/godot-coreaudio-input-rate-bug.md.
func _check_input_device(avail: int, delta: float) -> void:
	if _check_device == "":
		return
	_check_elapsed += delta
	_check_frames += avail
	if _check_frames > 0:
		_check_device = ""          # устройство отдаёт звук — всё в порядке
	elif _check_elapsed >= INPUT_CHECK_GRACE:
		var failed := _check_device
		_check_device = ""
		input_device_failed.emit(failed)


## VAD: считаем RMS кадра и ведём состояние речи с гистерезисом и удержанием.
func _update_vad(mono: PackedFloat32Array, delta: float) -> void:
	if mono.is_empty():
		return
	var rms := _rms(mono)
	if _speaking:
		if rms < _vad_close:
			_silence_sec += delta
			if _silence_sec >= HOLD_SEC:
				_set_speaking(false)
		else:
			_silence_sec = 0.0
	elif rms >= _vad_open:
		_set_speaking(true)
		_silence_sec = 0.0


func _set_speaking(value: bool) -> void:
	if _speaking == value:
		return
	_speaking = value
	# На старте речи сбрасываем энкодер: каждый «спурт» уходит в эфир самостоятельным Opus-потоком
	# (приёмник AudioStreamOpus начинает декод с чистого состояния, без хвостов прошлой фразы).
	if value and _encoder != null:
		_encoder.reset_opus_encoder()
	local_speaking_changed.emit(value)
