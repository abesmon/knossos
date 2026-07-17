# VRWeb WASM Module Format v1

> **Статус: working draft.** До первого стабильного релиза обратная совместимость редакций
> документа не гарантируется.

## Объявление в документе

```html
<VRWebModule id="example.door" src="./door.vrmod"
             integrity="sha256-..." runtime="wasm-component"/>
<VRWebComponent module="example.door" export="Door"/>
```

`VRWebModule` объявляет artifact identity и доставку. `VRWebComponent` создаёт instance export;
его родительский VRWML node становится owned root, переданным в `mount`. Идентификатор runtime
имеет единственное значение `wasm-component`. Inline executable source стандартом не определён.

Для artifact без assets допускается прямой content-addressed Component. В этом случае canonical
manifest передаётся как JSON в атрибуте `manifest`; `component` обязан быть `module.wasm`:

```html
<VRWebModule id="example.door" src="./door.wasm"
  integrity="sha256-..."
  manifest='{"format":1,"id":"example.door","runtime":"wasm-component","world":"vrweb:module@1","component":"module.wasm","exports":{"Door":{"kind":"scene-component"}},"requires":["vrweb:core/1","vrweb:scene/1"],"optional":[]}'/>
```

Metadata проходит тот же manifest validator, а bytes — ту же same-origin/cross-origin integrity
policy и immutable cache. Отдельный manifest URL не допускается: это исключает гонку двух
независимо загружаемых ресурсов. Assets и debug sidecar требуют `.vrmod`.

## Package

`.vrmod` — ZIP с безопасными относительными путями:

```text
vrweb-module.json
module.wasm
assets/...
```

Минимальный manifest:

```json
{
  "format": 1,
  "id": "example.door",
  "version": "1.0.0",
  "sdk": "1.0.0",
  "runtime": "wasm-component",
  "world": "vrweb:module@1",
  "component": "module.wasm",
  "exports": {
    "Door": {"kind": "scene-component"}
  },
  "requires": ["vrweb:core/1", "vrweb:scene/1"],
  "optional": ["vrweb:input/1"],
  "limits": {
    "fuel": 500000,
    "memory_bytes": 8388608,
    "deadline_ms": 25,
    "host_calls": 32
  },
  "assets": {
    "open": {"path": "assets/open.ogg", "type": "AudioStream"}
  },
  "debug": {"source_map": "debug/module.wasm.map"}
}
```

`component` обязан указывать ровно на один file внутри package. Native libraries, core-module
вместо Component, абсолютные пути, traversal, case-collisions и незаявленные executable entries
отклоняются. `exports.*.kind` v1 принимает только `scene-component`.

Optional `sdk` фиксирует версию authoring facade/bindings, использованную при сборке. Она нужна
для diagnostics и воспроизводимости toolchain, но не добавляет capabilities и не заменяет
совместимость `world`: loader принимает решение по фактическим imports и ABI major.

`limits` является optional запросом внутри локальных hard maxima клиента. Без него используются
консервативные defaults; более тяжёлый language adapter может явно запросить больший fuel, но не
может изменить deadline, память или иной предел сверх policy клиента. V1 допускает
`fuel`, `memory_bytes`, `deadline_ms`, `host_calls`, `instances`, `tables` и `memories`. Нулевые,
отрицательные, дробные, неизвестные и превышающие local maxima значения отклоняют manifest.
Отсутствующие значения получают локальные defaults; manifest не может расширить policy клиента.

## Integrity и cache

Клиент вычисляет SHA-256 загруженного artifact до validation/instantiation и повторно связывает
этот hash с байтами при распаковке: локальный cache path сам по себе не является authority.
Cross-origin artifact требует SRI; несовпадение является hard deny. Immutable artifact storage
может дедуплицировать одинаковые bytes, но key производного execution/compiled cache включает
artifact hash, runtime, полное имя world, ABI major и module id. Поэтому два module id с
одинаковыми bytes не разделяют результат validation/compilation. Скомпилированный cache конкретной
VM не является частью формата.

Source language, compiler и debug metadata могут присутствовать как несемантические audit fields,
но не влияют на совместимость или исполнение.

Optional `debug.source_map` объявляет единственный package-local `.map` sidecar. Loader проверяет
безопасный путь и наличие файла, но sidecar не становится import/capability и не читается guest-ом.
Любой незаявленный package entry отклоняется, поэтому debug metadata нельзя использовать для
file smuggling. Production packager должен исключать sidecar, если его `sources` раскрывают
локальные абсолютные пути; относительные creator paths допустимы только в явной debug-сборке.

Референсный canonical packager вызывается после получения готового Component:

```bash
python3 tools/build_vrmod.py \
  --manifest path/to/vrweb-module.json \
  --output dist/example.vrmod
```

Он включает только `component` и assets, объявленные manifest, сортирует entries, использует
фиксированные ZIP metadata и `stored` encoding. Поэтому два запуска с одинаковыми входными
байтами создают byte-identical artifact независимо от текущего времени и настроек ZIP utility.
