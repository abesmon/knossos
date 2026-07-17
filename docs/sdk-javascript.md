# JavaScript/TypeScript SDK для VRWeb WASM

> **Статус: experimental authoring adapter.** Нормативной границей остаётся WIT и Component;
> конкретный JS engine не требуется клиентам VRWeb.

Первый creator-facing путь использует локально закреплённые Bytecode Alliance Jco 1.25.2,
ComponentizeJS 0.21.0 и TypeScript 5.9.3. Jco `componentize` превращает ES module и WIT world в self-contained
WebAssembly Component. В Knossos при этом нет отдельного JS API или JS VM — результат проходит
тот же loader, capability policy и Wasmtime linker, что низкоуровневые conformance fixtures.

## Сборка fixture

```bash
python3 tools/generate_wasm_sdk.py
cd sdk/javascript
npm ci --ignore-scripts
npm run build:fixture
```

`--disable=all` запрещает добавление WASI clocks/random/http/stdio/fetch-event. Build проверяет
извлечённый WIT fingerprint и hard-fail-ит при любом `wasi:*` import, генерирует TypeScript guest
types и упаковывает Component в canonical `.vrmod`. Перед componentization pinned esbuild 0.28.1
сводит относительные ES modules и TypeScript в один ESM, оставляя `vrweb:*` imports внешними.
Каждая capability facade лежит в side-effect-free модуле. После tree-shaking adapter извлекает
реально оставшиеся `vrweb:*` imports и создаёт для componentization временный минимальный WIT
world. Поэтому импорт `core` не расширяет готовый Component до всего Scene/State API. Любой
оставшийся import, отсутствующий в `requires`/`optional` manifest, отклоняется до componentization;
финальный extracted WIT проверяется повторно. Полный SDK WIT остаётся источником bindings и
переносимого API, а минимальный build-world является только ограничением authority артефакта.
Перед этим `tsc --noEmit` со strict-профилем проверяет creator source и SDK declarations.
Manifest содержит `sdk: "1.0.0"`.

Fixture экспортирует `create/mount/event/unmount`, импортирует только `vrweb:*` interfaces и
проходит настоящий delivery → cache → manifest → capability → lifecycle путь Knossos. Event
проверяет наблюдаемый byte-list контракт WIT `list<u8>`. Facade типизирует его как `Uint8Array`;
fixture не полагается на `instanceof`, потому что prototype identity зависит от JS realm adapter-а.

## Воспроизводимость и размер

Source, npm lockfile, generated bindings и точный WIT fingerprint воспроизводимы и проверяются
`npm run check`. Сам ComponentizeJS/Wizer snapshot в версии 0.21.0 не byte-reproducible: два
локальных запуска с одинаковыми входами дали разные component SHA-256, включая после `jco opt`.
Поэтому `dist/build-evidence.json` честно записывает `byte_reproducible: false`, tool versions,
source/lock/WIT/component hashes. `.vrmod` каноничен относительно конкретных component bytes.

Текущий минимальный self-contained fixture занимает около 12 МБ: внутрь входит SpiderMonkey.
Это главный измеренный минус против компактного Rust/WAT ABI-oracle и причина, по которой Javy или
shared-engine схема остаются кандидатами на будущую оптимизацию, а не меняют runtime standard.

Representative measurement на macOS arm64, debug Knossos, cold process (не нормативный budget):

| Показатель | Значение |
|---|---:|
| Component bytes | 12 631 001 |
| ComponentizeJS build | 3 563 ms |
| Wasmtime cold prepare двух components | 176 611 ms |
| Первый JS instantiate | 8 ms |
| Scene/state event | 1 541 µs |

Build сохраняет `component_bytes` и `componentize_ms` в evidence, integration test печатает
остальные значения для каждого CI host. Конкретные числа не являются частью VRWeb compatibility:
особенно cold prepare зависит от debug/release profile, CPU и engine cache.

Для проверки независимости от языка `sdk/rust` собирает второй компонент из того же WIT через
закреплённый `wit-bindgen`. Интеграционный тест сравнивает наблюдаемый lifecycle trace Rust и
TypeScript byte-for-byte на уровне кодов событий; Rust oracle не добавляет отдельный runtime API.

## Supply-chain оговорка

`npm audit` для актуальной пары toolchain сообщает critical advisory в транзитивном
`@bytecodealliance/weval → decompress` (archive traversal). Обычная сборка не включает AOT и не
вызывает загрузку Weval binary, установка выполняется с `--ignore-scripts`, версии и integrity
закреплены lockfile. Тем не менее этот adapter нельзя переводить из experimental в рекомендуемый,
пока upstream graph не устранит advisory или мы не изолируем toolchain отдельным доверенным
bundle/container. Это build-time риск; пакет и Knossos runtime не содержат npm dependencies.

Hostile gate отдельно доказывает: `window`, `document` и `process` отсутствуют; Node filesystem
import не собирается neutral bundler-ом; extracted WIT не содержит WASI, поэтому наличие JS-имени
`fetch` не создаёт HTTP authority; infinite loop и heap growth останавливаются fuel/deadline и
memory policy без повреждения следующего instance.
