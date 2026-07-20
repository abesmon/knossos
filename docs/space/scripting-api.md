# VRWeb scripting API (`vrweb-luau/1`)

Скрипт получает global table `document`. Все объекты сцены представлены opaque handles; их нельзя
преобразовать в Godot `Object` или сохранить как движковую ссылку.

> Это справочник по API. Практические рецепты авторских систем синхронизации (якорная
> модель, плейлист с владельцами, выбор между state и remote) —
> в [scripting-patterns.md](scripting-patterns.md).

Top-level код всегда входит в VM на lifecycle-границе `scene-ready`: декларативная сцена уже
находится в дереве и прошла первый physics frame. Отдельного `DOMContentLoaded` callback в v1 нет,
потому что сам запуск скрипта является его эквивалентом.

## Scene

- `document.query("#id") -> handle?`
- `document.query_all("#id") -> {handle}`
- `document.create(type, properties) -> handle?`
- `handle.get(property)` / `handle.set(property, value)`
- `handle.call(method, arguments)`
- `handle.on(event_or_signal, callback, hint)`
- `handle.destroy()` — только для созданного page realm объекта.

Knossos v1 разрешает создание безопасного подмножества 3D nodes и методы `show`, `hide`, `play`,
`stop`. Свойства проходят тот же content-policy фильтр, что атрибуты VRWML. HTML `id` адресует
материализованный объект независимо от его Godot `name`; id декларативного `<Resource>` адресует
тот же ресурс через такой же opaque handle. Поэтому скрипт может, например, менять
`StandardMaterial3D.albedo_color`, не получая прямую engine-ссылку. Запись read-only, служебных и
несовместимых по типу свойств отклоняется до commit. Неуспешный `document.create` транзакционно
удаляет заготовку, поэтому частично созданный объект не остаётся в сцене.

`activate` — переносимое событие пространственного взаимодействия с `{position}`. Кроме него
handle принимает имя объявленного сигнала материализованного объекта. Callback получает
`{type, args}` и именованные поля аргументов, когда движок публикует их имена. Непереносимый
аргумент превращается в `nil`; известный странице объект остаётся opaque handle. Текущий Knossos
поддерживает сигналы с нулём–четырьмя аргументами. Благодаря этому стандартные `Button`,
`CodeEdit`, `Slider`, `ColorPicker` и другие `Control` не требуют отдельных scripting API.

Для переносимого создания значений доступны `document.values.vector3(x, y, z)` и
`document.values.color(r, g, b, a)`. Они возвращают типизированные значения host, пригодные для
`handle.set`, и не раскрывают конструкторы движка.

## Session

`document.session` — ограниченная по размеру сериализуемая table страницы, общая для всех её
script tags. Она
переносится при успешной hot replacement и исчезает при закрытии страницы. Также доступны
`session_get(key, fallback)` и `session_set(key, value)`.

## Distributed state

`document.state` — единственная page-facing надстройка над generic replicated-state subsystem:

- `define(schema_id, definition)`;
- `ensure(object_id, schema_id, initial, owner_user_id)`;
- `read(object_id, schema_id)` и `revision(...)`;
- `command(object_id, schema_id, version, command, args)`;
- `on(object_id, schema_id, callback)`.

Wire ids namespaced identity page realm (в v1 это `id` первого валидного script tag). Регистрация
и top-level commands staged до успешного запуска страницы.
Живой realm сохраняет свои schema/object registrations при подключении или смене комнаты:
сетевой reset очищает локальный Store, после чего client bridge повторяет идемпотентную
регистрацию на `authority_changed`. Начальное значение действует до canonical snapshot от
authority; пользовательский скрипт не должен повторно вызывать `define`/`ensure` из-за reconnect.

Reducer в `definition.commands[name].reducer` получает один event:
`{ state, args, context }` и возвращает patch-таблицу. Callback `on` получает
`{ state, changed, revision }`. Представление остаётся обычной сценой: subscription вызывает
`handle.set(...)`, а интеракция — `handle.on("activate", ...)` и затем `state.command(...)`.
Полный копируемый пример: [демо общего света](../client/state-switch-demo.md) и его
[inline Luau](../../test_pages/state_switch.html).

