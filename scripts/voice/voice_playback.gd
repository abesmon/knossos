class_name VoicePlayback
extends AudioStreamPlayer3D

## Воспроизведение голоса одного пира — пространственно, из позиции его капсулы.
## Принимает Opus-пакеты (twovoip) и скармливает их AudioStreamOpus — это нативный AudioStream,
## который декодирует Opus сам; повешен прямо на этот AudioStreamPlayer3D, поэтому декод и
## пространственность «бесплатно» совмещены. Внутренний буфер потока (VoiceCodec.STREAM_BUFFER_SEC)
## работает джиттер-буфером. Отдельного «декодера в семплы» у аддона нет — см. docs/voice-chat.md.
##
## Адаптивного джиттер-буфера, переупорядочивания и FEC здесь нет (пакеты идут без порядковых
## номеров, lenchunkprefix=0) — осознанное упрощение: потерянный пакет даёт короткий разрыв.
## twovoip это умеет (sequence-префикс + out-of-order + pitch-compensation), вынесено в «дальше».

## «Говорит» переключилось — капсула подсвечивает неймплейт.
signal speaking_changed(speaking: bool)

## Считаем пира говорящим, пока пакеты приходили не позже этого порога назад.
const SPEAKING_TIMEOUT_MSEC := 250
## Скорость спада уровня голоса (ед./с): атака мгновенная (по громкости кадра), спад плавный,
## чтобы между пакетами «рот» не схлопывался в ноль.
const VOICE_DECAY := 8.0
## Сколько секунд звука накопить в джиттер-буфере, ПРЕЖДЕ чем снять воспроизведение с паузы.
## AudioStreamPlaybackOpus после play() стартует В ПАУЗЕ (см. пример twovoip two_voip_speaker):
## пакеты копятся, get_chunk_max() уже видит декод (рот шевелится, неймплейт моргает), но на
## выход не идёт ничего, пока не вызвать mark_end_opus_stream(true). См. docs/voice-chat.md.
const START_BUFFER_SEC := 0.2

var _stream_playback = null   # AudioStreamPlaybackOpus (untyped: класс из аддона, см. VoiceCodec)
var _last_push_msec := -1000000
var _speaking := false
var _unpaused := false     # сняли ли текущий поток с паузы (mark_end_opus_stream(true))
var _voice_level := 0.0   # сглаженная громкость [0..1] для параметра аватара VOICE


func _ready() -> void:
	# Голос пиров идёт на отдельную шину «Voice» — её громкость регулируется отдельным
	# ползунком в настройках (см. default_bus_layout.tres, docs/audio.md).
	bus = &"Voice"
	# Чуть «дальнобойнее» дефолта, чтобы голос был слышен через комнату, но оставался
	# направленным (затухание с расстоянием сохраняет ощущение, кто где).
	unit_size = 6.0
	max_distance = 0.0   # 0 — без жёсткого обрезания по дальности
	stream = VoiceCodec.make_stream()
	if stream != null:
		play()
		_stream_playback = get_stream_playback()


## Принять Opus-кадр от пира: дослать в декодирующий поток. Если поток перестал играть
## (опустошился между фразами) — перезапускаем перед отправкой. Громкость для «рта» берём из
## get_chunk_max() в _process (своих семплов у нас нет — декод внутри AudioStreamOpus).
func push(payload: PackedByteArray) -> void:
	if _stream_playback == null:
		return
	if not playing:
		play()
		_stream_playback = get_stream_playback()
		_unpaused = false
	# lenchunkprefix=0 (без порядкового префикса), fec=0 (без восстановления потерь) — см. заголовок.
	_stream_playback.push_opus_packet(payload, 0, 0)
	_last_push_msec = Time.get_ticks_msec()
	# Поток стартует в паузе — снимаем с неё, когда в буфере набралось START_BUFFER_SEC звука.
	# Без этого пакеты копятся, но на выход ничего не идёт (см. START_BUFFER_SEC).
	if not _unpaused:
		var queued: float = _stream_playback.queue_length_frames() / float(VoiceCodec.OPUS_RATE)
		if queued >= START_BUFFER_SEC:
			_stream_playback.mark_end_opus_stream(true)
			_unpaused = true
	_set_speaking(true)


## Текущая сглаженная громкость голоса [0..1] — RemotePlayer кладёт её в параметр VOICE,
## чтобы аватар анимировал «рот». 0, пока пир молчит.
func current_level() -> float:
	return _voice_level


func _process(delta: float) -> void:
	if _speaking and Time.get_ticks_msec() - _last_push_msec > SPEAKING_TIMEOUT_MSEC:
		_set_speaking(false)
		# Конец «спурта»: передатчик сбрасывает энкодер на каждой фразе (новый Opus-поток), поэтому
		# пере-армим паузу — следующая фраза снова добирает START_BUFFER_SEC перед стартом.
		if _stream_playback != null and _unpaused:
			_stream_playback.mark_end_opus_stream(false)
			_unpaused = false
	# Громкость текущего декодируемого кадра (пик [0..1]) → уровень «рта». Домножаем, как раньше
	# RMS (VOICE_RMS_GAIN), и клампим. Атака мгновенная (max), спад плавный (VOICE_DECAY).
	if _stream_playback != null and _speaking:
		var peak: float = _stream_playback.get_chunk_max()
		_voice_level = maxf(_voice_level, clampf(peak * AvatarParams.VOICE_RMS_GAIN, 0.0, 1.0))
	_voice_level = maxf(0.0, _voice_level - VOICE_DECAY * delta)


func _set_speaking(value: bool) -> void:
	if _speaking == value:
		return
	_speaking = value
	speaking_changed.emit(value)
