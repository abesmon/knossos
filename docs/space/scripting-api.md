# VRWeb scripting API (`vrweb-luau/1`)

Скрипт получает global table `document`. Все объекты сцены представлены opaque handles; их нельзя
преобразовать в Godot `Object` или сохранить как движковую ссылку.

Top-level код всегда входит в VM на lifecycle-границе `scene-ready`: декларативная сцена уже
находится в дереве и прошла первый physics frame. Отдельного `DOMContentLoaded` callback в v1 нет,
потому что сам запуск скрипта является его эквивалентом.

## Scene

- `document.query("#id") -> handle?`
- `document.query_all("#id") -> {handle}`
- `document.create(type, properties) -> handle?`
- `handle.get(property)` / `handle.set(property, value)`
- `handle.call(method, arguments)`
- `handle.on("activate", callback, hint)`
- `handle.destroy()` — только для созданного этим script realm объекта.

Knossos v1 разрешает создание безопасного подмножества 3D nodes и методы `show`, `hide`, `play`,
`stop`. Свойства проходят тот же content-policy фильтр, что атрибуты VRWML. HTML `id` адресует
материализованный объект независимо от его Godot `name`; id декларативного `<Resource>` адресует
тот же ресурс через такой же opaque handle. Поэтому скрипт может, например, менять
`StandardMaterial3D.albedo_color`, не получая прямую engine-ссылку. Запись read-only, служебных и
несовместимых по типу свойств отклоняется до commit. Неуспешный `document.create` транзакционно
удаляет заготовку, поэтому частично созданный объект не остаётся в сцене.

Для переносимого создания значений доступны `document.values.vector3(x, y, z)` и
`document.values.color(r, g, b, a)`. Они возвращают типизированные значения host, пригодные для
`handle.set`, и не раскрывают конструкторы движка.

## Session

`document.session` — ограниченная по размеру сериализуемая table одной script identity. Она
переносится при успешной hot replacement и исчезает при закрытии страницы. Также доступны
`session_get(key, fallback)` и `session_set(key, value)`.

## Distributed state

`document.state` — единственная page-facing надстройка над generic replicated-state subsystem:

- `define(schema_id, definition)`;
- `ensure(object_id, schema_id, initial, owner_user_id)`;
- `read(object_id, schema_id)` и `revision(...)`;
- `command(object_id, schema_id, version, command, args)`;
- `on(object_id, schema_id, callback)`.

Wire ids namespaced script id. Регистрация и top-level commands staged до успешного запуска.
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

## Адресованные remote calls

Capability `vrweb/remote/1` реализует мимолётные адресованные вызовы между realm одного
`script_id` на разных клиентах. Это event, а не replicated state: вызов не хранится, не имеет
snapshot и не воспроизводится late joiner.

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
  произвольную сеть или иные полномочия за пределами уже доступного странице `document`.

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

## Остальной host API

- `document.assets.resolve(relative_url)`;
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
`vrweb/players/1`, `vrweb/player/1`, `vrweb/assets/1`, `vrweb/clock/1`, `vrweb/log/1`.

`local_time` общее для всех script realms одной сцены, но начинается заново при навигации.
`authority_time` у host совпадает с его монотонными ticks, а у остальных клиентов оценивается
периодическим ping/pong с компенсацией половины RTT. Вне сетевой комнаты шкала продолжает идти
локально, но `authority_ready == false`. Она предназначена для вычисления производного состояния
вроде фазы анимации; canonical игровые решения по-прежнему должны проходить через
`document.state` и authority validation.

## Ошибки и лимиты

Недоступная операция возвращает `nil`/`false`; скрипт не получает fallback-доступ к движку.
Knossos ограничивает один source 256 KiB, страницу 32 скриптами, realm 256 handles, 64 timers,
10 000 host calls на один контролируемый вход VM, 75 ms top-level и 25 ms на callback. Текущий memory watchdog использует soft
budget 16 MiB. Эти числа — политика reference client, не wire contract стандарта.

Ошибки callback и CPU timeout локализуются в одном realm: он отключается и очищает выданные им
handlers/timers/owned objects. Остальные скрипты и декларативная сцена продолжают работать.
