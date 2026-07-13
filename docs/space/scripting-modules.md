# VRWeb scripting modules: пользовательские классы и скрипты

> **Статус: trusted runtime prototype реализуется.** Inline, внешний `.gd` и script-only
> `.vrmod` уже проходят общий navigation/runtime pipeline; trust UI и полный asset graph
> остаются запланированными. Декларативные
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
- **Trust list/repository** — будущий подписанный список `(module id, version, hash, source)`.
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

В идентичность страницы входят canonical URL и hashes модулей: разные hashes нельзя молча
считать wire-совместимыми. Рекомендуемый schema id — `publisher.module/schema@major`.

Код приходит с исходной страницы/origin, не от пира. Пир может передать URL и hash, но каждый
клиент сам скачивает модуль, проверяет его и применяет собственную origin policy.

## Полный план реализации

Работа делится на два результата. **Trusted modules MVP** даёт авторам реальные GDScript-классы
со страницы после согласия пользователя. **Sandboxed modules** после него добавляет безопасный
автозапуск недоверенного кода. Первый результат не должен ждать выбора sandbox VM.

### Этап 0. Зафиксировать wire/document contract

- Превратить примеры этого документа в JSON Schema/валидаторы manifest format 1.
- Зафиксировать атрибуты `<VRWebModule>`, `<VRWebComponent>` и inline `<script>`; неизвестные
  поля manifest игнорировать, неизвестный major format отклонять.
- Задать лимиты: compressed/unpacked bytes, files, scripts, components, source length и время
  компиляции. Значения держать в одном `ScriptingModuleLimits`, а не размазывать по loader'ам.
- Определить canonical origin для `http(s)`, `vrweblocal` и `vrwebresource`; локальные схемы не
  должны случайно наследовать доверие интернет-origin.

**Готово, когда:** fixture-набор good/bad manifest и HTML имеет однозначный ожидаемый результат.

### Этап 1. Обязательный feasibility spike Godot

Начат в [tests/test_scripting_module_runtime.gd](../../tests/test_scripting_module_runtime.gd): probe
проверяет `GDScript.source_code/reload`, `new`, `set_script`, compile error и две версии модуля
с относительной зависимостью из `user://`.

Сделать отдельный headless/ручной probe, который:

1. записывает source в приватный каталог `user://`;
2. создаёт/загружает `GDScript`, компилирует его и проверяет ошибочный source;
3. вызывает `new()` и `Object.set_script()` на совместимом/несовместимом base;
4. загружает второй относительный `.gd`, module-local Resource и PackedScene;
5. удаляет инстанс, меняет hash/source и убеждается, что Resource cache не вернул старый Script;
6. повторяется в **exported debug/release**, а не только в editor, на macOS/Windows/Linux.

Нужно отдельно проверить, как получить структурированные compile errors с module URL/строкой.
Если source compilation в export недоступна или нестабильна, trusted runtime меняется на заранее
импортированный page bundle; внешний HTML-контракт от этого меняться не должен.

**Готово, когда:** CI-артефакты трёх платформ создают класс, ловят намеренную ошибку и проходят
hot-version test. Это блокер всей дальнейшей реализации.

### Этап 2. Module IR без исполнения

Базовая реализация: [scripting_module_collector.gd](../../scripts/scripting_modules/scripting_module_collector.gd)
собирает inline/src/package IR; [scripting_module_manifest.gd](../../scripts/scripting_modules/scripting_module_manifest.gd)
валидирует manifest format 1; [scripting_module_integrity.gd](../../scripts/scripting_modules/scripting_module_integrity.gd)
реализует принятую same-/cross-origin policy.

Добавить независимый от UI слой примерно следующей формы:

```text
ScriptingModuleDefinition  — id/runtime/hash/exports/permissions/files
ScriptingModuleCollector   — HTML <script>/<VRWebModule> -> definitions
ScriptingModuleValidator   — manifest, пути, MIME, лимиты, integrity
ScriptingModuleRegistry    — module id -> загруженная версия/exports текущей навигации
```

- `HtmlParser` уже сохраняет raw body `<script>`; collector должен брать только точный MIME
  `application/vrweb+gdscript`, не JavaScript.
- Inline и `src=.gd` превращаются в synthetic manifest с export `default`.
- Дубликат `id`, пустой id, одновременно body+src и неизвестный runtime — ошибка документа,
  но не падение всей страницы.
- Module id разрешается только внутри документа; глобального `class_name` registry нет.

**Готово, когда:** unit-тесты строят одинаковый IR для inline, single-file src и эквивалентного
`.vrmod`, не исполняя ни строки кода.

### Этап 3. Fetch, integrity, unpack и cache

