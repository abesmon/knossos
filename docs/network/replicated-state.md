# Реплицируемое состояние компонентов (исследование VRChat)

> **Статус:** пилот реализован 12 июля 2026: общий Store/RPC и видео-адаптер работают;
> аватары и эфемерный граф намеренно не мигрированы. Ручной тест двух экземпляров подтвердил
> play/pause и seek с обоих клиентов. Автоматический WebRTC E2E подтвердил late join,
> multi-chunk snapshot, ACK/отказы, конфликт команд, смену authority и reconnect.
>
> **Вердикт:** взять у VRChat разделение на **состояние, события и владельца**, но не строить
> универсальный «RPC со словарём Variant». Для VRWeb нужен небольшой типизированный слой
> реплицируемого состояния поверх существующего авторитета комнаты. Первый пилот —
> видео-плеер. Аватары и эфемерный граф сцены пока не мигрируют.

## Какую систему VRChat мы имеем в виду

У VRChat есть несколько механизмов с похожим словом «parameters»:

- **Avatar/Expression Parameters** управляют аниматором аватара. Это близкий аналог нашей
  `AvatarParameters`, но не общая модель состояния объектов мира.
- **Udon network variables (`UdonSynced`)** — типизированные поля сетевого компонента мира.
- **Network events** — одноразовые вызовы с параметрами, не являющиеся состоянием.
- **Object ownership** определяет единственного автора сетевых переменных объекта.

Дальше под «подходом VRChat» понимается связка последних трёх механизмов.

## Как VRChat разделяет аватары и объекты мира

Avatar/Expression Parameters и Udon synced variables выглядят похоже только снаружи: оба
механизма синхронизируют небольшие типизированные значения. Архитектурно это разные системы.

**Avatar/Expression Parameters** принадлежат конкретному игроку и его аватару. Они входят в
avatar/animator pipeline: Expression Parameters asset задаёт имя, тип, default и sync-флаг;
Animator, Expressions Menu, Avatar Parameter Driver и OSC могут менять эти значения. Лимиты
жёстко заточены под аватар: `bool` занимает 1 бит, `int` и synced `float` — 8 бит, всего до
256 бит synced custom parameters. Float по сети квантуется до диапазона `[-1, 1]`. Sync-типы
тоже аватарные: `Playable` для медленных состояний анимации, `IK` для часто меняющихся
значений с интерполяцией, `Speech` для viseme/голоса и `None` для локальных параметров.

**Udon synced variables** принадлежат объектам мира и UdonBehaviour. Их публикует owner объекта;
они имеют manual/continuous sync, late-join state, ownership transfer, сетевую совместимость
схемы и другие правила world networking.

Причина разделения у VRChat практическая:

- аватар — это поток состояния одного игрока, где владелец всегда сам wearer, важны частота,
  интерполяция, маленький budget и интеграция с Animator/IK/voice;
- объект мира — это разделяемое состояние сцены, где нужен owner, late join, совместимость
  версии мира и валидация действий других игроков;
- аватары должны переноситься между мирами, а Udon-код и сетевые переменные принадлежат
  конкретному миру;
- разные ограничения помогают авторам не использовать один механизм не по назначению.

Плюс такого решения — узкие, оптимизированные контракты. Минус — дублирование понятий
«типизированный параметр», «sync flag», «частый/редкий режим» и отдельные ограничения, которые
нужно помнить. Подводные камни VRChat хорошо показывают цену смешивания доменов: avatar
parameters синхронизируются между PC/Quest по позиции и типу в списке, а не по имени; trigger
parameters не рекомендуются для состояния из-за desync; `Add`/`Random` в Avatar Parameter
Driver может дать разные результаты на разных клиентах, поэтому результат лучше класть в
synced destination parameter и запускать driver локально.

Для VRWeb вывод такой: не надо делать один Store для всего. Имеет смысл иметь общие нижние
примитивы — codec, лимиты, rate metrics, `SAMPLE` envelope, возможно schema registry. Но
`AvatarParameters` как доменная avatar/animator-шина должна остаться отдельно от
`ReplicatedStateStore`, который решает world/object state, команды, authority, snapshots и
late join.

### Почему не один настраиваемый транспорт для всего

