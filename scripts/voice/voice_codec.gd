class_name VoiceCodec
extends RefCounted

## Кодек голоса — граница, за которой прячется представление аудио «на проводе».
## Сейчас это **Opus** через нативный аддон twovoip (addons/twovoip): libopus, собранный
## GDExtension'ом под все платформы (вкл. web/wasm). До этого был сырой PCM16 — см. git-лог и
## docs/voice-chat.md, где описан этот переход и зачем он (PCM16 24 кГц ≈ 384 кбит/с против
## ~20 кбит/с у Opus, плюс FEC/PLC).
##
## ВАЖНО: API twovoip не «чистая функция encode/decode». Энкодер (TwovoipOpusEncoder)
## stateful, сам ресемплит вход→OPUS_RATE и принимает кадры порциями (process+encode).
## Декодер существует ТОЛЬКО как AudioStreamOpus (полноценный AudioStream) — отдельной
## «decode → семплы» нет. Поэтому VoiceCodec теперь не кодирует сам, а:
##   • держит единый источник истины по параметрам Opus (частота/каналы/битрейт/кадр);
##   • отдаёт сконфигурированные энкодер (make_encoder) и поток-декодер (make_stream).
## Энкодер живёт в VoiceManager; AudioStreamOpus вешается на капсулу пира (VoicePlayback,
## AudioStreamPlayer3D — так сохраняется пространственность). См. docs/voice-chat.md.
##
## Классы аддона резолвятся через ClassDB (как WebRTC в NetworkManager): без статической
## типизации, чтобы автолоад/сцены парсились даже в сборке без аддона. Доступность — opus_available().

const ENCODER_CLASS := "TwovoipOpusEncoder"
const STREAM_CLASS := "AudioStreamOpus"

## Частота голосового тракта Opus. 48 кГц — ОБЯЗАТЕЛЬНО для денойза: RNNoise в twovoip
## включается только при opus_sample_rate == 48000 и НЕ ресемплит внутри (см. make_encoder и
## opus_encoder_object.cpp в аддоне). Раньше было 24 кГц (компромисс «речь/трафик/CPU»), но
## трафик ограничен BITRATE и от частоты почти не зависит — подъём до 48 кГц стоит лишь немного
## CPU. Протокол у нас фиксированной частоты (пакеты без заголовков на поток), поэтому частота
## общая для всех: и энкодер, и декодер берут OPUS_RATE. Энкодер ресемплит сюда захват с частоты
## микшера; аудиосервер доресемплит выход к микшеру.
const OPUS_RATE := 48000
## Моно: голос не нуждается в стерео, а 1 канал вдвое дешевле по битрейту.
const OPUS_CHANNELS := 1
## Длительность кадра, мс. 40 мс → 25 пакетов/с (как было на PCM): крупнее — меньше накладных
## расходов RPC, мельче — ниже задержка. Opus допускает до 60 мс.
const FRAME_MS := 40
## Размер кадра в семплах ВЫХОДА (opus-частоты): 48000×40/1000 = 1920. Передаётся в
## process_pre_encoded_chunk как opus_chunk_size. Кратен кадру RNNoise (480) — денойз применим.
@warning_ignore("integer_division")
const OPUS_CHUNK_SIZE := OPUS_RATE * FRAME_MS / 1000
## Целевой битрейт энкодера (бит/с). ~20 кбит/с — внятная речь; ~×19 легче прежнего PCM16.
const BITRATE := 20000
## Сложность кодирования Opus (0..10): компромисс CPU/качество. 5 — как в примере аддона.
const COMPLEXITY := 5
## Подсказка кодеку оптимизироваться под голос (SILK/VOIP-режим).
const OPTIMIZE_FOR_VOICE := true
## Длина буфера декодера (с) — джиттер-буфер AudioStreamOpus, сглаживает неравномерность сети.
const STREAM_BUFFER_SEC := 0.5


## Доступен ли нативный Opus-аддон (twovoip). Без него голос не кодируется/не воспроизводится,
## но проект работает (как и без webrtc-native). Голос всё равно требует онлайна и WebRTC.
static func opus_available() -> bool:
	return ClassDB.class_exists(ENCODER_CLASS) and ClassDB.class_exists(STREAM_CLASS)


## Создать и сконфигурировать Opus-энкодер под наш тракт. input_rate — частота захвата
## (= AudioServer.get_mix_rate(), на ней приходят кадры с шины). Внутренний ресемплер аддона
## приводит её к OPUS_RATE. denoise — включить RNNoise (4-й аргумент create_sampler заводит
## rnnoise-состояние; реально применяется по флагу в process_pre_encoded_chunk). Работает только
## при OPUS_RATE == 48000. Смена denoise требует пересоздания энкодера. null, если аддон недоступен.
static func make_encoder(input_rate: float, denoise := false):
	if not opus_available():
		return null
	var enc = ClassDB.instantiate(ENCODER_CLASS)
	enc.create_sampler(int(input_rate), OPUS_RATE, OPUS_CHANNELS, denoise)
	enc.create_opus_encoder(BITRATE, COMPLEXITY, OPTIMIZE_FOR_VOICE)
	return enc


## Создать и сконфигурировать AudioStreamOpus для воспроизведения потока одного пира.
## Вешается на AudioStreamPlayer3D (VoicePlayback). Возвращает null, если аддон недоступен.
static func make_stream():
	if not opus_available():
		return null
	var stream = ClassDB.instantiate(STREAM_CLASS)
	stream.opus_sample_rate = OPUS_RATE
	stream.opus_channels = OPUS_CHANNELS
	stream.buffer_length = STREAM_BUFFER_SEC
	return stream