В offline mode Knossos обрабатывает `command` тем же Store/reducer/delta путём локально, считая
клиент временным standalone authority. При появлении комнаты это локальное состояние заменяется
canonical snapshot по обычным правилам; специальной ветки в page script не требуется.

## Эфемерный слой сцены (`vrweb/scene-objects/1`)

`document.scene` — доступ к [слою эфемерных изменений](../network/ephemeral-changes.md).
Скрипт действует **от имени локального пользователя**: действия идут обычным протоколом
action/event, авторитет валидирует их против своих прав (владение по `author`, ранги) —
capability не добавляет собственной модели прав. Kind не ограничивается: авторитет и
content policy — единственные судьи.

- `document.scene.add(spec, callback) -> id?` — `spec = {kind, parent?, ttl?, props?}`;
  `id` генерится клиентом (адрес СВОЕГО объекта), `callback` получает `{ok, id}` после
  решения авторитета (`nil`, если исход не нужен);
- `document.scene.update(id, props, callback) -> bool` — патч props;
- `document.scene.remove(id, callback) -> bool`;
- `document.scene.object(id) -> table` — плоские данные объекта слоя (`{}` если нет);
- `document.scene.objects(kind) -> {table}` — перечисление объектов слоя (по kind; `nil`/`""`
  — все) для инструментов-модификаторов; размер ограничен самим слоем.

⚠️ **Арность:** во всех host-вызовах передавайте ВСЕ аргументы (необязательные — как `nil`
или `{}`). Текущий Luau-биндинг не подставляет дефолтные значения при недостающих
аргументах: вызов лямбда-биндинга даёт ошибку скрипта, а bound-метод способен уронить
клиент. Конвенция уже используется всеми API (`call("play", {})`).

Top-level вызовы стейджатся до успешного commit realm. Закрытие страницы/realm НЕ удаляет
созданные объекты — артефакты принадлежат пользователю, как штрихи карандаша. В offline mode
слой работает локальной standalone-машиной (симметрично `document.state`); локальные объекты —
сессионные и заменяются снимком комнаты при подключении.

## Прицел (`vrweb/aim/1`)

`document.player.aim() -> {hit, origin, direction, position?, normal?, distance?, target?}` —
`origin`/`direction` луча взаимодействия отдаются **всегда** (прицеливание «в воздух»:
`origin + direction * d`); точка/нормаль/дистанция — при попадании; `target` — html id узла
под прицелом, если он адресуем скриптом (поднимается к ближайшему адресуемому предку
коллайдера). Poll-модель: вызов из `document.on_update` или обработчиков не расходует
handle-бюджет. Держимый предмет исключён из собственного луча. В VR той же формой будут
отдаваться лучи рук.

## Выбор файла (`vrweb/files/1`)

`document.files.pick(kind, callback) -> bool` — модель `<input type="file">`: клиент
показывает системный диалог, сам выбор — явное согласие пользователя. `kind`:
`"image" | "audio" | "model" | "any"` (фильтры диалога, не гарантия типа). Callback:
`{ok, name, size, url, bytes?}` — файл уезжает в blob store и доступен по `vrwebblob://`
URL (готов для `vrweb-node`/realtime-ресурсов); `bytes` — инлайн для файлов ≤ 2 MiB
(например, под `document.assets.decode`). Путь ОС скрипту не сообщается. Один pending-выбор
на realm; в staged top-level недоступен.

## Grabbable-предметы (`vrweb/grabbable/1`)

Материализованный `<VRWebGrabbable>` (норматив — [grabbable.md](grabbable.md)) адресуется
обычным `document.query` и, кроме событий `grab`/`drop`/`use`/`use_end`, принимает
типизированные методы через `handle.call`:

