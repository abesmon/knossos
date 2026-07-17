# Выбор Godot WASM runtime для Knossos

> **Статус:** принятое решение для reference implementation, аудит и maintenance review от
> 2026-07-16.

VRWeb не стандартизует конкретную VM или GDExtension. Но Knossos не должен самостоятельно
реализовывать общую интеграцию Wasmtime с Godot, если эту работу можно переиспользовать.

## Требования Knossos

Готовая основа должна обеспечивать:

- Godot 4 GDExtension и desktop targets macOS, Windows и Linux;
- WebAssembly Component Model, а не только core modules;
- отдельный Store на instance, memory limits и прерывание зависшего guest;
- возможность связать типизированные imports из WIT с host implementation;
- отсутствие WASI и прямого Godot Object API по умолчанию;
- возможность оставить `vrweb:*` WIT packages единственной публичной границей стандарта.

## Рассмотренные реализации

### `ashtonmeuser/godot-wasm`

Проверена revision `196ddf5e4e5a230c1c29d634124915a52b930b0e` и release
`v0.5.0-godot-4`.

Проект является хорошей готовой GDExtension для **core WebAssembly**: поддерживает Wasmtime и
Wasmer, импорт функций Godot через dictionary и публикует готовые desktop artifacts. Однако он
использует общий C API `wasm.h`, один singleton Store для всех modules и числовой core ABI
`i32/i64/f32/f64`. Component Model, WIT linker, per-instance budgets и typed canonical ABI в нём
отсутствуют. WASI Preview 1 включён по умолчанию, хотя в текущем release extensions можно
отключить.

Чтобы использовать эту библиотеку с нормативным VRWeb WIT contract, пришлось бы самостоятельно
реализовать Canonical ABI и почти полностью заменить её runtime core. Поэтому она **не выбрана**.
Она остаётся подходящим вариантом только если VRWeb когда-либо откажется от Component Model в
пользу собственного core-WASM ABI.

