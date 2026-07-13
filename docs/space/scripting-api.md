# VRWeb Scripting API v1

`context` — переносимый контракт между scripting module и VRWeb-клиентом. Trusted GDScript также
может пользоваться публичным Godot API, но внутренние классы/autoload-ы Knossos не являются API
и не получают гарантий совместимости. Для trusted runtime `context` — compatibility boundary,
а не security sandbox.

## Capabilities

| Capability | Facade | Статус |
|---|---|---|
| `vrweb/core/1` | `mount(context)`, `unmount()`, identity/lifecycle | stable |
| `vrweb/scene/1` | `context.scene.root/find/is_valid` | stable, минимальный |
| `vrweb/state/1` | `context.state` replicated schema/object/command/read/subscriptions | stable |
| `vrweb/assets/1` | `context.assets.has/load/text/bytes` | stable |
| `vrweb/timers/1` | `context.timers.start/cancel/cancel_all` | stable |
| `vrweb/input/1` | `context.input.on_activate/off_activate` | stable, только activate |
| `vrweb/log/1` | `context.log.debug/info/warning/error` | stable |
| `vrweb/features/1` | `context.features.has/require` | stable |
| `godot/engine/4` | публичный API Godot 4 в `trusted-gdscript` | runtime extension |

Старые `context.has("lifecycle/1"|"scene-root/1"|"replicated-state/1"|...)` оставлены как
совместимые aliases. Новый код использует `context.features.has("vrweb/.../1")`.

## Manifest

Package объявляет обязательные и опциональные capabilities:

```json
{
  "format": 1,
  "id": "demo.lights",
  "runtime": "trusted-gdscript",
  "requires": ["vrweb/core/1", "vrweb/scene/1", "godot/engine/4"],
  "optional": ["vrweb/state/1", "vrweb/input/1"],
  "exports": {"default": {"script": "light_switch.gd", "base": "StaticBody3D"}}
}
```

Неизвестная обязательная capability останавливает только данный модуль до инстанцирования.
Неизвестная optional capability видна через feature detection. Ошибка модуля не должна ломать
статическую часть страницы.

## Input

`context.input.on_activate(target, callback, hint)` принимает только `target` из ветки
компонента. В Knossos target должен быть физическим collider, на который попадает луч игрока.
Host связывает его со своим input protocol; модуль не обращается к `Player`:

```gdscript
func mount(context):
    context.input.on_activate(self, func(_point):
        context.state.command("demo", "switch", 1, "toggle")
    , "Toggle shared light")
```

Hover, drag, grab, axes, `fetch` и `storage` не входят в v1: capability расширяется после
появления реального потребителя.

## Package-demo

Открыть `vrwebresource://package_script.html`. Исходник —
[`tests/fixtures/package_demo/light_switch.gd`](../../tests/fixtures/package_demo/light_switch.gd),
готовый пакет — [`test_pages/lights.vrmod`](../../test_pages/lights.vrmod). Пересборка:

```bash
HOME=/tmp/knossos-godot-home godot --headless --path . \
  --log-file /tmp/knossos-package-demo.log --script tests/build_package_demo.gd
```

Команда печатает integrity и hash. При изменении пакета новое значение integrity нужно перенести
в `test_pages/package_script.html`; trust по старому exact hash намеренно не наследуется.