| Вызов | Смысл |
|---|---|
| `call("release", {})` | положить предмет (действует только на клиенте держателя) |
| `call("holder", {})` | `user_id` держателя (`""` — свободен) |
| `call("held_hand", {})` | рука держателя (`""` — свободен) |
| `call("set_enabled", {bool})` | разрешить/запретить захват (аналог VRChat `pickupable`) |
| `call("is_enabled", {})` | текущее состояние |

## Адресованные remote calls

Capability `vrweb/remote/1` реализует мимолётные адресованные вызовы между page realms на
выбранных клиентах. `target_script_id` адресует identity целевого page realm; локальный код одной
страницы взаимодействует обычными globals и вызовами функций, без RPC. Это event, а не replicated
state: вызов не хранится, не имеет snapshot и не воспроизводится late joiner.

Для мимолётных адресованных действий, особенно над локальным игроком, нужен отдельный путь, не
превращающий вызов в replicated state. Автор страницы регистрирует локальный endpoint с
типизированной схемой аргументов, а другой участник вызывает его на выбранном клиенте:

```lua
document.remote.expose("move-player", {
  version = 1,
  args = { "vector3" },
}, function(event)
  -- event.caller выдан transport/session layer, а не прислан вызывающим в args.
  if may_move_player(event.caller) then
    document.player.set_position(event.args[1])
  end
end)

document.remote.call(target_peer_id, "room.controller", "move-player", 1, {
  document.values.vector3(0, 2, 0),
})
```

Handler исполняется в realm страницы **на целевом клиенте**. Поэтому remote peer не получает
`player.set_position` над чужим игроком: он передаёт только намерение, а локальный код автора
мира решает, разрешить ли его и как применить. Автор может проверять rank, object ownership,
подтверждённую identity, игровое состояние или собственные правила. Для телепортации это тот же
принцип, что `network event → LocalPlayer.TeleportTo` в VRChat.

Адрес endpoint включает target `peer_id`, `script_id`, имя и версию. Одного глобального строкового
имени недостаточно: два скрипта не должны перехватывать вызовы друг друга. `event.caller`
формируется из фактического transport peer и содержит неприсланные отправителем identity/rank
facts; claims из обычных аргументов не считаются полномочиями. Handler дополнительно получает
`event.endpoint`, `event.version` и типизированный `event.args`.

Инфраструктура отвечает только за структурные инварианты:

- аутентичную связь сообщения с transport sender и выбранным target;
- точную адресацию document/script/endpoint/version;
- allowlist wire-типов, пределы размера, rate limit и deadline callback;
- отсутствие late-join replay и snapshot у remote calls;
- исполнение только через безопасный стандартный host API: RPC не открывает engine, ОС, файлы,
  произвольные сокеты/сетевые классы или иные полномочия за пределами уже доступных странице
  ограниченных capability `document`.

Семантическую авторизацию инфраструктура не навязывает: endpoint может разрешать host, owner,
команду, конкретного пользователя или всех — это код автора мира. Страница может написать
`allow all`, как обычная web-страница может сама решить, что делать по click/network event.
Отдельного permission per origin/document для locomotion стандарт не требует: безопасность
строится на том, что сам `vrweb/player/1` спроектирован как безопасный page API, а реализация
браузера соблюдает его контракт. Пользователь, зайдя в мир, доверяет его поведению в пределах
этого sandbox так же, как при открытии HTML-страницы доверяет браузеру исполнить JavaScript в
пределах Web API.

Remote calls и `document.state.command` решают разные задачи. Телепорт, haptic pulse или локальный
UI prompt — transient local effect и идут прямо target-клиенту. Открытая дверь, счёт или inventory
— canonical state и должны проходить через authority, reducer, `DELTA` и snapshot. Handler remote
call при необходимости может сам послать state command, но remote transport не должен подменять
каноническую ветку.

