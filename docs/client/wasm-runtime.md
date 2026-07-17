# Native WASM runtime в Knossos

Текущий checkout содержит optional исследовательскую Rust GDExtension в
`native/vrweb_wasm_runtime`. Это ненормативная reference implementation стандарта VRWeb:
публичной границей остаются WIT packages и наблюдаемая семантика Scene API.

После maintenance review принято решение сохранить небольшой прямой adapter над официальными
Wasmtime и `godot-rust`, а не переходить на fork общей Godot WASM GDExtension. Обоснование,
измеренная площадь сопровождения и условия пересмотра зафиксированы в
[аудите Godot WASM runtimes](godot-wasm-evaluation.md).

## Закреплённый toolchain

- Rust 1.94.0 (`rust-toolchain.toml` является источником версии для локальной сборки и CI);
- `godot-rust` 0.5.2 с Godot API 4.6;
- Wasmtime 46.0.1 с `component-model`, Cranelift и без WASI linker;
- точные transitive versions фиксирует `Cargo.lock`;
- build metadata и targets записаны в `runtime-build.json`.

Сборка и установка в checkout:

```bash
bash native/vrweb_wasm_runtime/build_runtime.sh debug
```

На macOS скрипт создаёт universal `arm64+x86_64` dylib. На Linux и Windows собирается host
`x86_64` library. Generated addon находится в `addons/vrweb_wasm_runtime` и не хранится в Git:
без него Knossos использует `UnavailableWasmBackend` и продолжает открывать статические страницы.
Release `build.sh` требует platform artifact и прикладывает license metadata.

## Реализованные границы

Native runtime валидирует именно Component Model binary, перечисляет imports/exports, запрещает
WASI и неизвестные/скрытые imports до instantiation. Каждый store получает:

- 1 000 000 fuel на вызов;
- максимум 16 MiB linear memory;
- максимум 10 000 элементов одной table и quotas instances/tables/memories;
- epoch deadline 50 ms;
- максимум 64 host calls на lifecycle event.

Optional manifest `limits` выбирает бюджет внутри hard maxima для конкретного instance. Default
fuel остаётся 1 000 000; локальный maximum 50 000 000 нужен self-contained language VM adapters,
которые обязаны запросить его явно и всё равно ограничены 50 ms epoch deadline. Runtime
проверяет `fuel`, `memory_bytes`, `deadline_ms`, `host_calls`, `instances`, `tables` и `memories`
до instantiation; нулевые и превышающие local policy значения отклоняются.

Lifecycle instance проходит `create → mount → event → unmount`; повторный callback после остановки
или unmount невозможен. Hostile fixtures покрывают infinite loop, memory growth, trap, host-call
flood, table growth, core module вместо component, WASI, неизвестный import и major mismatch.
Binary validator также получает все truncated prefixes и детерминированные byte mutations. После каждой
ошибки запускается исправный `answer() → 42`.

GDScript-side authority реализует bounded value codec, generational owner/page handles,
read-only scoped traversal, атомарные property batches, allowlisted create/resource/reparent/
destroy, methods и queued signals. `vrweb:scene/host@1.0.0` связан с authority непосредственно
в linker каждого Store. Граница остаётся byte-only: Rust хранит `Callable` конкретного instance,
а guest передаёт только WIT scalar/string/list values. `Node`, `Object`, pointer и Variant никогда
не пересекают sandbox boundary. Host-call budget общий для log и Scene API.

Integration fixture импортирует `scene.query` по Component Model ABI и во время `create` проходит
полный путь `guest → canonical lowering → Wasmtime linker → Godot Callable → SceneAuthority`.
Отдельный authority test проверяет root query, `mutate/commit`, стабильный отказ invalid UTF-8 и
реальное изменение scoped property.

Portable-services fixture тем же путём вызывает `state`, `assets`, `timers`, `input`, `features`
и `log`, после чего проверяется canonical host-call trace, module-scoped state, timer event и input
registration. `close` отменяет timers/subscriptions и запрещает последующие callbacks.

Backend возвращает structured diagnostics вместе с совместимыми человекочитаемыми errors.
Запись содержит stable `code`, lifecycle `phase`, `module`, public `origin`, content `hash` и
instance id; component path хоста в этот contract не входит. Уже используются codes
`runtime_unavailable`, `component_invalid`, `import_policy_denied`, `module_not_prepared`,
`export_not_found`, `execution_budget_exhausted`, `memory_limit_exceeded`,
`host_call_budget_exhausted`, `event_envelope_too_large` и `guest_trap`. Instance context также
публикует module hash/origin для debug UI. Diagnostic schema содержит bounded `guest_stack`,
первый Wasmtime offset как `source_location` и только package-local имя `debug_sidecar`; абсолютный
host component path туда не входит. Для языков, чья VM теряет stack при переходе в WASM trap,
`vrweb:core/host.report-error` передаёт до 8 KiB portable guest-stack до самого trap. JavaScript
adapter делает это автоматически, оставляет только кадры `module.bundle.js`, а Source Map v3
consumer преобразует первый подходящий кадр в `vrweb-source:///creator-file:line:column`.
Integration fixture доказывает отображение реального TypeScript exception в `lifecycle.ts` и
отсутствие checkout/temp paths в выдаваемом diagnostic.

Incremental reload сначала компилирует и проверяет signature под временным component id, затем
probe-инстанцирует каждый реально используемый export с изолированным state. Старый component и
его instances остаются рабочими при compile, policy или probe failure. Только после успешной
проверки candidate атомарно заменяет compiled component; каждый старый instance получает ровно
один `unmount`, новый — `create/mount`. Linear memory, handles, timers и subscriptions создаются
заново, а module-scoped `vrweb:state` Dictionary сохраняется и передаётся replacement instances.

Platform matrix описана в `.github/workflows/wasm-runtime.yml`; один и тот же набор component
fixtures собирается и запускается в Godot на macOS, Windows и Linux. Та же matrix проверяет
каноническую byte-identical упаковку, hostile `.vrmod` corpus и clean-project Maker Kit export
без установленного runtime addon, а также одинаковый/изменённый module hash между двумя реальными
WebRTC peers. После editor integration matrix устанавливает официальный export template, создаёт
debug client и повторяет минимальный `.vrmod` lifecycle уже из экспортированного executable.
Затем два экспортированных процесса проходят compatible/mismatch, navigation с новым descriptor
handshake и смену authority на identity реально собранного JavaScript `.vrmod`.
