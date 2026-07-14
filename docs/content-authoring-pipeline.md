# Создание VRWeb-контента: текущий pipeline и границы

> **Актуальное состояние:** VRWeb Maker Kit устанавливается как самостоятельный Godot 4.6
> addon/starter и проходит полный путь от `.tscn` до HTML, локальных assets и trusted GDScript.
> Репозиторий Knossos внешнему автору не нужен; Knossos используется как reference runtime для
> Build & Run и финальной проверки страницы.

Этот документ собирает в одном месте именно пользовательский путь автора. Форматы и детали
реализации остаются в [vrweb-export.md](vrweb-export.md),
[vrweb-tags.md](space/vrweb-tags.md) и
[scripting-modules.md](space/scripting-modules.md). Незавершённые работы ведутся только в
[roadmap.md](roadmap.md).

## Какие средства создания контента уже есть

| Средство | Для чего подходит | Что получается | Главная граница |
|---|---|---|---|
| Обычный HTML/CSS | Процедурный мир из текста, секций, ссылок и media | Обычная web-страница | Автор не управляет точной 3D-геометрией |
| Ручной `<vrweb>` | Небольшая декларативная сцена или точечная вставка в страницу | HTML с Godot-shaped тегами | VS Code completion покрывает strict vocabulary/properties, но не заменяет semantic strict validation |
| Godot-плагин `addons/vrweb_tools` | Сцена, resources, spawn points и экспорт | HTML либо standalone `.vrwml` | Export/plugin core уже переносим; rich HTML preview, avatar import и runtime external preview подключаются только Knossos adapter-ом |
| Inline GDScript | Маленький самодостаточный компонент | `<script type="application/vrweb+gdscript">` + `<VRWebComponent>` | Trusted-код; один файл, без зависимостей |
| Package GDScript | Компонент с кодом, сценами и ассетами | HTML + sibling `.vrmod` | Trusted-код; dependency graph ограничен статически обнаруживаемыми portable dependencies |
| Импорт HTML в Godot | Portable правка существующего `<vrweb>` с lossless envelope; Knossos дополнительно показывает процедурное окружение | Изменённый исходный HTML | Окружение read-only; scripted/небезопасный слой становится целиком read-only |
| Импорт/preview VRWML | Authoring аватаров и проверка avatar-policy | Локальная editable `.tscn`-копия или несохраняемый viewport preview | Внешним входом всегда остаётся `.vrwml`; `.tscn` создаётся только локально для редактирования. `ExtResource` требует отдельной editable copy |
| Space Console (`~`) | Live-правка сцены в запущенном пространстве | Эфемерная дельта, опционально flush в страницу | Не заменяет source authoring; batch не атомарен, часть live patches не пересобирает специальные узлы |
| Встроенные инструменты игрока | Рисунок, картинка, leave-bubble | `stroke`, `vrweb-node`, `bubble` в эфемерном слое | Набор инструментов фиксирован кодом клиента, внешнего tool SDK нет |

Geometry/topology debug scenes помогают разрабатывать сам генератор Knossos, но не являются
инструментами стороннего автора мира.

## Фактический pipeline стороннего разработчика

### 1. Подготовить authoring-проект

`addons/vrweb_tools` уже загружает общий HTML parser, импортирует и экспортирует сцену в чистом Godot 4.6 project без
autoload-ов и исходников Knossos. В самом репозитории через project settings дополнительно
подключаются public avatar registry и `integrations/knossos/vrweb_tools`: они возвращают rich
procedural HTML preview, avatar import и runtime external preview, но не входят в переносимую границу.

Для внешнего пользователя уже есть starter `templates/vrweb_maker_starter`, install/build guide
и clean-project harness. Существующий release builder выпускает versioned Maker Kit
archive рядом с Knossos и с той же версией. Архив можно открыть как готовый starter project
или скопировать из него `addons/vrweb_tools`. Актуальная инструкция находится в
[maker-kit.md](maker-kit.md).

