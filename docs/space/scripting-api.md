# VRWeb Scripting API

Переносимый scripting API определяется WIT-пакетами, а не классами или singleton-ами Knossos.
Нормативная граница описана в [VRWeb WASM Runtime](wasm-runtime.md), формат поставки — в
[VRWeb Module Format](wasm-module-format.md), семантика сцены — в
[VRWeb Scene API](wasm-scene-api.md).

Обязательный world первой версии — `vrweb:module@1`. Он предоставляет lifecycle и negotiation
доступных imports. Системные возможности, включая WASI, сеть, файловую систему, процесс и
постоянное хранилище, отсутствуют, пока отдельная versioned capability не предоставлена host-ом.

Scene API передаёт только opaque handles. Handle принадлежит instance и странице, имеет type tag
и поколение; его нельзя использовать для доступа к `/root`, autoload, player или соседней ветке.
Любое чтение и изменение проходит host-side проверку scope, типа, policy, quota и execution budget.

Запланированные переносимые capability families:

| Capability | Назначение |
|---|---|
| `vrweb:core/1` | identity, features, lifecycle, bounded log |
| `vrweb:scene/1` | scoped queries и транзакционные mutations |
| `vrweb:state/1` | namespaced replicated state |
| `vrweb:assets/1` | доступ к объявленным assets модуля |
| `vrweb:timers/1` | lifecycle-bound timers |
| `vrweb:input/1` | нормализованные interaction events |

До реализации соответствующего import capability считается недоступной. Неизвестный обязательный
import останавливает только модуль; статическая часть страницы продолжает работать. Текущее
состояние реализации и атомарные следующие отсечки ведутся в
[едином roadmap](../roadmap.md#p3--стандартный-wasm-sandbox).
