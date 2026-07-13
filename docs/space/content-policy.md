# VRWeb Content Policy

`VrwebContentPolicy` — единая точка решения перед материализацией декларативного VRWeb-контента.
Она применяется к двум клиентским источникам:

- декларациям загруженного document;
- live `vrweb-node` и `vrweb-patch` от участников комнаты.

Persistence не является третьим runtime-источником: после flush объект становится частью
document. В будущем ту же спецификацию правил полезно повторять на серверной границе flush, но
клиент всё равно валидирует полученный документ самостоятельно.

## Текущий статус: passthrough

Реализованы режимы `ALLOW_ALL`, `AUDIT`, `ENFORCE`, однако набор enforce-правил пока пуст.
Поэтому **все три режима сейчас разрешают все декларации** и не меняют совместимость. Наличие
`VrwebContentPolicy` само по себе не является защитой и не закрывает принятый ClassDB-риск.

Каждая декларация до `ClassDB.instantiate()` проходит `evaluate_element`; встроенные и внешние
ресурсы — `evaluate_resource`; фактическая установка/патч свойства — `evaluate_property`.
Результат имеет стабильную форму `{allowed, reason, rule}`. `VrwebBuilder` пропускает отклонённый
элемент или property локально, не ломая остальную сцену.

Один instance policy создаётся в `main` и передаётся и `VrwebBuilder`, и `EphemeralView`, поэтому
будущие правила нельзя обойти переходом с document на live peer object.

## Audit

`snapshot()` возвращает счётчики:

```text
classes     декларации тегов/классов
properties  объявленные атрибуты
mutations   фактические попытки set/patch
resources   типы Resource/ExtResource
operations  live operation kinds (`vrweb-node`/`vrweb-patch`)
sources     document/live_peer
```

Сейчас статистика остаётся в памяти и предназначена для тестов и следующего debug UI. Она нужна,
чтобы сначала увидеть реальные классы и свойства миров, а уже затем формировать safe profile.

## Следующие инкременты

1. Вывести audit snapshot в debug UI и добавить редкие/неизвестные комбинации.
2. Вынести class/property/resource rules в data-driven registry.
3. Добавить в opt-in safe profile hard deny для заведомо опасных properties/classes
   (`script`, `source_code`, callback-и, пути к ФС и произвольные сетевые классы) и очевидные
   бюджеты дерева/ресурсов.
4. Отдельно, только после реальных audit-данных определить поведение неизвестного: allow, warn,
   ask или deny. Это не откладывает блокировку известных опасных поверхностей.

Scripting modules регулируются отдельно через integrity/trust и
[VRWeb Scripting API](scripting-api.md). Trusted GDScript остаётся кодом с правами процесса.
