class_name AvatarParams
extends RefCounted

## Контракт параметров аватара — общий словарь имён сигналов между источником (что
## излучает игрок) и аватаром (как он это отображает). Имена и типы выровнены по
## встроенным параметрам аниматора VRChat (https://creators.vrchat.com/avatars/animator-parameters/),
## чтобы система была привычной и заранее готовой под расширение.
##
## Контракт — единственная связь между источником и аватаром: они не ссылаются друг на
## друга, общаются только через AvatarParameters по этим именам. Подробности и гайд «как
## добавить параметр / написать свой аватар» — в docs/avatars.md.

## Версия набора параметров (аналог VRChat AvatarVersion). Поднимать при несовместимой
## смене контракта — аватар может проверить AVATAR_VERSION и не ломаться на чужой версии.
const VERSION := 1

# --- Группа A: производятся сейчас (network-owned или local-context) ---

## Наклон взгляда (рад): >0 вверх, <0 вниз. Наш сигнал — у VRChat голова идёт через
## трекинг, отдельного параметра нет.
const LOOK_PITCH := &"LookPitch"
## true на аватаре, который «носит» локальный игрок; false на чужих капсулах.
const IS_LOCAL := &"IsLocal"
## Громкость голоса 0..1. Источник истины локален для наблюдателя: свой микрофон либо
## декодированное аудио удалённого игрока. В state snapshot не передаётся.
const VOICE := &"Voice"
## Касается ли тело земли (CharacterBody3D.is_on_floor()).
const GROUNDED := &"Grounded"
## Скорость в локальных осях тела (м/с). X — вбок, Y — вверх, Z — вперёд(−)/назад(+).
const VELOCITY_X := &"VelocityX"
const VELOCITY_Y := &"VelocityY"
const VELOCITY_Z := &"VelocityZ"
## Модуль скорости (м/с).
const VELOCITY_MAGNITUDE := &"VelocityMagnitude"
## Угловая скорость вокруг Y (рад/с) — как быстро поворачивается корпус.
const ANGULAR_Y := &"AngularY"
## Производный флаг движения (VELOCITY_MAGNITUDE > порога) — наша добавка сверх VRChat
## для удобства простых аватаров.
const MOVING := &"Moving"

# --- Группа B: заложены в контракт с дефолтами (пока статичны, оживут позже) ---

## Поза 0..1 (0 — лёжа, 1 — стоя). Приседаний/полёта-ничком пока нет → дефолт 1.0.
const UPRIGHT := &"Upright"
## 1 — VR, 0 — десктоп. Сейчас только десктоп → дефолт 0.
const VR_MODE := &"VRMode"
## Игрок замьютил себя.
const MUTE_SELF := &"MuteSelf"
## Игрок отошёл (AFK).
const AFK := &"AFK"
## Сидит (в «станции»).
const SEATED := &"Seated"
## Находится в станции.
const IN_STATION := &"InStation"
## Версия контракта конкретного аватара/источника (значение — VERSION).
const AVATAR_VERSION := &"AvatarVersion"

# --- Группа C: резерв имён под будущее (нет инпутов — не производим, только forward-compat) ---

const VISEME := &"Viseme"
const GESTURE_LEFT := &"GestureLeft"
const GESTURE_RIGHT := &"GestureRight"
const GESTURE_LEFT_WEIGHT := &"GestureLeftWeight"
const GESTURE_RIGHT_WEIGHT := &"GestureRightWeight"
const TRACKING_TYPE := &"TrackingType"
const EARMUFFS := &"Earmuffs"
const IS_ON_FRIENDS_LIST := &"IsOnFriendsList"
const PREVIEW_MODE := &"PreviewMode"
const IS_ANIMATOR_ENABLED := &"IsAnimatorEnabled"
const SCALE_MODIFIED := &"ScaleModified"
const SCALE_FACTOR := &"ScaleFactor"
const SCALE_FACTOR_INVERSE := &"ScaleFactorInverse"
const EYE_HEIGHT_METERS := &"EyeHeightAsMeters"
const EYE_HEIGHT_PERCENT := &"EyeHeightAsPercent"

# --- Владение значением / транспорт ---

## Эти параметры принадлежат контексту принимающего клиента. Они не отправляются в state
## snapshot и игнорируются, если старый/недоверенный клиент всё же прислал их. Такой registry
## позволяет позже перевести сюда Grounded или другой параметр без изменения RPC/VRWML.
const LOCAL_CONTEXT_PARAMS := {
	IS_LOCAL: true,
	VOICE: true,
}

## Скорость (м/с), ниже которой считаем игрока стоящим (для MOVING).
const MOVING_EPSILON := 0.1

## Множитель RMS амплитуды → VOICE [0..1]. Речь по RMS обычно ~0.05..0.2; домножаем, чтобы
## нормальная громкость уезжала к 1.0 (результат всё равно клампим). Один на оба источника
## VOICE — приём (VoicePlayback, чужие капсулы) и локальный mirror (AvatarParameterSource), —
## чтобы «рот» вёл себя одинаково у себя в зеркале и у других.
const VOICE_RMS_GAIN := 6.0


## Безопасные начальные значения для всех параметров, которые читаются в проекте (группы
## A и B). Шина инициализируется отсюда, чтобы get_value всегда возвращал значение нужного
## типа, даже если источник ещё не прислал свой первый снимок.
static func defaults() -> Dictionary:
	return {
		# Группа A
		LOOK_PITCH: 0.0,
		IS_LOCAL: false,
		VOICE: 0.0,
		GROUNDED: true,
		VELOCITY_X: 0.0,
		VELOCITY_Y: 0.0,
		VELOCITY_Z: 0.0,
		VELOCITY_MAGNITUDE: 0.0,
		ANGULAR_Y: 0.0,
		MOVING: false,
		# Группа B
		UPRIGHT: 1.0,
		VR_MODE: 0,
		MUTE_SELF: false,
		AFK: false,
		SEATED: false,
		IN_STATION: false,
		AVATAR_VERSION: VERSION,
	}


## Сетевое представление шины: сохраняет network-owned и неизвестные extension-параметры,
## но удаляет всё, чьим источником истины является принимающий клиент.
static func network_snapshot(values: Dictionary) -> Dictionary:
	var result := values.duplicate()
	for pname in LOCAL_CONTEXT_PARAMS:
		result.erase(pname)
	return result


static func is_local_context(pname: StringName) -> bool:
	return LOCAL_CONTEXT_PARAMS.has(pname)
