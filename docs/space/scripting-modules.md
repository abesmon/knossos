# VRWeb scripting modules: пользовательские классы и скрипты

> **Статус: базовый trusted runtime vertical slice реализован.** Inline, внешний `.gd` и
> package `.vrmod` проходят общий navigation/runtime pipeline; работают integrity/cache,
> exact-hash trust UI, lifecycle, public context API, manifest-declared assets и
> воспроизводимый package-demo. До trusted MVP остаются multiplayer module compatibility,
> navigation/redirect hardening, полная asset/platform matrix и E2E. Декларативные
> `<VRWebReplicatedState>`/`<VRWebStateAction>` остаются простым уровнем расширения и не
> заменяют пользовательский код.

## Задача и граница безопасности

Автор страницы должен поставлять собственные классы, сцены и ассеты без изменения Knossos.
Но необходимо честно разделить два режима:

1. **Полная мощность Godot:** обычный GDScript может создавать любые узлы и пользоваться всем
   API движка, но получает права процесса клиента. Запуск — только после доверия origin.
2. **Ограниченный код:** видит только capability API Knossos. Для этого нужна отдельная среда;
   обычный GDScript песочницей не является.

Поле `permissions` или поиск запрещённых слов не делают GDScript безопасным: остаются прямые и
рефлексивные пути к `FileAccess`, `OS`, сети и autoload клиента.

## Поставка: content-addressed `.vrmod`

Страница подключает модуль, а затем создаёт экспортированный им класс:

```html
<VRWebModule id="acme.lights" src="./lights.vrmod"
             integrity="sha256-BASE64..." mode="trusted-gdscript"/>
<VRWebComponent module="acme.lights" class="LightSwitch"
                state_id="hall-light" transform="..."/>
```

`lights.vrmod` — ZIP без нативных библиотек:

```text
vrweb-module.json
scripts/light_switch.gd
scenes/light_switch.tscn
assets/click.ogg
```

Минимальный манифест:

```json
{
  "format": 1,
  "id": "acme.lights",
  "version": "1.2.0",
  "knossos_api": "1",
  "runtime": "trusted-gdscript",
  "exports": {
    "LightSwitch": {"script": "scripts/light_switch.gd", "base": "Node3D"}
  },
  "permissions": ["network:origin", "storage:module"]
}
```

`id` — namespace автора, не глобальный `class_name` Godot. `exports` — единственные классы,
видимые странице. Модуль вместо отдельного `script="https://…"` нужен потому, что зависимости,
сцены и ассеты получают одну версию и hash; можно проверить все пути и лимиты; кэш не зависит
от изменяемого URL; классы разных сайтов не сталкиваются.

## Маленький скрипт прямо в HTML

Для одного самодостаточного класса `.vrmod` не обязателен. Используется обычный HTML
`<script>` с отдельным MIME type; JavaScript клиента такой блок исполнять не должен:

```html
<script type="application/vrweb+gdscript"
        id="light-switch" data-base="Node3D" data-mode="trusted-gdscript">
extends Node3D

func mount(context):
    context.log.info("light switch mounted")
</script>

<vrweb>
  <VRWebComponent module="#light-switch" class="default" transform="..."/>
</vrweb>
```

Это не второй loader: клиент синтезирует в памяти однофайловый module manifest с export
`default`, а дальше использует тот же compile/trust/lifecycle pipeline, что `.vrmod`. Identity
inline-модуля — `(canonical page URL, script id, sha256 точного raw-text)`. Изменение кода меняет
hash, но решение о доверии всё равно относится к origin и runtime-классу.

Как в HTML, поддерживается и маленький внешний однофайловый скрипт:

```html
<script type="application/vrweb+gdscript" id="light-switch"
        src="./light_switch.gd" integrity="sha256-BASE64..."
        data-base="Node3D" data-mode="trusted-gdscript"></script>
```

Ограничения single-file формы:

- один export `default`; для нескольких классов, сцен, ассетов и зависимостей нужен `.vrmod`;
- одновременно `src` и inline body запрещены;
- inline body с буквальным `</script` использовать нельзя по правилам raw-text HTML;
- `src` подчиняется той же origin policy, integrity и cache, что пакет;
- MIME без `application/vrweb+gdscript` игнорируется Knossos: обычный JavaScript не исполняется;
- inline GDScript остаётся trusted-кодом, а не становится безопаснее из-за малого размера.

Поставляемые ручные примеры `vrwebresource://inline_script.html` и
`vrwebresource://external_script.html` не только материализуют компонент: `_ready()` их
скриптов вычисляет подпись через `answer()` и меняет текст/цвет дочернего `Label3D`. Поэтому
исполнение кода видно непосредственно в сцене. Обе exclusive-сцены также содержат собственный
видимый `BoxMesh`-пол со `StaticBody3D` и `BoxShape3D`, чтобы игрок не падал в void.