Теоретически можно было бы сделать общий transport layer, где каждый поток задаёт rate,
delivery mode, budget, interpolation policy и snapshot policy. Скорее всего, внутри VRChat
какая-то общая сетевая инфраструктура действительно есть, но публичные API намеренно разведены:
avatar parameters и Udon variables не являются разными пресетами одного пользовательского
контракта.

Главный риск не в разной частоте обновления, а в разных **семантиках состояния**:

- avatar stream принадлежит игроку и оптимизируется под свежесть, квантование и сглаживание;
- world object state принадлежит owner/authority и оптимизируется под late join, ревизии,
  ownership transfer и совместимость схемы;
- одноразовые события не должны становиться snapshot-состоянием;
- голос/IK/head pose терпят потерю старых пакетов, а `seek`, `open door` или `set URL` не
  должны теряться и должны проходить проверку прав;
- интерполяция позиции головы и применение команды `seek(42.5)` требуют разных правил
  времени, порядка и конфликта.

Если сделать это одним публичным механизмом с большим набором флагов, появляются типичные
ошибки:

- компонент выбирает неверный delivery mode и получает desync, который сложно диагностировать;
- быстрый поток забивает budget медленного, но важного состояния;
- snapshot начинает включать transient-данные, которые поздний участник не должен
  воспроизводить;
- общий API вынужден поддерживать слишком много комбинаций `rate × ownership × reliability ×
  interpolation × permissions`;
- ради универсальности домены теряют свои инварианты: avatar-код начинает думать про
  authority snapshots, а world-state код — про IK-style interpolation.

Для VRWeb правильная граница: общий transport/envelope и общие лимиты — да; один публичный
state engine для аватаров, видео, графа сцены, чата и эффектов — нет. `SAMPLE`, `DELTA`,
`COMMAND` и `SNAPSHOT` могут использовать общие кодеки и rate limiter, но разные доменные слои
должны явно выбирать, какие из этих режимов им доступны.

## Как это работает в VRChat

### Сетевые переменные — состояние, а не поток команд

Поле Udon-поведения помечается `UdonSynced`. Публиковать его может владелец объекта. Есть два
режима:

- **continuous** — небольшие часто меняющиеся значения отправляются автоматически; возможна
  интерполяция;
- **manual** — владелец вызывает `RequestSerialization()` после логической транзакции.

Новый участник получает последние значения переменных. Итоговое состояние не надо
восстанавливать по истории событий.

### События — для мимолётного эффекта или намерения

Network event выполняется у текущих адресатов один раз. Вошедший позже его не увидит. Поэтому
VRChat рекомендует хранить значимый результат в synced variable, а событие использовать,
например, как запрос владельцу изменить эту переменную.

Современные network events могут нести до восьми параметров поддерживаемых типов. Порядок
одного отправителя гарантирован, но порядка между одновременными отправителями нет. «Любой
пишет всем» само по себе не даёт общей сериализации конфликтов.

### Ownership — часть семантики

У каждого сетевого объекта один owner. Только он публикует synced variables. Владение можно
передать; при уходе владельца VRChat назначает нового. Пользователь либо забирает ownership,
либо отправляет событие текущему owner, а тот валидирует намерение и меняет состояние.

### «Произвольность» ограничена схемой и типами

Это не реплицируемый `Dictionary<String, Variant>`:

- схема полей и типы заданы компонентом;
- поддерживаются примитивы, строки/URL, векторы, quaternion, color и массивы этих типов;
- ссылки на объекты сцены не синхронизируются;
- `DataDictionary` напрямую не синхронизируется — его рекомендуют сериализовать в JSON-строку;
- изменение состава/порядка сетевых компонентов или переменных может сделать версии мира
  несовместимыми.

Ценность VRChat — не «любой Variant по сети», а единый жизненный цикл типизированного
состояния: owner → serialize → deserialize → late join.

### Ограничения формируют архитектуру

По актуальной документации Udon имеет ориентир около 11 КБ/с исходящего трафика; continuous
serialization — примерно 200 байт, manual — до примерно 280 КБ, но большие manual-пакеты
отправляются реже. Параметры одного network event ограничены 16 КБ. Числа нам копировать не
нужно, но вывод универсален: нужны лимиты, rate limiting и режим доставки по классу данных.