Immutable content cache реализован в
[scripting_module_cache.gd](../../scripts/scripting_modules/scripting_module_cache.gd): артефакты дедуплицируются
по SHA-256, повторно проверяются при чтении и входят в общую очистку/размер `Cache`. Binary fetch,
integrity и cancel реализованы в
[scripting_module_fetcher.gd](../../scripts/scripting_modules/scripting_module_fetcher.gd). Fetcher намеренно
отклоняет redirects до появления проверки каждого нового origin. `.vrmod` проверяется и
извлекается [scripting_module_package.gd](../../scripts/scripting_modules/scripting_module_package.gd): лимиты,
безопасные/case-insensitive уникальные пути, manifest до exports и content-hash root. URL
metadata/ETag и redirect flow ещё не реализованы.

- Вынести binary fetch с cancel/generation token: переход на другую страницу обязан отменять
  старые callbacks. Не смешивать его с text-only `PageFetcher` без общего byte API.
- Проверять same-origin/CORS policy до запроса, redirect origin — после каждого финального URL.
- Проверять `integrity` до использования; для network trusted modules integrity сделать
  обязательным либо явно описать режим development без него.
- Распаковывать ZIP через validator: никакого `..`, абсолютных путей, symlink, duplicate path,
  case-fold collision и zip bomb.
- Кэшировать immutable bytes по SHA-256; отдельно хранить URL metadata/ETag. Очистка входит в
  существующую команду очистки кэша и учитывается в `Cache.total_size()`.
- Не использовать `ProjectSettings.load_resource_pack` и не давать модулю перекрыть `res://`.

**Готово, когда:** тесты покрывают wrong hash, redirect на другой origin, traversal, zip bomb,
отмену навигации, cache hit и две версии одного URL.

### Этап 4. Trust policy и UX — первый срез реализован

Вкладка «Безопасность», default-режим `ask`, агрегированный preflight и persistent exact-hash
allow/block store реализованы в `Settings`, `main` и `ScriptingModulePermissionDialog`.

- Реализованы глобальные `allow_all|ask|block_all`; default — `ask`.
- `allow once` живёт одну загрузку страницы; reload спрашивает снова.
- Один preflight агрегирует неизвестные модули и показывает страницу, resource URL, module id и
  hash (полный hash — в tooltip); compile/materialize ждут решения по всем записям.
- Persistent store хранит exact origin + module id + hash, решение, resource URL и время;
  настройки показывают allow и block, поддерживают отзыв одной записи и очистку всех.
- Runtime/permissions пакета в карточке пока не раскрыты; это следующий UX-срез.
- Без UI навигационный pipeline не должен запускаться в `ask`: headless-интеграциям следует
  явно выбирать `block_all` или `allow_all` (отдельный CLI override пока не реализован).
- Смена hash exact-trusted модуля делает его неизвестным; широкое origin trust может разрешить
  новую версию, но изменение всё равно показывается по принятой warning policy.
- Заложить import подписанных trust lists; интеграция с домашним сервером не меняет локальные
  решения без явной подписки пользователя.

**Первый срез готов:** неизвестный exact hash не компилируется до ответа, deny запоминается,
allow once не переживает reload, revoke действует со следующей загрузки. Остались широкие origin
rules, provenance/trust lists, показ permissions и автоматизированный UI integration test.

Разметка preflight является собственным modal `Window` и не зависит от внутренних дочерних
узлов Godot `ConfirmationDialog`; регрессия создания окна и безопасного default deny —
`tests/test_scripting_module_permission_dialog.tscn`.

### Этап 5. Trusted GDScript runtime и lifecycle