## Загрузка и связывание

1. `src` разрешается относительно страницы; HTTP по умолчанию same-origin.
2. До распаковки проверяются размер и `integrity`, после — число файлов, распакованный размер,
   ZIP traversal, абсолютные пути и symlink-подобные записи.
3. Модуль кладётся в content-addressed каталог кэша. Его нельзя монтировать через
   `ProjectSettings.load_resource_pack`: pack способен перекрыть существующие `res://`-пути.
4. Ссылки разрешаются только внутри корня модуля. Логический `module://...` преобразуется в
   приватный путь конкретного hash; `res://` в поставляемом коде/сценах запрещается loader'ом.
5. `<VRWebComponent>` создаёт заявленный base node, присоединяет Script и только затем применяет
   атрибуты. Export также может указывать на `PackedScene`.
6. Навигация удаляет экземпляры страницы. Ключ Script/Resource cache включает hash, поэтому
   новая версия не получает старый код.

### Принятая integrity policy

Integrity и разрешение исполнения — независимые проверки.

| Источник модуля | `integrity` | Несовпадение |
|---|---|---|
| тот же origin, что страница | необязателен | предупреждение об изменившемся/неожиданном hash; не является автоматическим hard deny |
| другой origin | обязателен | hard deny: модуль не компилируется и не запускается |
| inline body | не нужен | сам body уже входит в документ; всегда вычисляется фактический hash |

Даже без атрибута Knossos всегда вычисляет SHA-256 артефакта, использует его как cache key,
показывает в preflight и включает в multiplayer compatibility. Для same-origin предупреждение
возникает при несовпадении явно указанного integrity либо при изменении ранее известного hash
того же module identity. Exporter по возможности пишет integrity и для same-origin.

Hard deny cross-origin нельзя отменить trust-настройкой: доверие разрешает исполнить конкретный
валидный артефакт, но не разрешает CDN отдать байты, отличные от зафиксированных страницей.

В поставляемом GDScript запрещается `class_name`: внешнее имя задаёт manifest. Внутренние
импорты проходят через module-local resolver.

## Runtime-режимы

### `trusted-gdscript` — первый вертикальный срез

Это обычный GDScript со всей мощностью Godot. Перед первым запуском клиент показывает origin,
module id/hash и предупреждает, что код получает права Knossos. Решения пользователя:

- запретить;
- разрешить один раз;
- доверять этому origin;
- позже просмотреть и отозвать доверие.

`permissions` здесь — декларация для UI, не security boundary: raw GDScript способен обойти
любой facade.

## Режимы разрешения скриптов

Заранее закладываются три режима; их UI и persistence реализуются после module loader:

> **Временное решение прототипа:** до отдельной feature-доработки trust UX клиент использует
> `ALLOW_ALL`. Это не безопасный default для production. Preflight UI, persistent fingerprints,
> domain rules, trust lists и revoke объединены в обязательный milestone перед публичным
> использованием произвольных страниц.

| Режим | Поведение |
|---|---|
| **Все скрипты разрешены** | после integrity-проверок модули запускаются автоматически; изменения same-origin всё равно показываются предупреждением |
| **Только выбранные разрешены** | неизвестные/изменившиеся hashes останавливают загрузку на preflight; пользователь изучает и принимает отдельные элементы либо все элементы страницы |
| **Ничего не разрешено** | executable modules не скачиваются дальше необходимого metadata либо не компилируются; декларативная/статическая часть может быть показана только после явно выбранной UX-политики |

В режиме «только выбранные» порядок загрузки такой:

```text
fetch HTML → parse/collect → download bytes (без компиляции) → integrity → trust lookup
           → review неизвестных/изменившихся → решения пользователя → compile → materialize
```

До завершения review полноценная сцена страницы не создаётся. Экран показывает module id,
тип (inline/script/package), page origin, delivery origin, фактический и заявленный hashes,
версию/permissions и источник уже найденного доверия. Действия: принять один, отклонить один,
принять все на странице; постоянное доверие должно быть отдельным осознанным действием.

### Единицы доверия

- **Exact artifact hash** — основная и наиболее узкая запись. Одинаковая shared-библиотека
  остаётся доверенной при доставке через CDN; для `.vrmod` hash покрывает весь пакет и зависимости.
- **Module identity + hash** — отображаемая связь имени/издателя с конкретными байтами.
- **Origin/domain rule** — широкое доверие будущим модулям/версиям origin; изменение hash всё
  равно журналируется и, согласно выбранной политике, может требовать предупреждения.
