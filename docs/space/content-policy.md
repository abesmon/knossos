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

## Единый roadmap

Safe profile, registry правил, audit UI, budgets и политика неизвестного ведутся в
[едином roadmap](../roadmap.md#p0--content-policy-safe-profile).
