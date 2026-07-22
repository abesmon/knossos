# Единое демо Luau: update, clocks, resources и Distributed State

`vrwebresource://examples/state_switch.html` — эталонный пример поведения страницы на
`vrweb-luau/1`. Он показывает пересечение API в одном пространстве двумя script tags общего
page realm:

1. `document.query("#id")` получает opaque handles обычных VRWML-объектов;
2. `handle.on("activate", ...)` превращает обычный `StaticBody3D` с collision shape в кнопку;
3. `document.state` определяет схему, создаёт общий объект, отправляет команду и подписывает
   представление на canonical distributed state и Subject Bindings;
4. `document.on_update(...)` двигает два шара по синусу: левый от локального времени сцены,
   правый от времени authority;
5. handles декларативных `StandardMaterial3D` меняют цвет шаров каждый кадр, показывая, что
   scripting API обновляет не только nodes, но и resources.

В сцене нет специальных state/action/binding-тегов и невидимых behavior-узлов. Она содержит
только обычные `StaticBody3D`, `MeshInstance3D`, `Label3D`, lights и resources. Вся предметная
логика находится в двух inline Luau внутри
[state_switch.html](../../addons/vrweb_tools/examples/state_switch.html), поэтому тот же документ служит
копируемым примером для создателей и не расширяет VRWML новой доменной конструкцией.

## Update и две шкалы времени

Script `demo.update-clocks` регистрирует один `document.on_update`. Event одного render frame
содержит `delta`, общее для сцены `local_time` и `authority_time`. Левый шар поэтому начинает
фазу с нуля при каждой локальной навигации. Правый вычисляет положение только из authority-time:
клиенты в одной комнате видят одну фазу даже если открыли страницу в разные моменты.

Knossos синхронизирует authority-clock периодическим ping/pong и компенсирует половину RTT.
До первого sample и вне комнаты API честно возвращает `authority_ready=false`; временная шкала
при этом продолжает идти от локальных monotonic ticks, так что демо и offline-сцена не замирают.
Это clock для производного представления, а не замена canonical state: переключатель света рядом
по-прежнему проходит через `document.state`.

Материалы `LocalBallMaterial` и `AuthorityBallMaterial` объявлены обычными `<Resource id=...>`.
Они попадают в тот же id registry, что scene nodes, и возвращаются через `document.query` как
opaque handles. Скрипт создаёт переносимые `Color`/`Vector3` через `document.values`, после чего
передаёт их в обычный `handle.set`.

## Distributed State в той же сцене

Первый script id `demo.light-switch` является namespace wire-id page realm. Локальные `light` и `switch`
превращаются клиентом в `demo.light-switch/light` и `demo.light-switch/switch`, поэтому разные
скрипты страницы не могут случайно занять state друг друга.

Скрипт объявляет bool-поле `enabled` и команду `toggle`. Reducer одним commit переключает
state и назначает `bindings.operator` из `context.actor_user_id`. Страница читает state,
подписывается через `document.state.on` и `on_bindings`, а по `activate` вызывает команду вместо
локального изменения ламп.

Top-level скрипты запускаются на общей границе `scene-ready`. Клик проходит полный публичный
маршрут `RayCast -> VrwebScriptInputBridge -> Luau callback -> document.state.command -> DELTA`,
включая standalone Store в offline mode.

## Проверка

1. Открыть страницу в двух клиентах одной комнаты с небольшой паузой между входами.
2. Убедиться, что локальные часы и фаза левых шаров различаются, а authority-часы и правые шары
   совпадают; подпись правых часов должна перейти из `LOCAL FALLBACK` в `SYNCED TO AUTHORITY`.
3. Убедиться, что оба шара движутся и плавно меняют цвет через scripting resource handles.
4. Навести центр экрана на обычную 3D-кнопку и активировать её: оба клиента должны показать
   один цвет.
5. Открыть третий клиент позже: цвет должен восстановиться snapshot’ом, а правый шар сразу
   прийти в общую фазу.
6. Закрыть первоначальный authority и продолжить переключение в оставшемся клиенте.

`tests/test_state_switch.tscn` строит реальный документ, активирует оба Luau script в общем realm, проверяет
обычный collision target, один update frame и изменение ресурса, имитирует room reset и authority
transition, запускает page-defined reducer через generic Store и подтверждает, что distributed
delta и custom binding возвращаются в Luau subscriptions и меняют сцену. Низкоуровневые инварианты Store отдельно
покрывает `tests/test_replicated_state.gd`.