- **Trust list/repository** — подписанный список `(module id, version, hash, source)` пока не
  поддерживается; работа ведётся в [едином roadmap](../roadmap.md#p2--release-confidence).
  Пользователь явно подписывается на список. Домашний сервер может публиковать или рекомендовать
  такие списки, но сервер не должен незаметно менять локальный режим пользователя.

Подпись списка подтверждает издателя списка; exact hash подтверждает выбранные байты; ни то ни
другое не делает код безопасным. Отзыв trust list или доменного правила влияет на следующие
загрузки, а активная страница получает отдельную политику остановки/перезагрузки позже.

### `sandboxed` — целевой режим недоверенных страниц

Он исполняет не raw GDScript в основном `SceneTree`, а код в отдельном runtime с opaque handles
и capability API. Это не часть trusted GDScript и не требуется для первого релиза модулей.

WebAssembly здесь упоминается **не как браузерная технология**, а как один из форматов
переносимого байткода для встраиваемой desktop-VM (например, Wasmtime/Wasmer можно встроить в
нативное приложение). Минус для Knossos существенный: автор уже не сможет просто положить
GDScript со страницы — ему понадобится компиляция в `.wasm` и другой SDK. Поэтому WASM лишь
кандидат для далёкого sandbox spike, а не выбранное решение. Альтернативы — отдельный процесс
Godot/GDScript с IPC и ограничениями ОС либо embeddable VM с более привычным языком.

Предварительный приоритет для Knossos: сначала trusted GDScript в основном клиенте; для
песочницы сначала исследовать отдельный Godot/GDScript worker, поскольку он сохраняет язык и
инструменты автора. WASM сравнивать как технический baseline изоляции, но не принимать по
умолчанию ценой ухудшения authoring UX.

Долгосрочный host API:

```text
scene.get/set(handle, property)
scene.spawn(allowed_type, parent_handle)
events.subscribe(handle, event)
state.register/command/read
fetch.request(url)          # только с capability
storage.get/set             # namespace origin + module
clock.now / timer.start
```

Handle принадлежит странице: нет доступа к `/root`, autoload или чужой ветке. Host проверяет
типы, свойства, объём данных, память, число узлов и instruction/time budget на кадр. ABI
версионируется независимо от VM, чтобы реализации VRWeb могли поддержать один контракт.

## Что страница не может поставлять

- GDExtension, `.dll`, `.so`, `.dylib` и C# assembly — это устанавливаемый plugin клиента;
- PCK/ZIP, монтируемый в общий `res://` namespace;
- `@tool`, editor plugins и autoload;
- автоматическое доверие на основании подписи. Подпись подтверждает автора, но не безопасность.

## Стабильный API Knossos

Минимальный реализованный portable-контракт вынесен в [scripting-api.md](scripting-api.md). Новые модули
объявляют versioned `vrweb/*` capabilities; `godot/engine/4` отдельно маркирует зависимость от
trusted Godot runtime. Внутренние singleton/class/path Knossos не являются публичным API.

Даже trusted-коду нужен `KnossosPageAPI`, иначе модули привяжутся к внутренним singleton.
Первая версия: `mount(context)`/`unmount()`, своя ветка сцены, Replicated State, world input,
module-local assets, same-origin fetch, scoped storage, логирование и feature detection вида
`api.has("replicated-state/1")`. `NetworkManager` и устройство дерева клиента не являются API.

## Multiplayer

В идентичность страницы должны входить canonical URL и ordered-набор `(module id, runtime,
hash)`: разные hashes нельзя молча считать wire-совместимыми. Сейчас module identity ещё не
включена в room/page compatibility — это следующий multiplayer-инкремент. Рекомендуемый schema
id — `publisher.module/schema@major`.

Код приходит с исходной страницы/origin, не от пира. Пир может передать URL и hash, но каждый
клиент сам скачивает модуль, проверяет его и применяет собственную origin policy.

## Статус реализации

Базовый trusted runtime vertical slice реализован и описан выше. Текущий этап — multiplayer
module identity, navigation/redirect hardening, exporter/platform matrix и E2E Trusted Modules
MVP. Приоритеты, критерии готовности, зависимости и будущий sandbox ведутся только в
[едином roadmap](../roadmap.md).

## Связанные материалы

- [vrweb-tags.md](vrweb-tags.md) — декларативная сцена и уровень без пользовательского кода;
- [security.md](../security.md) — общая модель доверия;
- [replicated-state.md](../network/replicated-state.md) — сетевой state API.

Godot рассматривает GDScript как Script Resource, который можно загрузить и создать через
`new()`/`set_script`; resource packs также загружаются в runtime, но могут перекрывать пути.
Это подтверждает направление trusted-модулей, однако конкретный pipeline исходника из кэша в
export-сборке Knossos необходимо подтвердить первым spike.