Knossos ограничивает realm 32 опубликованными endpoints, вызов — 8 аргументами и 8 KiB wire
данных, вложенность переносимых контейнеров — четырьмя уровнями, а входящий поток — 20 вызовами
в секунду от одного peer. Поддерживаются примитивы, строки, byte arrays, `vector2/3/4`, `color`,
`quaternion`, массивы и словари со строковыми ключами. Endpoint schema дополнительно проверяет
число и объявленные типы аргументов до входа в callback.

Полный пример трёх разных правил допуска: [remote-call demo](../client/remote-call-demo.md).

## Участники и реактивные права

Capability `vrweb/players/1` даёт read-only снимки локального участника и текущего инстанса:

- `document.players.local_info() -> player`;
- `document.players.all() -> {player}`;
- `document.players.on_changed(callback)` — сразу вызывает callback и повторяет его при изменении
  состава, identity, rank, authority, P2P/room connection или локального login/settings state.

Callback получает `{ local = player, players = {player} }` (в Luau поле с зарезервированным
именем читается как `event["local"]`). Каждый player содержит `peer_id`, `user_id`, `nick`,
`rank`, `rank_assigned`, `is_local`, `is_authority`, `can_manage_ranks`, `verified`,
`verified_address`, `online`, `in_room`, `p2p_connected`, `p2p_lost` и сведения о текущем
authority. Это снимки: после события следует использовать новый event, а не ожидать мутацию
старой table.

## Remote data и runtime-ресурсы

Capability `vrweb/assets/2` строится из трёх независимо комбинируемых операций:

- `document.assets.fetch(url, "text" | "json" | "bytes", callback) -> bool`;
- `document.assets.fetch_with(url, response_type, options, callback) -> bool`;
- `document.assets.decode(bytes, resource_type) -> resource?`;
- `document.assets.load(url, resource_type, callback) -> bool` — сокращение `fetch + decode` для
  случая, когда обрабатывать байты в Luau не требуется.
- `document.assets.load_with(url, resource_type, options, callback) -> bool`.

`fetch` вызывает callback с `{ok, url, response_type, data, error}`. Для `json` поле `data` — уже
переносимая table, для `text` — строка, для `bytes` — byte array. `load` вызывает callback с
`{ok, url, resource_type, resource, error, status, credentials}`. `fetch` возвращает те же
`status` и `credentials`. Поддерживаемые типы ресурсов:
`image`, `audio-mp3`, `audio-ogg`, `audio-wav`, `mesh-gltf`.

Ресурс остаётся opaque handle и предоставляет только
`resource.apply(target_handle, property) -> bool`. Host повторно проверяет существование и
записываемость свойства, точный ожидаемый класс ресурса и content policy. Поэтому скрипт может
заменить `StandardMaterial3D.albedo_texture`, `AudioStreamPlayer.stream` или
`MeshInstance3D.mesh`, но не получает Godot object и не может применить аудио к texture-свойству.
Один realm хранит до 64 runtime-ресурсов, одновременно держит до 64 запросов; переносимый ответ
`fetch` ограничен 2 MiB. Низкоуровневый загрузчик коалесцирует одинаковые URL и кэширует результат.

URL разрешается относительно страницы. HTTP(S) доступен страницам; `vrweblocal://` и
`vrwebresource://` доступны только документу из соответствующей локальной схемы, чтобы remote
page не превратила API в чтение файлов пользователя или bundle. GET — единственная сетевая
операция v2: нет произвольных headers, cookies, методов записи, сокетов или доступа к ответу вне
заявленного типа.

### Credentials и ограничения владельца ресурса

Обычные `fetch`/`load` используют режим `credentials = "same-origin"`: Bearer автоматически
прикладывается, только когда и документ, и target URL находятся на origin собственного Home
Server пользователя. Токен никогда не выдаётся сторонней странице, даже если она явно укажет
URL Home Server. Запрос к остальным origin остаётся анонимным.

Для ресурса, которому нужна федеративно проверяемая личность, автор явно выбирает
`credentials = "include"`:

