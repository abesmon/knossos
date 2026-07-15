# Видео-плеер (как в VRChat)

> **Суть:** логический видео-плеер декодирует видео по ссылке в текстуру («рендер-буфер»),
> которую можно натянуть на любое число поверхностей мира. Управляется стандартными тегами VRWML,
> в онлайне воспроизведение синхронизируется между клиентами. Прямая аналогия —
> video-player из VRChat.

Расширение Слоя 1 ([README.md](../README.md)) + Слоя 2 (синхронизация). Опирается
на тот же паттерн специального стандартного тега, что и зеркало (`<VRWebMirror>` →
[vrweb-mirror.gd](../../scripts/vrweb_mirror.gd)).

---

## Концепция: плеер ≠ поверхность

Как в VRChat, разделены **логический плеер** (что играет) и **поверхность** (где показывается):

- **`VrwebVideoPlayer`** ([scripts/vrweb_video_player.gd](../../scripts/vrweb_video_player.gd)) —
  headless-узел без геометрии. Декодирует видео в текстуру (`get_video_texture()`), держит
  транспорт (play/pause/seek). Невидим сам по себе.
- **`VrwebVideoScreen`** ([scripts/vrweb_video_screen.gd](../../scripts/vrweb_video_screen.gd)) —
  3D-квад, натягивающий текстуру плеера. Одну текстуру одного плеера показывают сколько угодно
  экранов (общий декод, общая память). Кликабелен лучом игрока (`interact_at`, как
  `ImagePanel`/`Portal`) → переключает play/pause.
- **`VrwebVideoManager`** ([scripts/vrweb_video_manager.gd](../../scripts/vrweb_video_manager.gd)) —
  связывает плееры и экраны по `id` и синхронизирует воспроизведение по сети. Живёт в `world`,
  создаётся в [scenes/main.gd](../../scenes/main.gd) (`_rebuild_world` → `scan`), при навигации
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

Это специальные стандартные теги VRWML — в Knossos они обрабатываются особо в
[vrweb_builder.gd](../../scripts/vrweb_builder.gd), как `<VRWebMirror>`/`<ExtScene>`.

### Стандартный HTML-тег `<video>`

Обычный `<video>` из веб-страницы тоже становится плеером — не нужен `<vrwml>`-блок. Топология
(`TopologyBuilder`) классифицирует `<video>` как объект `media` с `media_tag="video"`, а
`WorldGenerator` строит из него **тот же `VrwebVideoScreen`** (неявный плеер по `src`), что и
стандартный тег VRWML. Так HTML-видео проигрывается реальным плеером приложения.

```html
<video controls preload="metadata">
  <source src="/play/clip.mp4">
  Ваш браузер не поддерживает HTML5 video.
</video>
```

- **`src`** берётся из `<video src>` либо из первого вложенного `<source src>` (стандарт HTML)
  и резолвится относительно базы страницы (учитывает `<base href>`, см.
  [local-resources.md](local-resources.md)).
- **`autoplay`/`loop`** — булевы атрибуты (наличие = `true`) пробрасываются в неявный плеер.
- **Размер** экрана берётся из `width`/`height` (если заданы абсолютно), иначе — запасная
  ширина с пропорциями 16:9; высота подгоняется под реальные пропорции кадра при его приходе
  (как `<img>` под текстуру). Экран ставится у стены комнаты, центр на уровне глаз.
- Без аддона FFmpeg или без `src` — деградирует до статичной заглушки `▷` (как прочие `media`).

Привязку HTML-экранов делает тот же `VrwebVideoManager`: `main._rebuild_world` сканирует **весь
мир** (`scan(_world)`), а не только корень `<vrwml>`, поэтому экраны из обоих источников
регистрируются и синхронизируются одинаково.

> **Важно:** раз `scan` обходит весь `_world`, старое поддерево к моменту скана должно быть уже
> **удалено из дерева**, а не просто `queue_free()`'нуто. `queue_free` убирает узел из дерева лишь
> в конце кадра, а `scan` бежит в том же кадре — поэтому в `_rebuild_world` старые дети сносятся
> через `remove_child()` + `queue_free()` сразу. Иначе свежий менеджер обошёл бы умирающие экраны
> старой страницы и повторно их `bind`'нул (ошибка «`texture_ready` already connected»), а мёртвые
> плееры попали бы в `_players` и всплыли как «previously freed instance» в `_process`.

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
  сабмодулем в [third_party/EIRTeam.FFmpeg](../../third_party/EIRTeam.FFmpeg) (см. ниже).