Первый inline-срез реализован в
[scripting_module_registry.gd](../../scripts/scripting_modules/scripting_module_registry.gd): registry принимает
явный `ALLOW_ALL|SELECTED|DENY_ALL`, компилирует только разрешённые hashes, а `VrwebBuilder`
материализует `<VRWebComponent>` только из подготовленного registry. Демо —
[inline_script.html](../../test_pages/inline_script.html). `main._finish_page` собирает inline
definitions, а после integrity `main._authorize_scripting_modules` применяет пользовательскую политику
до передачи разрешённого подмножества в registry.
Inline, single-file `src` и script exports `.vrmod` подключены к navigation pipeline.
Минимальный lifecycle реализован через
[scripting_module_context.gd](../../scripts/scripting_modules/scripting_module_context.gd): `mount(context)`
после `_ready`, однократный `unmount()` при выходе из дерева и инвалидируемые `scene_root` /
`lifecycle/1`. [scripting_module_session.gd](../../scripts/scripting_modules/scripting_module_session.gd)
разделяет общие сервисы экземпляров одного module/hash; state закрывается только после ухода
последнего компонента. `context.state` реализован в
[scripting_module_state_api.gd](../../scripts/scripting_modules/scripting_module_state_api.gd): namespaced
schema/object, command/read/revision/subscriptions и автоматическая очистка. `context.timers`
реализован в [scripting_module_timer_api.gd](../../scripts/scripting_modules/scripting_module_timer_api.gd):
таймеры принадлежат конкретному component context и отменяются до его инвалидирования при
`unmount`. `context.assets` реализован в
[scripting_module_asset_api.gd](../../scripts/scripting_modules/scripting_module_asset_api.gd): он открывает
только логические имена из `manifest.assets`, проверяет module-local путь и заявленный тип
Resource, ограничивает raw-чтение 8 MiB и инвалидируется вместе с component context. Package
validator требует физического наличия каждого объявленного asset. Exporter добавляет literal
relative non-`.gd` зависимости `load()`/`preload()` в `manifest.assets`; текстовые `.tscn/.tres`
обходятся рекурсивно, их `res://`-ссылки переписываются в module-local relative paths, известный
Resource type сохраняется. Распространённые imported source assets (image/audio/glTF) exporter
преобразует в bundled `.res` и переписывает ссылку, чтобы runtime не зависел от проектного
import cache; SVG round-trip покрыт тестом. Scene exports, полная platform/format matrix и
сложные import options ещё не реализованы. Minimal portable facade `scene`, `state`, `input`,
`assets`, `timers`, `log`, `features`, manifest `requires/optional` и `godot/engine/4` реализованы и описаны в
[scripting-api.md](scripting-api.md); `fetch/storage` ждут первого реального потребителя.

- Компилировать только после validation+trust; ошибки одного модуля не ломают статическую сцену.
- Для dependency resolution использовать приватный корень конкретного hash и относительные
  пути. Запрет `res://` в trusted GDScript нельзя считать security boundary: raw-код всё равно
  полноправный; это проверка переносимости и namespace.
- Реализовать `<VRWebComponent>` как отложенную точку монтажа. Внешние module fetch должны
  завершиться до materialization либо заменяться стабильным placeholder — выбрать один порядок
  и покрыть гонки навигации.
- Проверять manifest base против фактического base Script/PackedScene до присоединения.
- Lifecycle: создать root → передать context → `mount(context)` → работа → `unmount()` → удалить
  сигналы/timers/nodes при refresh/navigation/error. Повторный unmount идемпотентен.
- Ограничить module ownership веткой компонента на уровне facade, хотя trusted code технически
  может её обойти.

**Готово, когда:** inline и package классы создаются, два модуля с одинаковыми внутренними
именами сосуществуют, compile/mount error локализован, refresh не оставляет timers/signals/nodes.

### Этап 6. `KnossosPageAPI` версии 1

Реализованы versioned `vrweb/core/1`, `scene/1`, `state/1`, `input/1`, `assets/1`, `timers/1`,
`log/1`, `features/1` и Godot runtime extension; старые имена оставлены aliases. State facade
принадлежит module-level session, поэтому несколько components не снимают схемы друг у друга.

Сделать отдельные facade-объекты, выдаваемые через context, а не ссылку на `main`/autoload:

- `scene` — минимальные root/find/is_valid для ветки компонента реализованы;
- `state` — register/read/command/unregister Replicated State;
- `input` — `on_activate/off_activate` для collider ветки без зависимости от `Player` реализованы;
- `assets` — module-local manifest-declared Resource/text/bytes реализованы; same-origin URL и
  автоматический asset graph ещё нет;
- `fetch` — same-origin запросы;
- `storage` — namespace `(origin,module)` с quota;
- `log` и lifecycle-safe timers реализованы;
- `features.has/require("vrweb/name/version")` реализованы.

Для trusted runtime это compatibility boundary, не security boundary. Все facade должны терять
валидность после unmount, чтобы поздний callback не менял следующую страницу.

**Готово, когда:** модульный переключатель использует только context API; в его исходнике нет
`NetworkManager`, `BlobStore`, `main` и абсолютных NodePath клиента.

### Этап 7. Интеграция в navigation и multiplayer

- В `main` добавить pipeline: parse HTML → collect definitions → fetch/validate → trust → compile
  → build/materialize. Каждая стадия проверяет navigation generation token.
- Loading/cancel UI показывает текущую стадию и модуль с ошибкой.
- Room/page identity включает ordered `(module id, runtime, hash)`; mismatch виден пользователю
  и не допускает молчаливой регистрации несовместимой replicated schema.
- Пиры не пересылают executable bytes как авторитетный источник: URL/hash приходят от документа,
  скачивание и policy выполняет каждый клиент.

**Готово, когда:** два клиента с одинаковыми hashes синхронизируют модульный переключатель;
клиент с другим hash получает явный compatibility outcome.

### Этап 8. Доработать `vrweb_tools`

