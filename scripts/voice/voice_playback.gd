class_name VoicePlayback
extends AudioStreamPlayer3D

## Воспроизведение голоса одного пира — пространственно, из позиции его капсулы.
## Декодирует кадры VoiceCodec и скармливает их AudioStreamGenerator; внутренний буфер
## генератора (BUFFER_SEC) работает джиттер-буфером, сглаживая неравномерность прихода
## пакетов по сети. Декодер — свой на каждый поток (под будущий Opus с per-stream-состоянием).
##
## Адаптивного джиттер-буфера и компенсации потерь (PLC) здесь нет — это осознанное
## упрощение GDScript-этапа: потерянный пакет даёт короткий разрыв. См. docs/voice-chat.md.

## «Говорит» переключилось — капсула подсвечивает неймплейт.
signal speaking_changed(speaking: bool)

## Джиттер-буфер ~200 мс: компромисс «задержка/устойчивость к джиттеру».
const BUFFER_SEC := 0.2
## Считаем пира говорящим, пока кадры приходили не позже этого порога назад.
const SPEAKING_TIMEOUT_MSEC := 250

var _decoder := VoiceCodec.new()
var _playback: AudioStreamGeneratorPlayback = null
var _last_push_msec := -1000000
var _speaking := false


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(VoiceCodec.RATE)
	gen.buffer_length = BUFFER_SEC
	stream = gen
	# Голос пиров идёт на отдельную шину «Voice» — её громкость регулируется отдельным
	# ползунком в настройках (см. default_bus_layout.tres, docs/audio.md).
	bus = &"Voice"
	# Чуть «дальнобойнее» дефолта, чтобы голос был слышен через комнату, но оставался
	# направленным (затухание с расстоянием сохраняет ощущение, кто где).
	unit_size = 6.0
	max_distance = 0.0   # 0 — без жёсткого обрезания по дальности
	play()
	_playback = get_stream_playback()


## Принять голосовой кадр от пира: декодировать и дослать в генератор. Если джиттер-буфер
## переполнен (пир обогнал воспроизведение) — лишние семплы отбрасываем, держа задержку.
func push(payload: PackedByteArray) -> void:
	if _playback == null:
		return
	var mono := _decoder.decode(payload)
	var room := _playback.get_frames_available()
	var n := mini(mono.size(), room)
	for i in n:
		var s := mono[i]
		_playback.push_frame(Vector2(s, s))
	_last_push_msec = Time.get_ticks_msec()
	_set_speaking(true)


func _process(_delta: float) -> void:
	if _speaking and Time.get_ticks_msec() - _last_push_msec > SPEAKING_TIMEOUT_MSEC:
		_set_speaking(false)


func _set_speaking(value: bool) -> void:
	if _speaking == value:
		return
	_speaking = value
	speaking_changed.emit(value)