Maker Kit находится в `addons/vrweb_tools`: exporter, metadata resources, HTML scanner/saver,
package builder и editor UI образуют переносимую границу без compile-time зависимостей Knossos.
Addon формирует manifest/integrity/dependency graph, а
Knossos только валидирует trust и исполняет получившийся `.vrmod`. Module id/version,
permissions и capabilities не зависят от runtime-классов Knossos.

### 2. Собрать source scene

Canonical source — `.tscn`:

Здесь `.tscn` означает локальный Godot authoring-файл. Для аватара наружу публикуется и
загружается только `.vrwml`; внешний `.tscn` AvatarResolver всегда отклоняет.

1. создать корень `Node3D`;
2. добавить обычные Godot 4 nodes и resources;
3. добавить коллизии вручную — визуальный mesh сам по себе не становится поверхностью;
4. при необходимости поставить `VrwebSpawner` с дочерними `Marker3D`;
5. внешние texture/audio/mesh/scene URL привязать через dock как `VrwebExtResource`;
6. для scripted node явно выбрать `off`, `inline` или `package`.

Для HTML-export сам holder-корень не входит в `<vrweb>`, экспортируются его прямые дети. Для
standalone VRWML корень семантичен и экспортируется. Это различие легко получить случайно при
переключении формата.

### 3. Выбрать форму поставки

- **HTML `combine`** — процедурное HTML-окружение плюс авторская сцена;
- **HTML `exclusive`** — только авторская сцена;
- **standalone `.vrwml`** — data-only формат поставки аватаров; отдельный мир сейчас не
  предполагается, мир поставляется внутри HTML;
- **inline** — только небольшой самодостаточный GDScript;
- **package** — `.vrmod` рядом с HTML для кода и зависимостей.

Package exporter сам создаёт manifest, ZIP и integrity. `VrwebLocalAsset` собирает project-local
image/audio/GLB/glTF и их локальные зависимости в content-addressed `dist/assets`; обычные
HTTP(S)-bindings остаются внешними URL.

### 4. Экспортировать

В Godot: **Scene → Export As… → VRWeb Scene…**, затем выбрать `.html` или `.vrwml`.
Для package-компонентов рядом появляются `.vrmod`. `.tscn` остаётся source of truth.

Exporter формирует structured report, а editor после каждой попытки показывает итоговый review
с profile/catalog, errors, warnings, node paths и packages. `strict` является release-default и
не записывает файл при известной потере; `compatible` сохраняет прежнее широкое поведение.
Тот же контракт использует headless CLI с JSON report — см. [maker-kit.md](maker-kit.md).

### 5. Проверить как реальную страницу

Editor preview полезен, но не полностью эквивалентен клиенту:

- HTML preview строит production geometry, но заменяет интерактивные runtime actors статическими;
- preview внешних свойств пишет загруженный ресурс в реальное свойство, поэтому перед Save его
  нужно вручную очистить;
- preview standalone VRWML в dock относится к `Avatar`; world preview работает через импорт
  `.html/.htm` с embedded `<vrweb>`;
- scripting module trust, навигация, multiplayer, persistence и client content policy проверяются
  только обычным runtime-путём.

Значит, release candidate нужно открыть URL-ом в Knossos. Кнопка **Build & Run in Knossos**
строго пересобирает текущую сцену в `dist/`, показывает report и передаёт
`vrweblocal:///absolute/path/page.html` настроенному executable. Повторное нажатие заменяет
сборку и запускает новый process. Автоматического dev server и reload уже открытого процесса нет.

### 6. Опубликовать

HTML, `.vrmod` и внешние ресурсы размещаются на обычном HTTP(S)-хостинге. Специальная загрузка
на сервер Knossos не нужна. Относительные URL разрешаются от URL страницы. Cross-origin module
требует корректный `integrity`; сам trusted GDScript всё равно потребует решения доверия клиента.

Публикация выполняется внешним deploy-инструментом на обычный статический хостинг. В Maker Kit
есть hosting/cache checklist и headless verifier HTML, manifest, assets, status/size/hash; MIME
несоответствие остаётся предупреждением. Multiplayer
появляется по URL страницы; persistence требует отдельного origin endpoint/контракта и не
возникает автоматически.

