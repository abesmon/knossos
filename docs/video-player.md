# Видео-плеер (как в VRChat)

> **Суть:** логический видео-плеер декодирует видео по ссылке в текстуру («рендер-буфер»),
> которую можно натянуть на любое число поверхностей мира. Управляется кастомными VRWeb-тегами,
> в онлайне воспроизведение синхронизируется между клиентами. Прямая аналогия —
> video-player из VRChat.

Расширение Слоя 1 ([vrweb-overview.md](vrweb-overview.md)) + Слоя 2 (синхронизация). Опирается
на тот же паттерн кастомного узла-тега, что и зеркало (`<VRWebMirror>` →
[vrweb-mirror.gd](../scripts/vrweb_mirror.gd)).

---

## Концепция: плеер ≠ поверхность

Как в VRChat, разделены **логический плеер** (что играет) и **поверхность** (где показывается):

- **`VrwebVideoPlayer`** ([scripts/vrweb_video_player.gd](../scripts/vrweb_video_player.gd)) —
  headless-узел без геометрии. Декодирует видео в текстуру (`get_video_texture()`), держит
  транспорт (play/pause/seek). Невидим сам по себе.
- **`VrwebVideoScreen`** ([scripts/vrweb_video_screen.gd](../scripts/vrweb_video_screen.gd)) —
  3D-квад, натягивающий текстуру плеера. Одну текстуру одного плеера показывают сколько угодно
  экранов (общий декод, общая память). Кликабелен лучом игрока (`interact_at`, как
  `ImagePanel`/`Portal`) → переключает play/pause.
- **`VrwebVideoManager`** ([scripts/vrweb_video_manager.gd](../scripts/vrweb_video_manager.gd)) —
  связывает плееры и экраны по `id` и синхронизирует воспроизведение по сети. Живёт в `world`,
  создаётся в [scenes/main.gd](../scenes/main.gd) (`_rebuild_world` → `scan`), при навигации
  сносится вместе с миром.

---

## Теги

```html
<!-- Простой случай: экран со своим (неявным) плеером — одного тега достаточно -->
<VRWebVideoScreen src="https://example.com/clip.mp4" size="3.2:1.8"
                  autoplay="true" loop="true"
                  transform="Transform3D(1,0,0, 0,1,0, 0,0,1, 0,2,-5)"/>

<!-- Сложный случай: один логический плеер — много поверхностей -->
<VRWebVideoPlayer id="main" src="https://example.com/clip.mp4" autoplay="true" loop="true"/>
<VRWebVideoScreen player="main" size="3.2:1.8" transform="..."/>
<VRWebVideoScreen player="main" size="1.6:0.9" transform="..."/>
```

### `<VRWebVideoPlayer>` — логический плеер (headless)

| Атрибут | Смысл |
|---|---|
| `id` | имя плеера; по нему на него ссылаются экраны и по нему идёт синхронизация |
| `src` | URL видео (http(s) или относительный/локальный vrweb-адрес, как `<img>`/`<ExtResource>`) |
| `autoplay` | `true` — стартует, как только видео готово |
| `loop` | `true` — зацикливание |
| `volume` | громкость 0..1 |

### `<VRWebVideoScreen>` — поверхность

| Атрибут | Смысл |
|---|---|
| `player` | `id` общего плеера (`<VRWebVideoPlayer>`) |
| `src` | ИЛИ свой источник — тогда создаётся **неявный** плеер (ключ по URL: одинаковый `src` = общий плеер). Поддерживает `autoplay`/`loop`/`volume` |
| `size` | `"ширина:высота"` в метрах (как у зеркала). Не задан → пропорции берутся из видео (дефолт 16:9) |
| `transform` и пр. | обычные свойства `Node3D` |

Это кастомные теги VRWeb (не классы Godot) — обрабатываются особо в
[vrweb_builder.gd](../scripts/vrweb_builder.gd), как `<VRWebMirror>`/`<ExtScene>`.

---

## Декодер: нативный аддон FFmpeg

Штатный `VideoStreamPlayer` Godot умеет **только Ogg Theora** — mp4/H.264/HLS он не декодирует.
Поэтому для реальных видео нужен GDExtension-аддон **FFmpeg** (EIRTeam `ffmpeg`), бинарники лежат
в `addons/ffmpeg/<платформа>/` (раскладка — в `addons/ffmpeg/ffmpeg.gdextension`). Аддон даёт
`VideoStream`-ресурс, работающий со **штатным** `VideoStreamPlayer`, а кадр берётся через
`get_video_texture()`. Должен резолвиться класс `FFmpegVideoStream`.

