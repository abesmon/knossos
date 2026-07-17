# VRWeb WebAssembly Runtime v1

> **Статус: working draft.** Это нормативная целевая граница VRWeb. Реализация Knossos
> добавляется по атомарным этапам [единого roadmap](../roadmap.md#p3--стандартный-wasm-sandbox).

## Область контракта

Исполняемый модуль VRWeb — WebAssembly Component с runtime id `wasm-component`. Стандарт
фиксирует WIT worlds, lifecycle, capability negotiation, ошибки и resource limits, но не
конкретную VM, исходный язык, compiler toolchain или игровой движок клиента.

Компонент взаимодействует с host только через объявленные imports. WASI, filesystem, sockets,
process, environment и другие ambient system capabilities отсутствуют по умолчанию. Клиент не
передаёт guest-коду внутренние pointers или объекты движка; scene objects представлены opaque
generational handles, ограниченными module/page ownership scope.

## Версии и worlds

Manifest объявляет обязательный world `vrweb:module@1`. Major version является границей
совместимости. Неизвестный required import или несовместимый major отклоняет только компонент;
статическая часть документа продолжает работать. Optional import доступен только если он
одновременно объявлен manifest и предоставлен host.

World объявляет host interfaces `core`, `scene`, `assets`, `state`, `timers`, `input`, `features`
и `log`, а manifest каждого модуля отдельно фиксирует реально необходимые `requires` и
`optional`. Guest экспортирует четыре lifecycle-функции: `create`, `mount`, `event`, `unmount`.
Конкретные WIT-файлы являются машинно-читаемым источником истины.

Готовый Component не обязан импортировать все interfaces world одновременно. Его фактический
набор imports может быть подмножеством API v1, но каждый import обязан быть объявлен в
`requires` или `optional`. Языковой adapter вправе сформировать минимальный build-world из
используемых imports; это не создаёт новый runtime world или вариант стандарта. Host связывает и
разрешает полномочия по extracted Component imports вместе с manifest, а не по исходному языку.

`core.report-error` — bounded диагностический канал, а не logging или новая capability. Языковой
adapter вызывает его перед trap, если собственный stack языка иначе потерялся бы на Component
Model boundary. Host обязан ограничить сообщение, а adapter — не включать абсолютные пути машины
сборки. Optional Source Map из package может преобразовать generated frame только в логический
`vrweb-source:///` URI автора.

## Lifecycle и scheduling

Наблюдаемый порядок одного instance:

```text
create → mount → event* → unmount
```

Host не вызывает guest реентерабельно. Signals, input, timers и frame updates попадают в
bounded event queue и доставляются между host phases. Scene mutations накапливаются в batch,
валидируются целиком и применяются на границе кадра. После `unmount` callbacks не исполняются,
handles отзываются, guest-owned nodes и subscriptions освобождаются.

## Обязательные ограничения

Каждый instance имеет локальные пределы linear memory, tables/resources, instruction/fuel,
wall-clock execution, host calls, event queue и scene mutations. Trap или превышение лимита
останавливает только виновный instance. Manifest может просить bounded hints, но локальная policy
клиента вправе только уменьшить полномочия и бюджеты.

## Языки

Rust, JavaScript, C/C++ и другие языки равноправны, если результат реализует тот же component
world. Javy, `componentize-js`, Wasmtime и другие инструменты не являются частью стандарта.
Обычный JavaScript страницы не исполняется: DOM, `window`, Node.js и browser API не возникают
без отдельных VRWeb capabilities.

## Независимая проверка совместимости

Versioned conformance archive содержит WIT, Scene API catalog, неизменяемые `.wasm` fixtures,
canonical traces, coverage report и минимальный model host на Wasmtime. Model host не использует
Godot или код Knossos и предоставляет guest только WIT imports. Один и тот же fixture обязан
проходить и в reference client, и в model host с одинаковым trace.

Профиль совместимости нельзя называть `full`, пока `missing_for_full` содержит хотя бы один
обязательный interface, class, property, method или signal. Текущий draft suite намеренно заявляет
узкий профиль `core-scene-state`; это исполняемое доказательство переносимости существующего среза,
а не заявление о полном покрытии Scene API.