### Сборка для macOS (из сабмодуля-форка)

ffmpeg собирается из исходников через `ffmpeg-kit` (нативного релиза под macOS нет). В нашем
форке Makefile **пропатчен на decode-only** (без энкодеров x264/x265/lame — плееру нужен только
декод; это сильно ускоряет сборку и делает её LGPL-чистой) и на `arch=$(PREFIX_ARCH)` для scons.
Патч закоммичен в форк, сабмодуль закреплён на ветке `knossos-decode-only` (см. `.gitmodules`),
поэтому `git submodule update` приносит уже пропатченный Makefile — применять ничего вручную не
надо.

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
> Правки сборки закреплены в форке (ветка `knossos-decode-only`, коммит с патчем Makefile),
> gitlink в основном репо указывает на него — изменения не потеряются. Build-артефакты внутри
> сабмодуля (`thirdparty/`, `gdextension_build/build/`, `venv/`) не отслеживаются родителем
> (`ignore = dirty` в `.gitmodules`).

**Деградация без аддона:** `VrwebVideoPlayer.is_available()` (= `ClassDB.class_exists`,
как `NetworkManager.webrtc_available()`) ложно — плеер не стартует, экраны показывают заглушку
«▶ video unavailable», приложение работает.

### Как кадр попадает в мир

```
src URL → прогрессивная докачка в user://-кэш (.part, Sandbox.resolve) → FFmpegVideoStream.file
   → VideoStreamPlayer (в скрытом CanvasLayer, декодирует, но не рисуется на экране)
   → get_video_texture()  ── обновляется на месте ──►  albedo_texture экранов (N штук)
```

`VideoStreamPlayer` (это `Control`) держится в дереве с `visible=false` — не рисуется в 2D, но
декодирует, пока играет. ⚠️ Его **нельзя** класть в невидимый `CanvasLayer`: там проигрывание
замирает (позиция не растёт); сам по себе невидимый VSP играет нормально. Текстура кадра
обновляется на месте — поэтому раздаётся многим материалам без копий (как `AnimatedTexture` у
гифок, см. [gif-support.md](gif-support.md)).

---

## Прогрессивная загрузка (буферизация) — без полного скачивания

Раньше видео качалось в кэш **целиком** и только потом стартовало — большие файлы заставляли
ждать (а то и не дожидались). Теперь декод стартует, **не дожидаясь** полной загрузки. Всё на
стороне GDScript ([vrweb_video_player.gd](../../scripts/vrweb_video_player.gd)) — нативный аддон
FFmpeg **не трогали** (почему — см. ниже).

**Идея.** `HTTPRequest.download_file` пишет тело во временный `*.part`-файл по мере приёма;
`FFmpegVideoStream` открывает этот **растущий** файл и декодирует с начала, пока он докачивается.
Декодер EIRTeam читает файл через `FileAccess` (`_read_packet_callback` в
`third_party/EIRTeam.FFmpeg/video_decoder.cpp`) и на коротком чтении
возвращает `AVERROR_EOF` — для него «конец докачанного куска» неотличим от «конца видео».
Поэтому **различает их GDScript**.

Машина состояний — в `VrwebVideoPlayer._process` (гоняется, пока файл качается или нет кадра):

1. **Ранний старт.** Накопив `START_BUFFER_BYTES` (≈2 МБ), открываем декод по `.part`.
2. **Первый кадр.** Поймали `get_video_texture()` → `texture_ready`, плеер «стартовал»
   (`_ever_started`). Если кадра нет дольше `PROBE_TIMEOUT_MS` (3 с) — у файла, видимо,
   `moov`-атом **в хвосте** (не faststart): рано открывать бесполезно, закрываем и ждём полной
   загрузки (`_early_open_blocked`).
3. **Ложный EOF.** Воспроизведение встало (`not is_playing`), хотя паузу не ставили и докачка
   ещё идёт — это конец докачанного куска, а не видео. Запоминаем позицию и размер файла.
4. **Перезапуск.** Дождавшись прироста файла (`REOPEN_AHEAD_BYTES`) или полной загрузки,
   **переоткрываем** файл и `seek` на сохранённую позицию. Перезапуск создаёт новый playback →
   новый объект текстуры, поэтому `texture_ready` эмитится повторно, и экраны перепривязывают
   `albedo` (`VrwebVideoScreen._on_texture`).

