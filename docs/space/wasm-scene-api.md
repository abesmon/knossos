# VRWeb Scene API v1

> **Статус: working draft.** API имеет Godot-совместимую семантику, но принадлежит стандарту
> VRWeb и может быть реализован клиентом без Godot.

## Семантический профиль

`vrweb:scene/godot-4.6` фиксирует наблюдаемую семантику публичных classes, inheritance,
properties, methods, signals и math values Godot 4.6. Клиент публикует machine-readable coverage;
наличие имени в полном каталоге не означает локального разрешения content policy.

Полный semantic catalog отделён от малого binary ABI. Guest SDK может показывать typed API:

```javascript
door.rotation = new Vector3(0, Math.PI / 2, 0);
door.addChild(label);
```

но component вызывает только универсальные host operations:

```text
create(class, parent, initial_properties)
get(handle, property)
set(handle, property, value)
call(handle, method, arguments)
subscribe(handle, signal)
destroy(handle)
commit()
```

## Ownership

Object handle непрозрачен, принадлежит module instance и содержит generation. Guest получает
корень собственного `VRWebComponent`, его разрешённых descendants и созданные им objects.
Абсолютные NodePath, `/root`, autoload, player, соседние компоненты и чужие handles недоступны.
Host-owned root нельзя удалить; guest-owned descendants удаляются при unmount.

## Values и mutations

ABI кодирует bounded scalar/string/buffer/collection values и Godot-compatible `Vector*`,
quaternion, color, basis и transform. Object-valued properties проходят отдельную handle policy.
Нормативные wire-примеры находятся в `spec/value-codec-golden.json` и исполняются одинаково host,
JavaScript SDK и Rust SDK. Компоненты `color` канонизируются через IEEE-754 `f32`, повторяя
Godot-совместимый semantic profile; остальные math components передаются как конечные JSON numbers.
Каждый write batch проверяется по ownership, schema, type, capability, content policy и quotas;
ошибка одной команды отклоняет весь batch без частичного изменения сцены.

Methods и signals входят в сгенерированный каталог только с явной security classification.
`FileAccess`, `OS`, raw Script, source code и ambient network/filesystem не являются Scene API.
Отдельные сервисы публикуются versioned capabilities `vrweb:state/1`, `assets/1`, `timers/1`,
`input/1`, `features/1` и `log/1`.

## Низкоуровневый WIT transport

Нормативный interface `vrweb:scene/host@1.0.0` определён в `spec/wit/vrweb-scene/scene.wit`.
`query`, `mutate`, `commit`, `call`, `subscribe` и `unsubscribe` являются единственной runtime
границей. Request/value payload использует bounded canonical JSON encoding tagged values;
невалидный UTF-8, глубина/размер сверх лимита и неизвестная операция возвращают стабильный error
code. Transaction id локален module instance. Неуспешная команда закрывает и отменяет transaction,
а `commit` либо применяет весь buffer, либо не меняет сцену. Команда `create` несёт уникальный
в пределах transaction guest token; успешный `commit` возвращает bounded JSON с соответствием
этих tokens новым opaque handles. Поэтому guest может продолжить работу с созданным объектом, не
получая raw Godot reference и не полагаясь на внутреннюю нумерацию host-команд.

`query(0, {"op":"root"})` выдаёт начальный opaque handle. Нулевой handle не означает Godot root
и не открывает ambient namespace: это только bootstrap operation текущего SceneAuthority.
