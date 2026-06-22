# Godot · macOS CoreAudio: входной AudioUnit не переконфигурируется под новую частоту устройства

> **Назначение документа.** Это самодостаточный баг-репорт + руководство по исправлению
> **внутри движка Godot** (драйвер CoreAudio на macOS). Для понимания и починки **не нужно**
> ничего знать о каком-либо прикладном проекте — всё описано в терминах самого движка.
> Документ можно принести в отдельную сессию по правке исходников Godot.

---

## TL;DR

На macOS драйвер CoreAudio конфигурирует **входной** `AudioUnit` частотой дискретизации, считанной
**один раз** в момент инициализации входа. Если затем фактическая частота устройства меняется
(переключение на другой входной девайс с другой частотой **или** изменение `nominal sample rate`
текущего девайса в рантайме — типичный случай для Bluetooth-гарнитуры, переходящей из профиля
A2DP в HFP), драйвер этого **не отслеживает и не переинициализирует** входной `AudioUnit`. Формат
потока остаётся старым, и возникает один из двух симптомов:

1. `AudioUnitRender failed, code: -10863` в `input_callback` — захват полностью ломается;
2. либо рендер «проходит», но сэмплы интерпретируются на неверной частоте → звук звучит
   ускоренно/искажённо («робовойс», эффект talkbox).

**Где чинить:** `drivers/coreaudio/audio_driver_coreaudio.mm`. Нужно добавить слушатель
`kAudioDevicePropertyNominalSampleRate` на входное устройство и пересобирать входной `AudioUnit`
(с перечитыванием реальной частоты) при смене частоты/устройства.