```lua
document.assets.fetch_with("https://assets.example.org/private/data.json", "json", {
  credentials = "include",
}, function(event)
  if event.ok then
    render(event.data)
  elseif event.status == 401 or event.status == 403 then
    show_access_denied()
  end
end)
```

Если документ сам загружен с Home Server пользователя, `include` может использовать его
origin-scoped Bearer. В остальных случаях — включая запрос сторонней страницы к Home Server —
HTTPS origin получает только сертификат identity и одноразовый proof владения приватным ключом.
Если действующего сертификата нет или URL использует открытый HTTP, операция не стартует и
возвращает `false`. `credentials = "omit"` запрещает даже same-origin Bearer.

Сертификат содержит стабильный адрес пользователя и поэтому позволяет владельцу ресурса
атрибутировать запрос, вести allowlist/квоты и вернуть обычный `401`/`403`. Это одновременно
privacy-sensitive действие: сертификат не отправляется стороннему origin по умолчанию; явный
`include` виден в исходнике страницы.

Credentialed-запрос не следует redirect автоматически. Это не позволяет ответу своего сервера
перенаправить Bearer или identity на другой origin. Script получает 3xx в `status` и при
необходимости делает новый запрос к явно выбранному URL, для которого создаётся новый proof.

Запросы асинхронны и стартуют только после успешного commit realm. При hot replacement/навигации
старые callbacks становятся недействительны. Порядок завершения не гарантирован; для карусели
автору следует использовать generation/token и игнорировать устаревшие ответы.

Сетевой transport API не синхронизирует загруженный `Resource`: каждый клиент загружает и
декодирует данные локально. Для синхронного выбора URL/индекса authority отправляет маленькое
намерение через `document.remote.call`; endpoint на каждом клиенте проверяет `event.caller` и
запускает ту же локальную композицию `fetch/decode/apply`. Поздно подключившимся участникам нужен
`document.state`, если выбранный индекс должен иметь snapshot.

Полный пример с локальной и authority-синхронизированной каруселью:
[remote data demo](../client/remote-data-demo.md).

## Видео-плееры (`vrweb/video/1`)

Материализованный `<VRWebVideoPlayer>` адресуется обычным `document.query("#id")` и, кроме
общих операций handle, принимает типизированные транспортные методы через `handle.call`:

| Вызов | Смысл |
|---|---|
| `call("play", {})` / `call("pause", {})` / `call("toggle", {})` | транспорт |
| `call("seek", {seconds})` | перемотка (секунды, число) |
| `call("set_source", {url})` | смена источника на лету; URL резолвится относительно страницы |
| `call("source", {})` | текущий URL источника |
| `call("position", {})` / `call("duration", {})` | таймкоды, секунды |
| `call("is_playing", {})` / `call("is_buffering", {})` | состояние |
| `call("set_volume", {v})` | громкость 0..1 |
| `call("last_error", {})` | `""` / `download_failed` / `decoder_unavailable` / `decode_failed` |
| `on("transport_changed", callback)` | локальные play/pause/seek (`event.action`, `event.position`) |
| `on("texture_ready", callback)` | появился (или сменился после `set_source`) кадр |
| `on("finished", callback)` | реальный конец ролика (не ложный EOF докачки; при `loop` не эмитится) — база для плейлистов |
| `on("playback_error", callback)` | терминальная ошибка, `event.code` — как в `last_error` |

Ошибка, случившаяся до активации скрипта (например, отсутствие FFmpeg-аддона при
материализации тега), сигналом не доедет — её видно опросом `last_error`. `set_source`
сбрасывает ошибку и начинает заново.

Как и остальные `handle.call`, транспорт недоступен в staged top-level — управлять плеером
следует из callbacks (кнопки, таймеры, `document.state.on`, `document.on_update`).

