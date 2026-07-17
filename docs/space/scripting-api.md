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

Capability names MVP: `vrweb/core/1`, `vrweb/scene/1`, `vrweb/state/1`, `vrweb/player/1`,
`vrweb/assets/1`, `vrweb/clock/1`, `vrweb/log/1`.

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