- **Windows/Linux** — готовые бинарники из релиза
  [EIRTeam/EIRTeam.FFmpeg](https://github.com/EIRTeam/EIRTeam.FFmpeg) (`win64`/`linux64`).
- **macOS** — публичного релиза **нет**, собираем сами из нашего форка
  [abesmon/EIRTeam.FFmpeg](https://github.com/abesmon/EIRTeam.FFmpeg), подключённого
  сабмодулем в [third_party/EIRTeam.FFmpeg](../third_party/EIRTeam.FFmpeg) (см. ниже).

### Сборка для macOS (из сабмодуля-форка)

ffmpeg собирается из исходников через `ffmpeg-kit` (нативного релиза под macOS нет). В нашем
форке Makefile **пропатчен на decode-only** (без энкодеров x264/x265/lame — плееру нужен только
декод; это сильно ускоряет сборку и делает её LGPL-чистой) и на `arch=arm64` для scons.

```bash
# 1. сабмодули (форк + его godot-cpp и ffmpeg-kit)
git submodule update --init --recursive third_party/EIRTeam.FFmpeg

# 2. build-тулзы (один раз): scons в venv + ffmpeg-зависимости
cd third_party/EIRTeam.FFmpeg
python3 -m venv venv && ./venv/bin/pip install scons
brew install yasm nasm meson ninja texinfo groff   # + autoconf automake libtool pkg-config

# 3. сборка arm64 (ffmpeg из исходников + расширение, ~неск. минут)
PATH="$PWD/venv/bin:/opt/homebrew/opt/texinfo/bin:$PATH" \
    make gdextension PLATFORM=macos TARGET_ARCH=arm64

# 4. разложить артефакты в аддон
ditto gdextension_build/build/addons/ffmpeg/macos ../../addons/ffmpeg/macos
```

Результат — `addons/ffmpeg/macos/`: `libgdffmpeg.macos.template_{debug,release}.framework`
(rpath ffmpeg-dylib переписаны на `@loader_path`) + шесть `lib*.dylib` (ffmpeg 60/58…).
Проверка: класс `FFmpegVideoStream` резолвится, декод mp4 в текстуру работает.

> ⚠️ `TARGET_ARCH=arm64` даёт **только Apple Silicon**. Для universal (поддержка Intel) —
> `TARGET_ARCH="arm64 x86_64"` (дольше: ffmpeg собирается под обе арки + `lipo`).
> Бинарники аддона, как и webrtc, в основной репозиторий обычно **не коммитятся**.
> Правки сборки живут в нашем форке (Makefile decode-only/arch) — их нужно закоммитить и
> запушить в `abesmon/EIRTeam.FFmpeg`, иначе при свежем `submodule update` они потеряются.

**Деградация без аддона:** `VrwebVideoPlayer.is_available()` (= `ClassDB.class_exists`,
как `NetworkManager.webrtc_available()`) ложно — плеер не стартует, экраны показывают заглушку
«▶ video unavailable», приложение работает.

### Как кадр попадает в мир

```
src URL → скачивание в user://-кэш (Sandbox.resolve) → FFmpegVideoStream.file
   → VideoStreamPlayer (в скрытом CanvasLayer, декодирует, но не рисуется на экране)
   → get_video_texture()  ── обновляется на месте ──►  albedo_texture экранов (N штук)
```

`VideoStreamPlayer` (это `Control`) держится в дереве с `visible=false` — не рисуется в 2D, но
декодирует, пока играет. ⚠️ Его **нельзя** класть в невидимый `CanvasLayer`: там проигрывание
замирает (позиция не растёт); сам по себе невидимый VSP играет нормально. Текстура кадра
обновляется на месте — поэтому раздаётся многим материалам без копий (как `AnimatedTexture` у
гифок, см. [gif-support.md](gif-support.md)).

---

## Синхронизация (Слой 2): shared-модель

Комната = страница (`PageFetcher.seed_key`), поэтому `id` плеера совпадает у всех клиентов.
Покадровый стрим невозможен (mesh p2p, только data-каналы) — **каждый клиент сам грузит тот же
URL**, синхронизируется только **состояние транспорта**.

- **Любой управляет.** Клик по экрану шлёт play/pause/seek всем — reliable-событие,
  last-writer-wins (`_recv_video_event`).
- **Таймкипер.** Источник таймкода — пир с **наименьшим id** среди подключённых
  (`NetworkManager.is_timekeeper()`): детерминированно у всех, ровно один, без переговоров.
  При его уходе роль автоматически переходит к следующему наименьшему.
- **Heartbeat.** Таймкипер ~1.5 Гц рассылает по каждому запущенному плееру **позицию + состояние
  play/pause** (`_recv_video_sync`). Остальные дрейф-корректируются: меняют play/pause при
  расхождении и делают seek, если разошлись больше `DRIFT_THRESHOLD` (0.5 c).
- **Поздний вход — решается этим же heartbeat.** Зашедший в течение `HB_INTERVAL` (~0.66 c)
  получает и состояние, и позицию — даже если в комнате `autoplay` и никто не жал play/pause.
  (Раньше без явного контроллера heartbeat не слался вовсе, и гость синхронизировался только
  при следующем ручном play/pause — это и чинит таймкипер.)
- **Анти-дребезг.** После явного действия плеер ~1 c игнорирует heartbeat (`SYNC_GRACE_MS`),
  чтобы устаревший таймкод не откатил свежий play/pause/seek, пока reliable-событие
  распространяется.
- **Офлайн** — `NetworkManager.send_*` без mesh это no-op, плеер просто играет локально.

**RPC** ([network_manager.gd](../scripts/network_manager.gd)) — по образцу `_recv_state`/`_recv_chat`:
`_recv_video_event(player_id, action, position)` (reliable: play/pause/seek) и
`_recv_video_sync(player_id, position, playing)` (unreliable_ordered: heartbeat), оба эмитят
`video_state_received(sender, player_id, action, position)` — heartbeat как `sync_play`/`sync_pause`.
Отправитель — `multiplayer.get_remote_sender_id()`; отдельный авторитет на узел не нужен.

Локальное действие → `transport_changed` (эмит) → менеджер ретранслирует; удалённое →
`apply_remote` (**без** эмита) → нет сетевого цикла.

---

## Ограничения прототипа

- **Аудио непозиционное** — играет через шину `VideoStreamPlayer`, не привязано к позиции
  экрана. 3D-аудио по позиции — позже.
- **Скачать-целиком-потом-играть** — видео качается в `user://`-кэш целиком, потом стартует
  (как `<ExtResource>`). Прогрессив/HLS/стрим — позже.
- **Дрейф-коррекция без синхронизации часов** — возраст heartbeat-пакета (≈RTT/2) не
  учитывается; при пороге 0.5 c погрешность мала. Состояние play/pause + позиция синхронны (в т.ч.
  при `autoplay` и для поздно зашедших) благодаря таймкиперу.
- **id неявных экранов** (по `src`) детерминирован URL; явных плееров без `id` — порядком
  тегов в блоке. Одинаковый HTML → одинаковый id у всех (нужно для совпадения по сети).
- **Безопасность.** Video-URL — вектор SSRF/DoS, как и прочие внешние ресурсы. Закрывается
  общим sandbox/whitelist до выхода на реальные URL (см. конец [vrweb-tags.md](vrweb-tags.md)).

---

## Как устроено в коде

| Файл | Роль |
|---|---|
| [scripts/vrweb_video_player.gd](../scripts/vrweb_video_player.gd) | логический плеер: FFmpeg-декод в текстуру, скачивание src, транспорт, локальный/удалённый режимы |
| [scripts/vrweb_video_screen.gd](../scripts/vrweb_video_screen.gd) | поверхность-квад: albedo = текстура плеера, заглушка до кадра, клик `interact_at` → toggle |
| [scripts/vrweb_video_manager.gd](../scripts/vrweb_video_manager.gd) | реестр плееров по `id`, привязка экранов, мост к `NetworkManager` (sync + heartbeat) |
| [scripts/vrweb_builder.gd](../scripts/vrweb_builder.gd) | теги `<VRWebVideoPlayer>`/`<VRWebVideoScreen>` (как `<VRWebMirror>`) |
| [scripts/network_manager.gd](../scripts/network_manager.gd) | `send_video_event`/`send_video_sync` + RPC `_recv_video_*` + сигнал `video_state_received` |
| [scenes/main.gd](../scenes/main.gd) | создаёт `VrwebVideoManager` в мире и зовёт `scan(vrweb_root)` |

---

## Демо

Открыть `vrwebresource://video.html` (см. [test_pages/video.html](../test_pages/video.html)):
пол, простой экран со своим плеером и один общий плеер на двух поверхностях. С аддоном FFmpeg —
играют публичные mp4; клик по экрану ставит на паузу. Два инстанса онлайн на одном URL
(`--sandbox=A`/`=B`, см. [multiplayer.md](multiplayer.md)) — транспорт синхронизируется.

---

## Дальше

- 3D-позиционное аудио (привязать звук к позиции экрана).
- Прогрессивная загрузка / стриминг (HLS), без полного скачивания.
- Передача роли контроллера и опциональный режим owner-презентера.
- UI-контролы (полоса прогресса, громкость) на самом экране.