## Показательный пример VRChat: видео

Официальный Udon Video Sync Player синхронизирует:

- URL;
- пару `(video_time, server_time)`, записанную владельцем в один `Vector2`;
- периодическую повторную сериализацию пары при необходимости.

Получатель вычисляет позицию как `video_time + (now_server - server_time)`. Late joiner
получает тот же якорь и сразу восстанавливает таймлайн. Главный принцип: **синхронизировать
минимальное каноническое состояние и якорь времени, а производное считать локально**.

## Что уже есть у нас

| Область | Текущая модель | Почему она особенная |
|---|---|---|
| Аватар | `pos + yaw + params` unreliable ~15 Гц от каждого пира | Owner — сам игрок; важнее свежесть и сглаживание, чем snapshot |
| Эфемерный граф | action → authority → ordered event + snapshot | Топология, права, TTL, каскад и персистенция — часть домена |
| Видео | `COMMAND → authority → DELTA`, snapshot + `SAMPLE` от авторитета | Первый потребитель общего Replicated State |

Кроме того:

- `AvatarParameters` уже даёт именованную шину `set/get/apply/snapshot`, но её контракт
  специфичен для аватара и не решает ownership, версии, late join или лимиты;
- `SceneChanges` — хорошая чистая машина авторитетного состояния, но её поля `kind`, `parent`,
  `author`, `ttl`, `props` нужны именно редактируемому графу;
- авторитет комнаты вычисляется по `join_seq` и автоматически сменяется. Это готовый аналог
  owner общего world-state.

## Почему видео стало первым пилотом

Старый протокол был работоспособен, но доменная логика протекала в `NetworkManager`:

- отдельные `send_video_event`, `send_video_sync`, два RPC и `video_state_received`;
- менеджер сам сочетает event/state, heartbeat и late join;
- URL, loop, volume или очередь потребуют расширять сигнатуры либо добавлять RPC;
- действия разных пользователей разрешаются фактическим порядком доставки, не являющимся
  глобальным порядком mesh;
- heartbeat одновременно служит каноническим состоянием и коррекцией дрейфа.

При этом у видео есть стабильный `player_id`, небольшое состояние и авторитет-таймкипер.

## Реализованный слой VRWeb

Рабочее имя — **Replicated State**. Он должен быть меньше Udon и не пытаться заменить все
сетевые модели проекта.

### Контракт компонента

```text
object_id       детерминированный адрес в пределах страницы/комнаты
schema_id       например "vrweb.video.transport"
schema_version  версия совместимости
fields          имя → {type, default, limits}
default_write_rule  правило доступа по умолчанию
commands        имя → {arguments, write_rule?, validator}
```

Допустимые wire-типы первого этапа: `bool`, `int`, `float`, `String`, числовые массивы для
Vector2/3, массивы примитивов с лимитом длины и `PackedByteArray` с отдельным малым лимитом.
Никаких Object/Resource, Callable, NodePath или неограниченно вложенных Dictionary.
Расширяемость даёт схема, а не бесконтрольный `Variant`.

### Права записи: составные правила, а не enum

Одного `write_policy = authority | owner | self` недостаточно: в комнате уже есть ранги, а
разные операции одного компонента требуют разных прав. Например, обычному участнику можно
разрешить play/pause, модератору — seek, а смену URL — только ведущему.

Схема задаёт `default_write_rule`, а конкретная команда может его переопределить. Минимальная
алгебра правил:

```text
authority                         requester — текущий авторитет
object_owner                      requester — владелец объекта
rank { op: lt|lte|eq|gte|gt, value: int }
verified_identity                 requester подтвердил сетевую идентичность (будущий predicate)
any_of [rule, ...]                достаточно одного правила
all_of [rule, ...]                должны выполниться все правила
```

`rank` сравнивает фактический ранг requester из локальной таблицы авторитета. В нашей модели
**меньше число = больше прав**, поэтому типовой порог «ранг не хуже 10» записывается как
`rank <= 10`, то есть `op: lte`. `eq` даёт точную ступень; `gte/gt` полезны для игровых
диапазонов, но не должны использоваться как обычная проверка привилегий. Точный диапазон
выражается через `all_of(gte(min), lte(max))`.