## Где наиболее вероятны проблемы

### Совместимость и воспроизводимость

- В `compatible` vocabulary по-прежнему равен широкому Godot `ClassDB`. Для `strict` есть
  versioned MVP catalog nodes/resources/external types и генерируемая property-level HTML Custom Data schema.
- Документ не объявляет обязательную версию/capabilities; неизвестный класс и различия версий
  проявляются только при materialization.
- Exporter сравнивает свойства с defaults текущей версии Godot. Смена engine/client defaults
  способна изменить вид или generated output без правки `.tscn`.
- Мир по текущему контракту не существует отдельно от HTML-страницы. Его authoring и preview
  работают через HTML wrapper: editable `<vrweb>` плюс procedural read-only окружение.

### Потеря поведения и ассетов

- Script без явного opt-in блокирует `strict` export; в `compatible` остаётся warning и экспорт
  базовой геометрии без поведения.
- Inline отклоняет зависимости, `@tool`, autoload, C#/native code и `</script>`; package имеет
  собственные ограничения на `class_name`, `res://`, динамические зависимости и import options.
- Project-local image/audio/glTF собираются через `VrwebLocalAsset` в content-addressed
  `dist/assets` с manifest. Обычные URL bindings остаются внешними и публикуются отдельно.
- Активный external-resource preview может случайно запечь downloaded resource в `.tscn`.
- Round-trip гарантирован только для поддерживаемого семантического подмножества, не для
  произвольного Godot API и не для исходного форматирования `<vrweb>`.

### Runtime-отличия

- Editor viewport не проверяет trust/preflight, сетевую identity модулей, late join,
  authority change и persistence.
- Коллизии, spawn/teleport semantics, бюджеты, освещение, аудио и производительность требуют
  проверки в packaged client, желательно на всех целевых платформах.
- Особые VRWeb actors не исполняются в HTML editor preview, поэтому интерактивность там лишь
  приближённая.

### Безопасность

- Декларативный page/live-peer content policy работает allow-all даже в `ENFORCE`: произвольные
  Godot classes/properties остаются принятым риском.
- Trusted GDScript имеет права процесса; preflight и integrity подтверждают выбор конкретных
  байтов, но не изолируют код.
- Пир может добавить `vrweb-node` тем же materialization-путём; публикация безопасной исходной
  страницы сама по себе не делает multiplayer-сессию безопасной.

### Developer experience

- Переносимый addon включает starter, headless build, local asset bundle, release archive и
  code-driven completion. Semantic validation выполняют strict importer/exporter, не HTML editor.
- Цикл Build & Run пересобирает страницу и запускает новый процесс Knossos; уже открытый процесс
  автоматически не перезагружается.
- Полная проверка clean exported client и multiplayer относится к release/E2E тестам.
- Space Console удобна для эксперимента, но дельта и flush не образуют удобный source-control
  workflow обратно в `.tscn`.

## Что уже проверяется автоматически

В репозитории есть отдельные тесты exporter round-trip, avatar VRWML, HTML import/save,
inline/package export и module runtime. `tests/run_maker_clean_addon.sh` копирует addon
в чистый Godot project с новым `HOME` и прогоняет editor plugin, CLI, HTML edit,
asset bundle и scripting examples. `tests/run_maker_portability.py` добавляет byte-identical
rebuild, exact-case/missing path и schema freshness; workflow `maker-kit.yml` готов запускать
его на macOS, Windows и Linux.

Приоритеты устранения перечисленных разрывов находятся в разделах
[P0 Content Policy](roadmap.md#p0--content-policy-safe-profile),
[P1 Exporter](roadmap.md#p1--exporter-и-внешние-ресурсы),
[P1 Maker Kit release verification](roadmap.md#p1--vrweb-maker-kit-будущая-release-проверка) и
[P2 Release confidence](roadmap.md#p2--release-confidence).