Тонкости:

- **`.part` → финал только при успехе.** Качаем в `cache_path + ".part"`, переименовываем в
  `cache_path` лишь по `RESULT_SUCCESS`. Иначе оборванный файл закэшировался бы как целый и
  подхватился следующим запуском. Открытый декодером дескриптор POSIX-переименование не рвёт.
- **`loop` — только после полной загрузки** (`_maybe_enable_loop`). Включи штатный
  `VideoStreamPlayer.loop` раньше — ложный EOF зациклил бы видео на начало вместо ожидания
  докачки (и сломал бы детектор из п. 3).
- **Намерение play/pause** (`_want_playing`) отслеживается в `_do_play`/`_do_pause`, чтобы
  перезапуск восстановил то же состояние (а не стартовал всегда играющим).
- **faststart vs moov-в-хвосте.** Прогрессив реально работает для файлов с `moov` спереди
  (faststart/fragmented mp4). Для `moov` в хвосте `avformat_find_stream_info` не сможет открыть
  частичный файл — п. 2 это ловит и аккуратно деградирует до «дождаться целиком».
- **Обрыв скачивания.** Если уже стартовали — `.part` оставляем (доиграется до реального конца);
  если нет — чистим (заглушка 403/404 не должна кэшироваться).
- **Очистка кэша.** Дисковый кэш видео (`user://video_cache/`) очищается в настройках:
  вкладка **«Прочее» → Очистить кэш** (вместе с кэшем аватаров). Размер и удаление —
  `scripts/cache.gd` (`Cache.total_size()` / `Cache.clear()`), пути через `Sandbox.resolve()`.

### Почему GDScript, а не FFmpeg-стрим напрямую

FFmpeg умеет сам тянуть URL (range-запросы, seek по сети), но наша сборка ffmpeg **decode-only,
без TLS** (нет gnutls/openssl — см. `third_party/EIRTeam.FFmpeg/Makefile`
форка), а реальные видео-URL почти всегда `https`. Дать декодеру открывать URL напрямую
потребовало бы пересборки ffmpeg с TLS на всех платформах и сломало бы LGPL-чистую decode-only
сборку. Буферизация на стороне GDScript использует `HTTPRequest` (он умеет `https`) и **не
требует правок и пересборки нативного аддона**.

---

## Наэкранный UI: прогресс-бар + буфер

На самой поверхности (`VrwebVideoScreen`) внизу рисуется полупрозрачный **прогресс-бар** в стиле
плеера: тёмная дорожка, поверх неё серая полоса **буфера** (скачанная часть) и красная полоса
**проигранного**, плюс подпись «глиф состояния  M:SS / M:SS». UI собран из простых 3D-узлов
(`QuadMesh` + `StandardMaterial3D` с альфой, `Label3D`) — без `SubViewport`, в стиле остального
мира (как заглушка `▶ video`). Вынесен на `UI_FRONT_Z` перед плоскостью экрана (анти-z-fighting);
буфер/прогресс — чуть ближе к зрителю, чем дорожка.

**Появление «как от мыши».** UI проявляется, только когда луч игрока **попадает в экран и
точка касания движется** (будто водят мышкой), и плавно гаснет, если:

- луч ушёл с экрана (`Player._dispatch_hover` вызвал `pointer_exit`; запасной таймаут
  `UI_LOST_HIDE` остаётся для устойчивости), **или**
- точка касания не двигалась дольше `UI_IDLE_HIDE` (мышь «замерла»).

Механика: игрок каждый физ-кадр кормит текущую world-space UI-поверхность методом
`hover_at(point)` и явно сообщает уход через `pointer_exit` (общий канал непрерывного наведения,
в отличие от `interact_at` по клику — см. `Player._dispatch_hover` в
[actors/player/player.gd](../../actors/player/player.gd)). Экран сам ведёт таймауты и затухание
(`_update_ui`). Сдвиг точки меньше `UI_MOVE_EPS` считается «мышь не двигалась».

**Что показывает буфер.** Серая полоса = `VrwebVideoPlayer.buffered_fraction()` — доля файла,
уже скачанная и доступная декодеру (во время докачки — от `Content-Length`, после — целиком). Так
видно, **насколько вперёд набит буфер** прогрессивной загрузки. Красная полоса прогресса =
`position()/duration()`. Глиф состояния: `▶` играет, `‖` пауза, `…` буферизация (underrun,
`is_buffering()` — плеер ждёт докачки, см. ложный EOF выше).

