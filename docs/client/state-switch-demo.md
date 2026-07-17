# Демо Luau + Distributed State: общий свет

`vrwebresource://state_switch.html` — эталонный пример поведения страницы на
`vrweb-luau/1`. Он показывает сразу три части portable scripting API:

1. `document.query("#id")` получает opaque handles обычных VRWML-объектов;
2. `handle.on("activate", ...)` превращает обычный `StaticBody3D` с collision shape в кнопку;
3. `document.state` определяет схему, создаёт общий объект, отправляет команду и подписывает
   представление на canonical distributed state.

В сцене нет специальных state/action/binding-тегов и невидимых behavior-узлов. Она содержит
только обычные `StaticBody3D`, `MeshInstance3D`, `Label3D`, lights и resources. Вся предметная
логика находится в inline Luau внутри
[state_switch.html](../../test_pages/state_switch.html), поэтому тот же документ служит
копируемым примером для создателей и не расширяет VRWML новой доменной конструкцией.

## Как устроен скрипт

Script id `demo.light-switch` является namespace wire-id. Локальные `light` и `switch`
превращаются клиентом в `demo.light-switch/light` и `demo.light-switch/switch`, поэтому разные
скрипты страницы не могут случайно занять state друг друга.

Скрипт:

- объявляет bool-поле `enabled` и команду `toggle` с Luau reducer;
- вызывает `document.state.ensure` с начальным состоянием;
- сразу рисует результат `document.state.read`;
- через `document.state.on` применяет каждый snapshot/delta к `visible` четырёх scene handles;
- по `activate` вызывает `document.state.command` вместо изменения ламп локально.

Top-level скрипт запускается на общей границе `scene-ready`. Сам клик проходит полный публичный
маршрут `RayCast -> VrwebScriptInputBridge -> Luau callback -> document.state.command -> DELTA`,
включая standalone Store в offline mode; тест не вызывает reducer напрямую.

Команда использует открытый rank threshold текущего MVP. Это осознанно соответствует текущему
этапу, где client capability layer реализован, а user permissions и instance ACL ещё не сужают
пул. Когда появятся следующие два слоя разрешений, пример должен запрашивать ту же команду, а
решение о доступе будет приниматься на пересечении политик без изменения scene API.

## Проверка

1. Открыть страницу в двух клиентах одной комнаты.
2. После появления перед панелью навести центр экрана на обычную 3D-кнопку и активировать её:
   оба клиента должны показать один цвет.
3. Открыть третий клиент позже: текущий цвет должен восстановиться snapshot’ом.
4. Закрыть первоначальный authority и продолжить переключение в оставшемся клиенте.

`tests/test_state_switch.tscn` строит реальный документ, активирует его Luau realm, проверяет
обычный collision target, имитирует room reset и authority transition, запускает page-defined
reducer через generic Store и подтверждает, что distributed delta возвращается в Luau
subscription и меняет сцену. Низкоуровневые инварианты Store отдельно покрывает
`tests/test_replicated_state.gd`.
