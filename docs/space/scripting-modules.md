# VRWML scripting modules

> **Статус:** working draft. Единственный executable runtime VRWeb — WebAssembly Component Model.
> Knossos уже распознаёт и проверяет delivery contract; native backend пока optional и при его
> отсутствии компонент локально деградирует, не ломая статическую сцену.

Страница объявляет готовый component package и связывает его export с узлом:

```html
<VRWebModule id="acme.lights" src="./lights.vrmod"
             integrity="sha256-BASE64..."
             runtime="wasm-component" world="vrweb:module@1"/>

<vrwml>
  <VRWebComponent module="acme.lights" export="LightSwitch" name="HallLight"/>
</vrwml>
```

`.vrmod` — ZIP без native libraries. В нём ровно один component binary и manifest:

```text
vrweb-module.json
module.wasm
assets/click.ogg
```

```json
{
  "format": 1,
  "id": "acme.lights",
  "runtime": "wasm-component",
  "world": "vrweb:module@1",
  "component": "module.wasm",
  "exports": {"LightSwitch": {"kind": "scene-component"}},
  "requires": ["vrweb:core/1", "vrweb:scene/1"],
  "optional": ["vrweb:state/1", "vrweb:input/1"]
}
```

Исходный язык не входит в формат. Rust, JavaScript и любой другой toolchain допустимы, если
результат является совместимым component. Исходники и вложенная language VM не требуются host-у.

Загрузка разделена на независимые слои: collector → fetch → integrity → content-addressed cache →
package validation → runtime backend. Cross-origin artifact требует точного SRI; same-origin
artifact всегда получает фактический SHA-256. Unpacker отклоняет traversal, лишний `.wasm`, native
library и manifest, не совпадающий с document declaration.

Для одиночного Component без assets разрешён прямой `src="./module.wasm"` с обязательным
canonical JSON manifest в атрибуте `manifest`. Host валидирует metadata тем же validator,
повторно связывает cached bytes с SHA-256 и материализует логическое имя `module.wasm`; отдельный
manifest URL, native sidecars и неявные assets в этом режиме запрещены.

Runtime не получает WASI по умолчанию. Все полномочия выражены versioned WIT imports; scene
references являются opaque handles с ownership и lifetime checks. Неизвестный required import,
несовместимый world или отсутствующий backend останавливают только компонент. Навигация вызывает
`unmount`, освобождает instance и закрывает backend.

Multiplayer page identity включает отсортированный список `(module id, runtime, world major,
artifact hash)`. Knossos хеширует canonical список в room key: клиенты с другими executable bytes
не попадают в одну replicated-state room и не принимают component от пира. Exact local identity
имеет outcome `compatible`; отсутствие optional native runtime при том же document identity явно
логируется как `degraded/runtime_unavailable`; различие tuples классифицируется
`rejected/module_identity_mismatch`.

После открытия P2P data channel peers дополнительно обмениваются bounded descriptor `{identity,
runtime_available, capabilities}` без component bytes. Replicated commands, deltas, snapshots и
samples закрыты до outcome `compatible`; mismatch и отсутствующая required capability дают
`rejected`/`degraded` и видимую network diagnostic. Descriptor state очищается при disconnect,
поэтому late join и reconnect всегда проходят handshake заново; смена authority не обходит gate.
Executable bytes каждый peer по-прежнему получает только через document delivery и проверяет по
локальному hash.

Полные нормативные документы: [runtime](wasm-runtime.md), [module format](wasm-module-format.md),
[scene API](wasm-scene-api.md). Реализация по атомарным отсечкам ведётся в
[roadmap](../roadmap.md#p3--стандартный-wasm-sandbox).