Источники: [README](https://github.com/ashtonmeuser/godot-wasm/blob/196ddf5e4e5a230c1c29d634124915a52b930b0e/README.md),
[singleton Store](https://github.com/ashtonmeuser/godot-wasm/blob/196ddf5e4e5a230c1c29d634124915a52b930b0e/src/store.h),
[runtime implementation](https://github.com/ashtonmeuser/godot-wasm/blob/196ddf5e4e5a230c1c29d634124915a52b930b0e/src/wasm.cpp),
[release v0.5.0](https://github.com/ashtonmeuser/godot-wasm/releases/tag/v0.5.0-godot-4).

### `Dheatly23/godot-wasm`

Проверена revision `b2940a12da43638d32dabf8e8ba9dbc9cd6eda41`.

Проект уже решает большую часть ненормативной инфраструктуры Knossos:

- Rust GDExtension на `godot-rust` и Wasmtime;
- optional Component Model;
- epoch timeout и memory limiter;
- отдельные instance/store abstractions;
- загрузку, валидацию и precompile components;
- WIT-based экспериментальный Godot API с фильтрацией операций;
- Apache-2.0 license.

Ограничение существенно: публичный generic `WasmInstance` пока не умеет инстанцировать component,
а README прямо относит binding произвольных host functions в component к будущей работе.
Component запускается только через заранее скомпилированные linker paths: WASI command или
встроенный широкий `godot:*` world. Готовых releases нет; официально протестированы только
Windows/Linux x86, а macOS targets перечислены, но не подтверждены автором.

Встроенный `godot:*` world нельзя напрямую выдавать недоверенному VRWeb content. Он содержит
reflection, произвольные `Object.call/get/set`, globals и resource handles. Method filter полезен
как reference и может быть переиспользован внутри host, но сам по себе не обеспечивает page-root
scope, ownership handles и VRWeb capability contract.

Источники: [README](https://github.com/Dheatly23/godot-wasm/blob/b2940a12da43638d32dabf8e8ba9dbc9cd6eda41/README.md),
[Cargo features](https://github.com/Dheatly23/godot-wasm/blob/b2940a12da43638d32dabf8e8ba9dbc9cd6eda41/Cargo.toml),
[component import restriction](https://github.com/Dheatly23/godot-wasm/blob/b2940a12da43638d32dabf8e8ba9dbc9cd6eda41/src/wasm_engine.rs),
[Godot component linker](https://github.com/Dheatly23/godot-wasm/blob/b2940a12da43638d32dabf8e8ba9dbc9cd6eda41/src/godot_component/mod.rs),
[Godot Object WIT](https://github.com/Dheatly23/godot-wasm/blob/b2940a12da43638d32dabf8e8ba9dbc9cd6eda41/wit/deps/core/object.wit).

## Maintenance review

После сравнения реальной площади кода переход на fork признан невыгодным на текущем этапе.

`native/vrweb_wasm_runtime` содержит около 700 строк Rust и напрямую использует официальные crates
Wasmtime и `godot-rust`. Это не собственная реализация VM, Component Model или Canonical ABI.
Собственный код является product-specific adapter: lifecycle, точные VRWeb imports, budgets,
diagnostics и Godot-facing methods. Именно эти части пришлось бы поддерживать и внутри fork.

В зааудированной revision `Dheatly23/godot-wasm` около 25 000 строк Rust. Большая часть реализует
core WASM, WASI, filesystem, object registry, GC/externref, generic Godot reflection и editor-facing
resources — возможности, которые VRWeb либо не использует, либо намеренно запрещает. Минимальная
сборка уменьшает binary, но не уменьшает стоимость синхронизации fork и security review.

Переход сэкономил бы в основном общие участки инициализации Engine/Store, limiter, epoch thread и
часть packaging — ориентировочно несколько сотен строк. Он не сэкономил бы VRWeb WIT linker,
preflight, host-call budget, lifecycle state machine, Scene Authority, handle ownership и
conformance fixtures. При этом отсутствующий generic component host-linking пришлось бы добавлять
в центральные `wasm_engine`, `wasm_instance`, StoreData и feature definitions upstream-проекта.

Дополнительная стоимость fork:

- разрешение конфликтов при регулярных обновлениях Wasmtime и `godot-rust` upstream-проектом;
- синхронизация с его Godot 4.3 git revision против используемого Knossos Godot 4.6 crate release;
- повторный аудит широких Wasmtime features, включая threads, GC, SIMD и memory64;
- поддержка собственного feature combination, который upstream не считает стабильным;
- собственная проверка macOS, потому что upstream официально тестирует только Windows/Linux x86;
- отсутствие готовых releases и совместимого public extension point для VRWeb component linker.

## Решение

Knossos **не переходит на fork сейчас**. Остаётся небольшой прямой adapter над официальными
Wasmtime и `godot-rust`, потому что это даёт меньшую площадь сопровождения и позволяет обновлять
две upstream dependencies без синхронизации третьей кодовой базы.

Из `Dheatly23/godot-wasm` можно переиспользовать архитектурные решения, hostile cases и отдельные
подходы к limiter/epoch handling после проверки лицензии и применимости, но не vendoring всего
runtime. Встроенный `godot:*` world не становится VRWeb API.

Решение пересматривается, если выполнено хотя бы одно условие:

- upstream публикует стабильный generic API для подключения произвольного WIT component linker
  без изменения его engine/store internals;
- собственный handwritten native adapter превышает примерно 3 000 строк из-за общей runtime
  инфраструктуры, а не из-за VRWeb policy или generated bindings;
- Knossos действительно понадобятся core WASM, WASI, generic Godot reflection или другие крупные
  возможности upstream;
- появляется поддерживаемая библиотека/extension, которая проходит VRWeb conformance suite
  неизменённой и имеет подтверждённую desktop platform matrix.

До этого момента обновления Wasmtime и `godot-rust` выполняются отдельными атомарными изменениями с
hostile/conformance suite. Размер handwritten native adapter отслеживается в release review, чтобы
решение не превратилось в бессрочное исключение.