Пример:

```yaml
default_write_rule:
  any_of:
    - authority
    - rank: { op: lte, value: 100 }
commands:
  seek:
    write_rule:
      any_of:
        - object_owner
        - rank: { op: lte, value: 10 }
  set_source:
    write_rule:
      all_of:
        - rank: { op: lte, value: 3 }
        - verified_identity
```

`verified_identity` можно добавить в ту же алгебру, когда политика доверия из `ranks.md`
станет исполняемой. До этого неизвестный predicate обязан давать **deny**, а не silently allow.

Правило проверяется **только авторитетом на приёме `COMMAND`** по `sender peer_id → user_id →
rank`; отправитель не передаёт свой ранг в сообщении. После проверки отдельно запускается
доменный validator аргументов. Access rule отвечает «кто может вызвать», validator — «допустима
ли сама операция сейчас».

Права лучше привязывать к командам, а не к отдельным полям: клиент просит `seek(42.5)`, а не
присылает произвольный patch `anchor_position = 42.5`. Так компонент атомарно обновляет сразу
несколько связанных полей и не открывает обход инвариантов через generic setter.

### Четыре разных сообщения

```text
COMMAND  requester → authority     намерение изменить состояние; reliable
DELTA    authority → room          подтверждённая новая ревизия; reliable ordered
SAMPLE   owner/authority → room    необязательная частая коррекция; unreliable ordered
```

- `COMMAND` проходит проверку схемы, составного access rule, размера и validator компонента.
- Авторитет применяет команду к `StateStore`, повышает `revision` и рассылает `DELTA`.
- `SNAPSHOT` (`epoch`, глобальный `seq`, объекты с revision и fields) отправляется новичку и
  запрашивается при смене авторитета или gap — как в `SceneChanges`.
- `SAMPLE` не меняет каноническую ревизию и не нужен для late join. Это коррекция, а не второй
  источник истины.

`COMMAND` содержит локально уникальный `request_id`. Authority отвечает инициатору `ACK` со
стабильным кодом и revision принятого изменения. ACK не содержит состояние и не заменяет
`DELTA`. Коды первой версии: `accepted`, `access_denied`, `invalid_args`, `invalid_state`,
`unknown_object`, `unknown_command`, `schema_version`, `rate_limited`, `too_large`,
`authority_changed`, `timeout`, `internal_error`. Ожидание ограничено пятью секундами;
pending-команды завершаются `authority_changed` сразу при смене сериализатора.

Дверь может жить только на `DELTA`; положение головы — только на `SAMPLE`; видео использует
редкие `DELTA` транспорта и, пока нет общих часов, редкий `SAMPLE` для коррекции.

### Граница слоёв

```text
NetworkManager (RPC-транспорт, sender id)
        ↓
ReplicatedStateStore (схемы, authority, revision/epoch/seq, snapshot, лимиты)
        ↓ signals / local API
VideoStateAdapter, будущие DoorStateAdapter, SliderStateAdapter…
        ↓
VrwebVideoPlayer и другие доменные узлы
```

`NetworkManager` не знает ключи `playing` или `anchor_position`. Store не знает, как seek'ать
FFmpeg. Адаптер переводит типизированное состояние в вызовы доменного узла.

## Схема видео

| Поле | Тип | Смысл |
|---|---|---|
| `playing` | bool | целевое состояние транспорта |
| `anchor_position` | float | позиция видео при фиксации состояния |
| `anchor_authority_msec` | int | монотонное время авторитета в тот же момент |
| `media_revision` | int | защита от применения таймкода к сменившемуся источнику |

`src`, `loop` и `volume` пока остаются частью страницы. Если появится смена URL/плейлист из UI,
они добавляются версией схемы и валидируются как ресурс. Действия пользователя становятся
командами `set_playing`/`seek`, результат — новое состояние с одной ревизией. Late join
получает snapshot сразу, без ожидания следующего heartbeat.

VRChat использует server time. В нашем p2p mesh общих часов нет, поэтому есть два пути:

1. **Реализованный пилот:** отдельный video-heartbeat заменён generic-сообщением
   `SAMPLE(position, playing, revision)`. Функция коррекции сохранена, а специальные
   `send_video_sync`/`_recv_video_sync` удалены вместе с остальным старым video-протоколом.
   Получаем общий state/late join/ownership без изменения качества синхронизации.
2. **Позже:** оценивать offset к монотонным часам авторитета через ping/pong и считать позицию
   от якоря. Heartbeat станет редкой проверкой дрейфа.

Для первой миграции выбран вариант 1: он не смешивает два независимых изменения.

## Byte budgets и snapshot transport

Лимиты первой версии относятся к результату `var_to_bytes`, а не только к числу полей:

| Payload | Максимум |
|---|---:|
| объект Store | 16 КиБ |
| `COMMAND` | 16 КиБ |
| `DELTA` | 16 КиБ |
| `SAMPLE` | 4 КиБ |
| snapshot комнаты | 1 МиБ |
| snapshot chunk | 32 КиБ |

Store проверяет prospective object и delta **до мутации**, поэтому oversized reducer не может
частично изменить каноническое состояние. Snapshot больше 1 МиБ не отправляется: большие
ресурсы принадлежат blob-протоколу, а не state snapshot.

Snapshot кодируется один раз, получает `transfer_id`, общий размер, число чанков и SHA-256.
Authority посылает `BEGIN`, затем reliable-чанки (не более четырёх за кадр) и `END`. Получатель
собирает только один transfer от текущего authority вне Store, проверяет полноту, размер и hash,
декодирует и валидирует snapshot, после чего заменяет Store атомарно. Таймаут — 10 секунд;
смена authority отменяет незавершённую сборку. Повреждение, неполнота или timeout вызывают
новый pull snapshot.

## ACK и локальные метрики

`request_replicated_command()` возвращает `request_id`, а сигнал
`replicated_command_result(request_id, accepted, code, revision)` завершает optimistic UI.
Видео-адаптер при отказе или timeout возвращает плеер к canonical state. Повторный
`(sender, request_id)` дедуплицируется authority и получает тот же ACK без второго коммита.

`NetworkManager.replicated_metrics()` возвращает ограниченный набор локальных счётчиков без
истории и пользовательских данных:

- count/bytes/max для command, delta и sample;
- snapshot count/bytes/chunks, последний размер и время применения;
- accepted и rejected-команды по стабильному коду, ACK и timeout;
- `duplicate/gap/invalid` delta, запросы resync, snapshot timeout/hash/format failures;
- средний sent/received bytes per second с момента сброса метрик.

Метрики нужны для подбора budgets, обнаружения heartbeat congestion и объяснения desync без
снятия сырого WebRTC-трафика. Их можно очистить через `reset_replicated_metrics()`.

## Что не обобщать сейчас

### Аватары

Не переносить в Store: параметры принадлежат пиру, часто меняются, допускают потери и исчезают
вместе с ним. Позже они могут переиспользовать wire codec, лимиты и метрики, но не
authority-state и не late-join snapshot.

### Эфемерный граф сцены

Не заменять `SceneChanges`: потеряются семантика графа, ownership по `author`, TTL, каскад и
флаш. Можно вынести общие примитивы `epoch/seq/gap/snapshot`, но доменная машина остаётся.

### Чат, голос и эффекты

Чат — событие; голос — realtime-stream; частицы/звук выстрела — событие. Их превращение в
состояние создаст неправильную семантику и ненужные snapshots.

## Риски и ограничения

- **Поверхность атаки:** allowlist схем, проверка типа и конечности float, длины строк/массивов,
  размера объекта/snapshot и rate limit на пира обязательны.
- **Split-brain:** `epoch + seq + revision` отсекают старые/gap пакеты, но после слияния нужен
  выбор состояния нового авторитета. Для видео побеждает состояние авторитета связной
  компоненты; это закрепляется тестом.
- **Schema evolution:** неизвестный `schema_id` игнорируется; несовместимая версия не
  применяется. Optional field с default может быть совместимым, смена типа — новая major.
- **LWW не является правами:** shared player шлёт intent авторитету, который сам вычисляет
  ранг отправителя, проверяет access rule, presenter-mode и допустимый seek.