Inline opt-in и warning для невыбранного Script реализованы; round-trip проверяет
[test_inline_export.tscn](../../tests/test_inline_export.tscn). Первый package-срез также
реализован: кнопка dock выставляет режим, exporter собирает основной GDScript и literal relative
`.gd` и literal relative files из `load()`/`preload()` в `.vrmod`, пишет manifest/assets и
SHA-256 integrity, а
[test_package_export.tscn](../../tests/test_package_export.tscn) загружает результат через
обычный Builder/registry. Полная поддержка ещё требует:

- metadata/Inspector UI для явного module id; `off`/`inline`/`package` доступны в dock;
- усилить inline dependency validation; структурированный export report уже возвращает
  errors/warnings и package file/hash/integrity/files/assets, а plugin не пишет HTML при ошибке;
- проверить bundled imported assets по format/platform matrix, добавить сложные import options
  и сделать ZIP полностью deterministic;
- никогда автоматически не включать editor scripts, `@tool`, autoload, native libs или файлы
  вне выбранного dependency graph;
- дополнить export report permissions и более подробными skipped-file reasons;
- preview/run exported page через тот же runtime клиента, а не отдельный упрощённый loader.
- добавить в `test_pages/index.html` пользовательский package-demo переключателя: страница и
  `.vrmod` должны быть self-contained, пакет содержать GDScript/сцену/ассеты, а рядом должна
  быть воспроизводимая инструкция или fixture для пересборки встроенным exporter;

**Готово, когда:** editor-сцена с пользовательским `LightSwitch.gd` экспортируется в двух
вариантах (inline и package), затем чистый клиент строит эквивалентное дерево и поведение.

### Этап 9. Регрессии, диагностика и выпуск trusted MVP

- Unit: parser/IR/manifest/path/integrity/cache/trust/base/lifecycle.
- Integration: локальная, HTTP и redirect страницы; inline/src/package; compile/mount failure;
  refresh во время fetch; два модуля и две версии.
- E2E: exporter → HTTP fixture → чистая exported build → multiplayer late join.
- Fuzz/limits: HTML raw script, manifest JSON и ZIP central directory.
- Диагностика: origin/module/hash во всех логах, список активных модулей в debug UI, метрики
  download/compile/mount, понятная страница ошибки без показа секретов/локальных путей.

**Trusted modules MVP завершён**, когда внешний каталог содержит только `index.html` и
`lights.vrmod`; чистый Knossos после подтверждения origin создаёт отсутствующий в клиенте
`LightSwitch`, синхронизирует его через public API и полностью удаляет при навигации. Wrong
integrity не запускается, другой origin снова спрашивает разрешение, exporter воспроизводит
этот fixture из editor-сцены.

### Этап 10. Настоящий sandbox runtime

Это отдельный последующий milestone:

1. Сравнить WASM без WASI, отдельный Godot/GDScript worker process и embeddable VM на
   macOS/Windows/Linux по размеру,
   startup, interruption, memory limit, debug/source maps и поддержке export-сборок.
2. Зафиксировать capability ABI 1 и сериализуемые value types/handles.
3. Реализовать handle ownership, quotas, instruction/time budget, deterministic termination и
   отзыв capabilities после unmount.
4. Перенести `KnossosPageAPI` adapters поверх ABI; raw Godot Object никогда не проходит в VM.
5. Добавить permission prompts для fetch/storage/microphone и deny-by-default.
6. Сделать sandboxed версию того же переключателя и hostile fixtures: infinite loop, memory
   growth, чужой handle, path/network escape, callback после unmount.

**Все намеченные планы завершены**, когда sandboxed module с неизвестного origin может быть
запущен без выдачи прав процесса, hostile fixtures ограничиваются host'ом, а trusted GDScript
остаётся отдельным явно обозначенным режимом для авторов, которым нужна полная мощность Godot.

## Порядок зависимостей

```text
contract → export spike → IR → fetch/cache → trust → trusted runtime → PageAPI
                                                    ↓
navigation/multiplayer → exporter → trusted MVP → sandbox spike/runtime
```

Критический путь до полезного результата заканчивается на trusted MVP. Sandbox — самый большой
и рискованный этап; его нельзя подменять фильтрацией текста GDScript или manifest permissions.

## Связанные материалы

- [vrweb-tags.md](vrweb-tags.md) — декларативная сцена и уровень без пользовательского кода;
- [security.md](../security.md) — общая модель доверия;
- [replicated-state.md](../network/replicated-state.md) — сетевой state API.

Godot рассматривает GDScript как Script Resource, который можно загрузить и создать через
`new()`/`set_script`; resource packs также загружаются в runtime, но могут перекрывать пути.
Это подтверждает направление trusted-модулей, однако конкретный pipeline исходника из кэша в
export-сборке Knossos необходимо подтвердить первым spike.