Уровни синхронизации (см. [video-player.md](../client/video-player.md#архитектура-базовый-уровень-и-надстройки)):

- **Плеер по умолчанию (synced).** Скриптовые `play`/`pause`/`seek` эквивалентны клику
  игрока по экрану: уходят команде authority и распространяются стандартной синхронизацией.
  `set_source` стандартная надстройка **не** реплицирует — намеренно: у синтезированного
  плеера источник задан разметкой, а любая его смена по определению исходит из авторского
  скрипта, поэтому синхронизацию источника всегда ведёт сам скрипт (одинаковая
  детерминированная логика у всех либо кастомный `document.state`, см.
  [границу надстройки](../client/video-player.md#архитектура-базовый-уровень-и-надстройки)).
- **`sync="none"`.** Чисто локальный базовый плеер: все вызовы действуют только на этом
  клиенте, а синхронизацию (если нужна) автор строит сам поверх `document.state` /
  `document.remote` / `document.clock` — от караоке с компенсацией задержки до плеера,
  управляемого по рангам. `document.assets` для видео не нужен: источник задаётся URL.

URL в `set_source` подчиняется тем же схемным ограничениям, что `document.assets`: http(s) —
любым страницам, `vrweblocal://`/`vrwebresource://` — только документу той же локальной
схемы.

**Рекомендуемый паттерн кастомной синхронизации — якорь, а не тики.** Вместо периодической
рассылки таймкода страница реплицирует через `document.state` канон
`{src, playing, anchor_position, anchor_time}`, меняющийся только при действиях
(`anchor_time` reducer берёт из `context.authority_msec / 1000` — это та же шкала, что
`document.clock.authority_time()` у каждого клиента). Текущая позиция выводится локально:
`target = anchor_position + (authority_time - anchor_time)`, а правила дрифт-коррекции
(порог, кулдаун, караоке-сдвиг на задержку голоса) — обычный авторский код в
`document.on_update`. Подписка на сигнал `transport_changed` превращает и клики по экрану,
и программные вызовы в state-команды (флаг «применяю канон» рвёт цикл). Snapshot бесплатно
решает late join; периодического трафика нет. `document.remote` остаётся для адресных
transient-действий («пересинхронизируйся сейчас», действия ведущего над одним клиентом),
которые не должны попадать в канон и доигрываться поздно вошедшим. Полный референс:
[scripted video demo](../../test_pages/scripted_video.html)
(`vrwebresource://scripted_video.html`).

## Runtime shaders и материалы

Capability `vrweb/render-shaders/1` даёт два общих примитива: создать shader из точно
объявленного формата и создать/применить материал, не раскрывая объект движка.

```lua
local format = {
  language = "godot-shader",
  version = "4.6",
  type = "spatial",
}

if document.render.shaders.supports(format) then
  format.source = "shader_type spatial; void fragment() { ALBEDO = vec3(1.0); }"
  local result = document.render.shaders.compile(format)
  if result.ok then
    local material = result.shader.create_material()
    material.set_parameter("tint", document.values.color(1, 0, 0, 1))
    material.apply(document.query("#surface"), "material_override")
  end
end
```

- `document.render.shaders.supports(descriptor) -> bool` требует точного совпадения
  `language + version + type`;
- `document.render.shaders.constants() -> {descriptor}` перечисляет стандартные shader globals;
- `compile(descriptor) -> {ok, shader, diagnostics, error}`;
- `shader.format()`, `shader.parameters()`, `shader.create_material()`;
- `material.set_parameter(name, value)`, `get_parameter(name)`,
  `apply(target_handle, property)`.

В Knossos первая реализация поддерживает `godot-shader` ровно версии текущего Godot major.minor
и типы `spatial`, `canvas_item`, `particles`, `sky`, `fog`. Это намеренно engine-specific формат:
автор явно выбирает язык, а клиент без него возвращает unsupported. Автоматической трансляции и
обещания переносимости исходника между shader-языками нет. Более универсальный формат может быть
добавлен позже отдельным значением `language`, не меняя композицию shader → material → apply.

### Стандартные shader inputs VRWeb

Клиент автоматически объявляет зарезервированные inputs во всех shaders, созданных через
`document.render.shaders`. Автор использует имя напрямую и не добавляет engine-specific
объявление самостоятельно. В реализации Godot input становится `uniform`, который runtime
обновляет на каждом созданном `ShaderMaterial`; другая реализация может отобразить ту же семантику
на собственный shader backend.

| Имя | Тип | Семантика |
|---|---|---|
| `AUTHORITY_TIME` | `float`, секунды | Та же монотонная шкала, что `document.clock.authority_time()`. У authority равна его локальным ticks, у остальных оценивается по clock sync; вне комнаты используется локальный monotonic fallback. |

```glsl
shader_type spatial;

void fragment() {
  float pulse = 0.5 + 0.5 * sin(AUTHORITY_TIME * 2.0);
  ALBEDO = vec3(pulse, 0.2, 1.0 - pulse);
}
```

В отличие от встроенного Godot `TIME`, который идёт независимо на каждом клиенте,
`AUTHORITY_TIME` позволяет вычислять одинаковую фазу производной shader-анимации у участников.
Это не canonical state и не источник авторизации. Список зарезервированных globals может
расширяться совместимыми добавлениями capability; их runtime-представление доступно через
`shaders.constants()`. Зарезервированные inputs read-only для автора: runtime обновляет их
значения, а `material.set_parameter` не позволяет их переопределить.

Runtime resources остаются opaque и применяются через ту же проверку свойства и content policy,
что загруженные assets. Текущий Knossos возвращает структурные boundary diagnostics; ошибки
низкоуровневого GPU compiler пока остаются в renderer diagnostics и журнале клиента.

## Остальной host API

- `document.assets.resolve(relative_url)` (сохранён из `vrweb/assets/1`);
- `document.clock.set_timeout(seconds, callback)`;
- `document.clock.set_interval(seconds, callback)`;
- `document.clock.cancel(timer_id)`;
- `document.clock.local_time()` — время активной сцены в секундах от её materialize;
- `document.clock.authority_time()` — монотонная шкала текущего authority;
- `document.clock.authority_ready()` — синхронизирована ли authority-шкала с удалённым host;
- `document.on_update(callback)` — callback каждого render frame с
  `{delta, local_time, authority_time, authority_ready}`;
- `document.player.get("position" | "flying")`;
- `document.player.set_position(vector)`;
- `document.log.debug/info/warning/error(value)`;
- `document.features.has(capability)`;
- `document.features.require(capability)`.

Capability names MVP: `vrweb/core/1`, `vrweb/scene/1`, `vrweb/state/1`, `vrweb/remote/1`,
`vrweb/players/1`, `vrweb/player/1`, `vrweb/assets/1`, `vrweb/assets/2`, `vrweb/clock/1`,
`vrweb/log/1`, `vrweb/render-shaders/1`, `vrweb/video/1`, `vrweb/scene-objects/1`,
`vrweb/aim/1`, `vrweb/files/1`, `vrweb/grabbable/1`.

`local_time` общее для page realm и начинается заново при навигации.
`authority_time` у host совпадает с его монотонными ticks, а у остальных клиентов оценивается
периодическим ping/pong с компенсацией половины RTT. Вне сетевой комнаты шкала продолжает идти
локально, но `authority_ready == false`. Она предназначена для вычисления производного состояния
вроде фазы анимации; canonical игровые решения по-прежнему должны проходить через
`document.state` и authority validation.

## Ошибки и лимиты

Недоступная операция возвращает `nil`/`false`; скрипт не получает fallback-доступ к движку.
Knossos ограничивает один source 256 KiB, страницу 32 скриптами, page realm 256 handles, 64 timers,
10 000 host calls на один контролируемый вход VM, 75 ms top-level и 25 ms на callback. Текущий memory watchdog использует soft
budget 16 MiB. Эти числа — политика reference client, не wire contract стандарта.

Ошибка callback и CPU timeout закрывают общий page realm и очищают выданные им
handlers/timers/owned objects. Декларативная сцена продолжает работать.