**Перемотка (seek).** Клик по **видимому** бару перематывает в эту точку: `interact_at` переводит
точку прицела в локальные координаты квада, проверяет попадание по бару (`_seek_at`, зона по
вертикали щедрая — бар тонкий) и зовёт `VrwebVideoPlayer.seek(fraction * duration)`. `seek` —
локальное действие: эмитит `transport_changed`, поэтому перемотка **уходит в сеть** через менеджер
(как play/pause). Клик мимо бара — по-прежнему play/pause. Перетаскивания (scrub) нет: клик игрока
одиночный (`Player._try_interact`), удержание не отслеживается.

---

## Синхронизация (Слой 2): shared-модель

Комната (WebRTC) ключуется по URL страницы (`PageFetcher.seed_key`), поэтому `id` плеера совпадает у всех клиентов.
Покадровый стрим невозможен (mesh p2p, только data-каналы) — **каждый клиент сам грузит тот же
URL**, синхронизируется только **состояние транспорта**.

- **Любой управляет.** Клик превращается в типизированную команду `set_playing`/`seek` и
  reliable отправляется авторитету. Тот проверяет sender/rank и аргументы, повышает revision
  и рассылает канонический `DELTA`.
- **Таймкипер.** Источник таймкода — **авторитет комнаты**, то есть раньше всех вошедший
  подключённый пир с наименьшим `join_seq` (`NetworkManager.is_timekeeper()` — алиас
  `has_authority()`): детерминированно у всех, ровно один, без переговоров. При его уходе роль
  переходит к следующему старейшему участнику комнаты.
- **Heartbeat.** Таймкипер ~1.5 Гц рассылает общий `SAMPLE` с **позицией + состоянием
  play/pause + revision**. Остальные дрейф-корректируются: меняют play/pause при
  расхождении и делают seek, если разошлись больше `DRIFT_THRESHOLD` (0.5 c).
- **Поздний вход.** Snapshot сразу восстанавливает канонические play/pause и последний якорь;
  следующий `SAMPLE` (до ~0.66 c) уточняет текущую позицию без изменения revision.
- **Анти-дребезг.** После явного действия плеер ~1 c игнорирует heartbeat (`SYNC_GRACE_MS`),
  чтобы устаревший таймкод не откатил свежий play/pause/seek, пока reliable-событие
  распространяется.
- **Отказ команды.** Локальный play/seek применяется optimistic, но менеджер запоминает
  `request_id`. Если authority отвечает `access_denied`/`invalid_state` либо наступает timeout,
  плеер возвращается к последнему canonical состоянию Store; ACK не используется как состояние.
- **Офлайн** — `NetworkManager.send_*` без mesh это no-op, плеер просто играет локально.

**RPC** ([network_manager.gd](../../scripts/network_manager.gd)) общие для компонентов:
`_recv_replicated_command`, `_recv_replicated_delta`, `_recv_replicated_snapshot` (reliable) и
`_recv_replicated_sample` (unreliable ordered). Видео-ключей и действий сетевой слой не знает;
их описывает [video_state_schema.gd](../../scripts/network/video_state_schema.gd), а применяет
`VrwebVideoManager`.

Локальное действие → `transport_changed` (эмит) → менеджер ретранслирует; удалённое →
`apply_remote` (**без** эмита) → нет сетевого цикла.

---

## Ограничения прототипа

- **Аудио непозиционное** — играет через шину `VideoStreamPlayer`, не привязано к позиции
  экрана. 3D-аудио по позиции — позже.
- **Прогрессивная загрузка есть, HLS/стрим — нет.** Декод стартует, не дожидаясь полной
  загрузки (буферизация на стороне GDScript, см. раздел выше), но это всё ещё докачка одного
  файла в кэш, а не настоящий стриминг. Ранний старт реально работает для faststart-mp4
  (`moov` спереди); для `moov` в хвосте деградирует до «дождаться целиком». HLS/DASH — позже.
- **Дрейф-коррекция без синхронизации часов** — возраст heartbeat-пакета (≈RTT/2) не
  учитывается; при пороге 0.5 c погрешность мала. Состояние play/pause + позиция синхронны (в т.ч.
  при `autoplay` и для поздно зашедших) благодаря таймкиперу.