- **Один глобальный словарь создаст congestion:** данные адресуются объектами и дельтами;
  snapshot лимитируется и при необходимости чанкуется.

## Состояние внедрения

Готово:

1. `ReplicatedStateStore`: registry схем, составные access rules, command reducer/validation,
   revision, delta, snapshot, epoch/seq/gap, allowlist wire-типов и лимиты контейнеров.
2. Generic RPC в `NetworkManager`: `command/delta/snapshot/sample`; canonical-пакеты
   принимаются только от вычисленного authority, команды ограничены 30/с на sender.
3. Видео-схема и адаптер: `set_playing`/`seek`, canonical snapshot и generic `SAMPLE`.
   Специальные video RPC и сигнал удалены.
4. Чистый headless-тест Store покрывает ранги, составные rules, deny неизвестного predicate,
   command/delta/snapshot, revision, gap и ограничения полей.
5. E2E `tests/run_net_replicated_state_test.py` автоматически проверяет late join, команды
   follower→authority, конфликт, сходимость и уход authority на трёх реальных WebRTC-клиентах.
   Второй сценарий перезапускает тот же sandbox/user, меняет состояние во время его отсутствия
   и проверяет восстановление snapshot плюс новую команду после reconnect. Обычные video
   play/pause/seek с обоих клиентов также проверены вручную.
6. Byte/event metrics, ACK и атомарный chunked snapshot с общим budget реализованы и
   покрыты unit/WebRTC E2E.

Осталось перед расширением на второй компонент:

1. Настоящий сетевой split-brain с последующим слиянием двух одновременно живых компонент
   mesh пока не покрыт fault-injection тестом.
2. Если дрейф видео заметен — оценка часов authority и вычисление позиции от временного якоря.

## Критерий решения после пилота

Продолжать, если generic-слой берёт late join, ownership, validation и resync без веток
`if schema == video`. Если Store начинает знать о seek/URL/FFmpeg или кода получается больше,
чем удаляется из `NetworkManager`, остановить обобщение на переиспользуемых примитивах
`epoch/seq/snapshot`.

Критерий подтверждён вторым потребителем: `<VRWebStateSwitch>` использует только bool-state,
`toggle`, ACK, `DELTA` и snapshot — без `SAMPLE` и без изменений generic Store. Демо и ручной
сценарий описаны в [state-switch-demo.md](../client/state-switch-demo.md).

## Источники VRChat

- [Network Variables](https://creators.vrchat.com/worlds/udon/networking/variables/) — manual/
  continuous sync, ownership и late join.
- [Late Joiners & Sync Issues](https://creators.vrchat.com/worlds/udon/networking/late-joiners/) —
  состояние доставляется поздно вошедшим, события не переигрываются.
- [Object Ownership](https://creators.vrchat.com/worlds/udon/networking/ownership/) — один
  владелец и передача владения.
- [Networking Specs & Tricks](https://creators.vrchat.com/worlds/udon/networking/network-details/) —
  типы, массивы, лимиты continuous/manual и congestion.
- [Network Events](https://creators.vrchat.com/worlds/udon/networking/events/) — параметры,
  порядок, targeting и rate/size limits.
- [Data Dictionaries](https://creators.vrchat.com/worlds/udon/data-containers/data-dictionaries/#syncing-a-data-dictionary-with-other-players-over-the-network) —
  словарь нельзя sync'ать напрямую; рекомендуемая упаковка через JSON.
- [Network Compatibility](https://creators.vrchat.com/worlds/udon/networking/compatibility/) —
  несовместимость при изменении сетевой схемы.
- [Udon Video Sync Player](https://creators.vrchat.com/worlds/examples/udon-example-scene/udon-video-sync-player/) —
  URL, `(video time, server time)`, ownership и периодическая синхронизация якоря.
- [Animator Parameters](https://creators.vrchat.com/avatars/animator-parameters/) —
  Expression Parameters, лимиты, sync types и caveats avatar parameters.
- [State Behaviors: Avatar Parameter Driver](https://creators.vrchat.com/avatars/state-behaviors/#avatar-parameter-driver) —
  локальные операции над avatar parameters и предупреждения про divergent Add/Random.
