class_name VoiceCodec
extends RefCounted

## Кодек голоса — граница, за которой прячется представление аудио «на проводе».
## Сейчас это сырой PCM16 (моно, VOICE_RATE Гц): float-семплы [-1;1] квантуются в int16
## little-endian. Заведомо неэффективно (см. docs/voice-chat.md), но без зависимостей и
## целиком на GDScript — это намеренный первый шаг.
##
## Контракт сделан под будущую замену на Opus: у энкодера/декодера может появиться
## внутреннее состояние (Opus его требует — FEC/PLC), поэтому это инстанс-класс, а не
## статические функции. VoiceManager держит один энкодер; каждая капсула (поток пира) —
## свой декодер. Чтобы перейти на Opus, достаточно подменить тело encode/decode и константы,
## не трогая транспорт и захват.

## Частота дискретизации голосового тракта. 24 кГц — компромисс «разборчивость/трафик»:
## речь до ~12 кГц передаётся, а поток вдвое легче 48 кГц. И захват, и воспроизведение
## ресемплятся к этой частоте.
const RATE := 24000
## Длина кадра в семплах. 40 мс при RATE → 960 семплов на пакет (25 пакетов/с): крупнее
## — меньше накладных расходов RPC, мельче — ниже задержка. См. расчёты в доке.
const FRAME_SAMPLES := 960
## Целевой размер пакета PCM16 (байт) — для справки/проверок: 2 байта на семпл.
const FRAME_BYTES := FRAME_SAMPLES * 2


## Кодирует кадр моно-семплов [-1;1] @ RATE в байты «провода» (PCM16 LE).
func encode(mono: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(mono.size() * 2)
	for i in mono.size():
		var s := int(round(clampf(mono[i], -1.0, 1.0) * 32767.0))
		out.encode_s16(i * 2, s)
	return out


## Декодирует байты «провода» обратно в моно-семплы [-1;1] @ RATE.
func decode(payload: PackedByteArray) -> PackedFloat32Array:
	var n := payload.size() / 2
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = float(payload.decode_s16(i * 2)) / 32767.0
	return out