- **id неявных экранов** (по `src`) детерминирован URL; явных плееров без `id` — порядком
  тегов в блоке. Одинаковый HTML → одинаковый id у всех (нужно для совпадения по сети).
- **Безопасность.** Video-URL — вектор SSRF/DoS, как и прочие внешние ресурсы. Закрывается
  общим sandbox/whitelist до выхода на реальные URL (см. конец [vrwml-tags.md](../space/vrwml-tags.md)).

---

## Как устроено в коде

| Файл | Роль |
|---|---|
| [scripts/vrweb_video_player.gd](../../scripts/vrweb_video_player.gd) | логический плеер: FFmpeg-декод в текстуру, прогрессивная докачка src (буферизация, ранний старт), транспорт, локальный/удалённый режимы |
| [scripts/vrweb_video_screen.gd](../../scripts/vrweb_video_screen.gd) | поверхность-квад (`WorldUiSurface`): albedo = текстура плеера, заглушка до кадра, клик `interact_at` → toggle/seek, наэкранный UI (прогресс/буфер) по `hover_at`/`pointer_exit`, `size_changed` после подгонки aspect ratio |
| [scenes/vrweb_video_screen.tscn](../../scenes/vrweb_video_screen.tscn) | обязательная составная сцена экрана: `Mesh`, `Collision`, `Placeholder`, `PlaybackUI`; стандартный тег VRWML инстанцирует именно её, не голый скрипт |
| [scripts/vrweb_video_manager.gd](../../scripts/vrweb_video_manager.gd) | реестр плееров, привязка экранов и адаптер Replicated State |
| [scripts/network/replicated_state_store.gd](../../scripts/network/replicated_state_store.gd) | схемы, access rules, command/delta/snapshot, revision и лимиты |
| [scripts/network/video_state_schema.gd](../../scripts/network/video_state_schema.gd) | типизированные поля, команды и reducers транспорта видео |
| [scripts/vrweb_builder.gd](../../scripts/vrweb_builder.gd) | теги `<VRWebVideoPlayer>`/`<VRWebVideoScreen>` (как `<VRWebMirror>`) |
| [scripts/topology_builder.gd](../../scripts/topology_builder.gd) | HTML-тег `<video>` → объект `media` с `media_tag="video"` (src из `<video>`/`<source>`, autoplay/loop, размеры) |
| [scripts/world_generator.gd](../../scripts/world_generator.gd) | `_build_video_screen` строит `VrwebVideoScreen` из объекта `media`-video; `_measure_video` — первичные габариты, поздний `size_changed` запускает reflow комнаты |
| [scripts/network_manager.gd](../../scripts/network_manager.gd) | общий RPC-транспорт `COMMAND/DELTA/SNAPSHOT/SAMPLE` |
| [scenes/main.gd](../../scenes/main.gd) | создаёт `VrwebVideoManager` в мире и зовёт `scan(vrweb_root)` |

---

## Демо

Открыть `vrwebresource://video.html` (см. [test_pages/video.html](../../test_pages/video.html)):
пол, простой экран со своим плеером (мелкий 1 МБ-клип — стартует мгновенно) и один общий плеер
на двух поверхностях — большой «Big Buck Bunny» 1080p (~30 МБ, faststart) для проверки
прогрессивной загрузки: декод стартует, накопив ~2 МБ, а не после полной докачки. С аддоном
FFmpeg играют публичные mp4; клик по экрану ставит на паузу. Два инстанса онлайн на одном URL
(`--sandbox=A`/`=B`, см. [multiplayer.md](../network/multiplayer.md)) — транспорт синхронизируется.

> ⚠️ **URL — только прямые https без кросс-хостового редиректа.** Godot `HTTPRequest` падает на
> 302 на другой хост (`ERR_INVALID_PARAMETER` в `_check_request_url` → `RESULT_CONNECTION_ERROR`,
> файл не создаётся). На этом молча ломался `archive.org/download/...` (редиректит на
> `ia*.us.archive.org`). Берите прямые ссылки (`download.blender.org`, `test-videos.co.uk`).
> Ручное следование за редиректами через `HTTPClient` сейчас не реализовано; работа учитывается
> в [едином roadmap](../roadmap.md#p0--scripting-preflight-и-transport-boundaries).

---

## Единый roadmap

Все планы видеоплеера и media transport ведутся в
[едином roadmap](../roadmap.md#p2--video-и-voice).