**Апстрим-трекинг:** [godotengine/godot#106397](https://github.com/godotengine/godot/issues/106397)
(открыт, без PR на момент написания).

---

## Затронутые версии и платформа

- **Платформа:** macOS (драйвер `coreaudio`). Аналогичный по структуре код есть для iOS
  (`AVAudioSession`), но репорт и проверка — про macOS.
- **Версии:** воспроизводится в 4.3.stable … 4.5.dev и в 4.6 (исправления не было). Корень кода
  одинаков во всех этих ветках.
- **Файл:** `drivers/coreaudio/audio_driver_coreaudio.mm` (+ заголовок
  `drivers/coreaudio/audio_driver_coreaudio.h`).

---

## Краткий ликбез по железу (зачем частота вообще «прыгает»)

Есть два независимых пути, на которых частота входного устройства может разойтись с тем, что
драйвер запомнил на старте:

1. **Смена входного устройства.** Пользователь/приложение выбирает другой микрофон. У встроенного
   микрофона MacBook обычно 44100/48000, у внешнего USB/Bluetooth-устройства может быть иначе.

2. **Смена режима того же устройства (классический Bluetooth).** У BT-гарнитуры два
   взаимоисключающих профиля:
   - **A2DP** — качественный *только выход*, обычно 44100, **микрофона нет**;
   - **HFP/HSP** — двусторонний (микрофон + выход), но деградированный: **16000 Гц, моно**.

   Как только *любое* приложение открывает **микрофон** BT-гарнитуры, macOS переводит **всю**
   гарнитуру в HFP: и микрофон, и выход уходят в 16000. Пока микрофон активен, обратно в 44100
   вернуть нельзя; после деактивации устройство возвращается в A2DP. Это поведение классического
   Bluetooth, общее для всей системы (так же ведут себя AirPods в Zoom/Discord).

   **Важно:** деградация качества BT-микрофона (16k моно) и падение качества BT-выхода в момент
   активации микрофона — это **физика Bluetooth, не баг Godot и не чинится никаким софтом** (см.
   раздел «Что НЕ входит в этот фикс»). Баг Godot — лишь в том, что драйвер не подстраивается под
   сменившуюся частоту и из-за этого *дополнительно* ломается крашем/робовойсом поверх и без того
   ограниченного железа.

В обоих путях итог одинаков: **фактическая частота входа отличается от той, под которую собран
`AudioUnit`**, а драйвер этого не замечает.

---

## Симптомы (наблюдаемое поведение)

Поведение зависит от того, **с каким частотным режимом входное устройство было на момент
инициализации драйвера**, и от того, в какую сторону потом «прыгнула» частота:

| Состояние на старте | Переключаемся на… | Что происходит |
|---|---|---|
| Драйвер инициализирован на **низкой** частоте (напр. BT-микрофон 16000) | вход с **более высокой** частотой (встроенный микрофон 44100/48000) | рендер проходит, но сэмплы трактуются как 16000 → **робовойс/ускорение** |
| Драйвер инициализирован на **высокой** частоте (напр. встроенный микрофон 48000) | вход с **более низкой** частотой (BT-микрофон в HFP 16000) | **`AudioUnitRender failed, code: -10863`** в `input_callback`, захват ломается |

Сигнатура краша в логе:

```
E  input_callback: AudioUnitRender failed, code: -10863
   drivers/coreaudio/audio_driver_coreaudio.mm @ input_callback()
```

`-10863` = `kAudioUnitErr_CannotDoInCurrentContext` — типичный признак того, что текущий формат/
конфигурация `AudioUnit` несовместимы с фактическим состоянием устройства.

---

## Корневая причина (с точными ссылками на код)

Все идентификаторы ниже — из `drivers/coreaudio/audio_driver_coreaudio.mm` (Godot 4.6).

### 1. Частота читается один раз — в `init_input_device()`

```c
// Error AudioDriverCoreAudio::init_input_device()
double hw_mix_rate;
UInt32 hw_mix_rate_size = sizeof(hw_mix_rate);
AudioObjectPropertyAddress property_sr = {
    kAudioDevicePropertyNominalSampleRate,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};
result = AudioObjectGetPropertyData(device_id, &property_sr, 0, nullptr,
    &hw_mix_rate_size, &hw_mix_rate);
...
capture_mix_rate = hw_mix_rate;   // <-- запомнили частоту; больше не обновляется
```

`capture_mix_rate` далее закладывается в `AudioStreamBasicDescription` входного `AudioUnit`
(`input_unit`) и в размеры буферов. После выхода из `init_input_device()` это значение нигде не
пересматривается.

### 2. Нет слушателя на изменение частоты устройства

Драйвер регистрирует слушатели **только на смену устройства по умолчанию**, но **не** на изменение
частоты:

```c
// есть:
AudioObjectAddPropertyListener(kAudioObjectSystemObject, &prop,
    &input_device_address_cb,  this);   // selector: kAudioHardwarePropertyDefaultInputDevice
AudioObjectAddPropertyListener(kAudioObjectSystemObject, &prop,
    &output_device_address_cb, this);   // selector: kAudioHardwarePropertyDefaultOutputDevice

// НЕТ слушателя на:
//   kAudioDevicePropertyNominalSampleRate  (на самом входном device_id)
```

Поэтому сценарий «то же устройство сменило частоту» (Bluetooth A2DP→HFP) драйвер вообще не видит.

### 3. `set_input_device()` не пересобирает `AudioUnit`

```c
// void AudioDriverCoreAudio::set_input_device(const String &p_name)
OSStatus result = AudioUnitSetProperty(input ? input_unit : audio_unit,
    kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
    &device_id, sizeof(AudioDeviceID));
```

Меняется только текущий девайс у уже существующего `AudioUnit`. Формат потока (`capture_mix_rate`,
число каналов) и размеры буферов остаются от старого устройства. Свежий
`kAudioDevicePropertyNominalSampleRate` нового устройства **не перечитывается**, `AudioUnit` не
переинициализируется.

### 4. Место краша — `input_callback()`

```c
// OSStatus AudioDriverCoreAudio::input_callback(...)
OSStatus result = AudioUnitRender(ad->input_unit, ioActionFlags,
    inTimeStamp, inBusNumber, inNumberFrames, &bufferList);
if (result == noErr) {
    int16_t *data = (int16_t *)bufferList.mBuffers[0].mData;
    for (unsigned int i = 0; i < inNumberFrames * ad->capture_channels; i++) {
        int32_t sample = data[i] << 16;
        ad->input_buffer_write(sample);
        ...
    }
}
```

Когда формат рассинхронизирован с устройством, `AudioUnitRender` возвращает `-10863` (ветка `!= noErr`
логирует ошибку). Когда формат «совместим по типу, но не по частоте» — рендер возвращает `noErr`, но
сэмплы кладутся в `input_buffer` на неверной частоте → робовойс.

### Сводка по релевантным символам

- Функции: `init_input_device()`, `finish_input_device()`, `input_start()`, `input_stop()`,
  `input_callback()`, `set_input_device()`.
- Колбэки слушателей: `input_device_address_cb`, `output_device_address_cb`.
- Поля: `input_unit`, `capture_mix_rate`, `capture_channels`, `capture_buffer_frames`,
  `buffer_size`; запись в кольцевой буфер — `input_buffer_write()` (унаследовано).

---

## Как воспроизвести (без какого-либо прикладного проекта)

Нужны: Mac и **два входных устройства с разной частотой** — проще всего встроенный микрофон
(44100/48000) и Bluetooth-гарнитура (в HFP — 16000). Подойдёт и любой USB-интерфейс с иной частотой.

В `project.godot` включить вход:

```ini
[audio]
driver/enable_input=true
```

Минимальная сцена с таким скриптом на корневом `Node`:

```gdscript
extends Node

var player: AudioStreamPlayer
var capture: AudioEffectCapture

func _ready() -> void:
    # отдельная заглушённая шина с эффектом захвата
    var bus := AudioServer.bus_count
    AudioServer.add_bus(bus)
    AudioServer.set_bus_name(bus, "Capture")
    AudioServer.set_bus_mute(bus, true)
    capture = AudioEffectCapture.new()
    AudioServer.add_bus_effect(bus, capture)

    player = AudioStreamPlayer.new()
    player.stream = AudioStreamMicrophone.new()
    player.bus = "Capture"
    add_child(player)
    player.play()

    print("input devices: ", AudioServer.get_input_device_list())
    print("mix_rate: ", AudioServer.get_mix_rate())

func _process(_d: float) -> void:
    # читаем захват, чтобы буфер не переполнялся
    var n := capture.get_frames_available()
    if n > 0:
        capture.get_buffer(n)

# вызвать из отладочной консоли / по кнопке для переключения входа:
func switch_to(device_name: String) -> void:
    AudioServer.input_device = device_name
```

**Сценарий A (краш `-10863`):**
1. Сделать дефолтным входом **встроенный** микрофон (48000). Запустить проект.
2. В рантайме переключить вход на **BT-микрофон** (`AudioServer.input_device = "<имя BT>"`),
   из-за чего устройство уходит в HFP 16000.
3. → В логе посыплется `AudioUnitRender failed, code: -10863`.

**Сценарий B (робовойс):**
1. Подключить BT-гарнитуру и сделать её вход дефолтным, чтобы драйвер встал на 16000. Запустить.
2. Переключить вход на **встроенный** микрофон (48000).
3. → Захваченный звук звучит ускоренно/искажённо (слышно через loopback или по спектру).

> В апстрим-issue [#106397](https://github.com/godotengine/godot/issues/106397) приложен minimal
> reproduction project со спектральным анализом — можно переиспользовать как эталон.

---

## Как починить (внутри движка)

Идея: при **любом** изменении фактической частоты входного устройства драйвер должен **перечитать**
`kAudioDevicePropertyNominalSampleRate` и **пересобрать** входной `AudioUnit` под новый формат.

### Шаг 1. Слушатель на частоту входного устройства

В момент инициализации входа (`init_input_device()`), после того как получен `device_id` входного
устройства, повесить слушатель именно на частоту этого устройства:

```c
AudioObjectPropertyAddress sr_addr = {
    kAudioDevicePropertyNominalSampleRate,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};
AudioObjectAddPropertyListener(input_device_id, &sr_addr,
    &input_sample_rate_cb, this);
```

- Хранить `input_device_id` в поле, чтобы корректно снимать слушатель в `finish_input_device()`
  через `AudioObjectRemovePropertyListener` (иначе утечка/двойная регистрация при переключениях).
- При смене устройства в `set_input_device()` слушатель надо **снять со старого** `device_id` и
  **повесить на новый**.

### Шаг 2. Колбэк переинициализации

```c
OSStatus AudioDriverCoreAudio::input_sample_rate_cb(AudioObjectID inObjectID,
        UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses,
        void *inClientData) {
    AudioDriverCoreAudio *ad = (AudioDriverCoreAudio *)inClientData;
    ad->set_input_reinit_pending();   // не делать тяжёлую работу прямо в колбэке
    return noErr;
}
```

Колбэк CoreAudio может прийти на служебном потоке — **не** пересобирать `AudioUnit` прямо в нём.
Выставить флаг/атомарный признак и выполнить реконфиг в безопасной точке (см. шаг 4).

### Шаг 3. Функция реконфигурации входа

Сделать переинициализацию входа атомарной относительно `input_callback`:

```c
void AudioDriverCoreAudio::reinit_input_device() {
    lock();                  // взять тот же мьютекс, что и обработка
    input_stop();            // AudioOutputUnitStop(input_unit)
    finish_input_device();   // AudioUnitUninitialize + снять слушатель частоты со старого device_id
    init_input_device();     // заново: перечитать nominal sample rate -> capture_mix_rate,
                             // пересобрать ASBD, буферы, повесить слушатель на новый device_id
    input_start();           // AudioOutputUnitStart(input_unit)
    unlock();
}
```

Ключевое — `init_input_device()` уже умеет читать актуальный `kAudioDevicePropertyNominalSampleRate`
и присваивать `capture_mix_rate`; задача в том, чтобы **вызывать этот путь повторно** при смене
частоты, а не один раз на старте.

### Шаг 4. Точка выполнения и защита `input_callback`

- Выполнять `reinit_input_device()` из безопасного места: либо в начале аудио-итерации драйвера
  (там, где уже берётся блокировка обработки), либо отдельным механизмом «pending → apply».
- В `input_callback` при выставленном «pending» или во время реконфига **пропускать**
  `AudioUnitRender` (ранний `return noErr` без записи в буфер), чтобы не словить `-10863` в момент
  пересборки.
- Так же дёрнуть реконфиг из `set_input_device()` (после `AudioUnitSetProperty(...CurrentDevice...)`)
  — чтобы переключение на устройство с другой частотой сразу пересобирало формат, а не полагалось
  только на слушатель частоты.

### Шаг 5. Согласование с верхним уровнем

`AudioServerinput`/ресемплинг рассчитывает на стабильный `capture_mix_rate`. После пересборки:
- убедиться, что обновлённый `capture_mix_rate` корректно используется при ресемплинге входа в
  `mix_rate` микшера (вход всегда ресемплится к частоте микшера — это и так делает движок);
- сбросить/переинициализировать кольцевой буфер входа (`input_buffer`/`buffer_size`,
  `capture_buffer_frames`), чтобы старые сэмплы на прежней частоте не смешивались с новыми;
- проверить пересчёт `capture_channels` (HFP — моно; встроенный — может быть стерео).

---

## Чек-лист тестирования

Прогнать все три комбинации на реальном железе (нужны встроенный микрофон + BT-гарнитура):

1. **Старт со встроенного входа → переключение на BT-микрофон:** раньше `-10863`; после фикса —
   чистый захват (16k моно, но без краша).
2. **Старт с BT-входа (16000) → переключение на встроенный микрофон (48000):** раньше робовойс;
   после фикса — корректная частота, нормальный звук.
3. **BT-гарнитура целиком (её микрофон + её выход) без переключений:** регрессий нет, как было.
4. **Дёрганье A2DP↔HFP в рантайме** (активация/деактивация микрофона при подключённой BT-гарнитуре):
   драйвер ловит смену частоты и пересобирается, без краша и без «застревания» формата.
5. Никаких утечек слушателей при многократных переключениях устройства (проверить парность
   add/remove по `input_device_id`).

---

## Что НЕ входит в этот фикс (важно для ожиданий)

- **Качество звука BT-микрофона.** Пока используется микрофон классической BT-гарнитуры, устройство
  работает в HFP: **16000 Гц, моно**, и выход тоже деградирует в HFP. Это ограничение Bluetooth, а
  не Godot — ни этот фикс, ни какой-либо другой софт не дадут одновременно A2DP-выход и BT-микрофон.
  Фикс лишь убирает **краш (`-10863`) и робовойс** поверх этого, делая захват корректным в рамках
  того, что отдаёт железо.
- Лучшее качество при наличии BT — комбинация «встроенный/проводной микрофон (вход) + BT-выход
  (A2DP)». Этот фикс как раз и делает **переключение в такую комбинацию в рантайме** рабочим (без
  краша/робовойса), тогда как сейчас оно требует перезапуска с нужным устройством на старте.

---

## Ссылки

- **Главный issue:** [godotengine/godot#106397 — «[macOS] AudioUnitRender errors with -10863 when
  changing to non-default audio input device»](https://github.com/godotengine/godot/issues/106397)
  (открыт; корень — sample-rate mismatch при смене устройства; PR нет; есть minimal repro).
- Связанные:
  [#58180](https://github.com/godotengine/godot/issues/58180) — `-10863` при записи (закрыт 2024,
  возможен регресс/другой путь);
  [#106904](https://github.com/godotengine/godot/issues/106904) — `-50` при записи на Mac (закрыт);
  [#64583](https://github.com/godotengine/godot/issues/64583) — микрофон не пишет на macOS (открыт).
- Упоминаемый в #106397 потенциально релевантный PR: `#88628`.
- Исходник: `drivers/coreaudio/audio_driver_coreaudio.mm` (и заголовок `.h`) в ветке `4.6`.
</content>
</invoke>
