# VRWeb Maker Kit

Maker Kit — переносимый Godot 4.6 addon для создания data-first мира в `.tscn` и сборки HTML
с embedded `<vrweb>`. Он не содержит клиент Knossos и не требует его autoload-ы. Knossos
подключает собственные preview/import возможности отдельным adapter-ом.

Maker Kit и Knossos имеют общий release train и один semver из `project.godot`. Каждый запуск
release builder создаёт отдельный устанавливаемый Maker Kit archive рядом с платформенными
архивами Knossos, используя тот же build number. Независимость kit означает отсутствие
runtime/compile-time зависимости от Knossos у автора, а не отдельный репозиторий или график
релизов.

## Установка и первый build

1. Создать Godot 4.6 project или скопировать `templates/vrweb_maker_starter`.
2. Скопировать каталог `addons/vrweb_tools` в проект, сохранив тот же путь.
3. Включить **VRWeb Tools** в Project → Project Settings → Plugins.
4. Открыть `world.tscn`, заменить два `example.invalid` URL или удалить placeholder-узлы.
5. Выбрать Scene → Export As… → **VRWeb Scene…**, формат `.html` и профиль `strict`.

Starter содержит пол, collision, куб, два источника света, spawn point и placeholders для
внешней картинки и GLB/PackedScene. Корень `World` — authoring holder: в HTML попадают его дети.

Для CI и локальной воспроизводимой сборки:

```bash
godot --headless --path /path/to/project \
  --script res://addons/vrweb_tools/vrweb_cli.gd -- \
  --scene=res://world.tscn \
  --output=res://dist/world.html \
  --profile=strict \
  --mode=exclusive \
  --report=res://dist/report.json
```

Код возврата `0` означает, что output записан; ошибка валидации или записи возвращает ненулевой
код. JSON report содержит `ok`, профиль и версию каталога, warnings/errors, packages, source,
output и SHA-256 записанного файла. HTML/VRWML payload в JSON не дублируется.

## Build & Run in Knossos

Dock **VRWeb → Build & Run · production runtime** выполняет короткий production-like цикл:

1. strict-сборка текущей сцены в `res://dist/<scene>.html`;
2. запись sibling `<scene>.report.json` с SHA-256;
3. показ export review;
4. запуск Knossos только после подтверждения **Run in Knossos**.

Повторное нажатие пересобирает тот же путь без file dialog и запускает новый runtime process —
это текущий reload workflow. Addon не содержит `WorldGenerator`/`TopologyBuilder`: страницу
открывает настоящий Knossos через `vrweblocal:///absolute/path`.

Настройки проекта доступны в Project Settings:

- `vrweb/maker/dist_dir` — каталог сборки, default `res://dist`;
- `vrweb/maker/html_mode` — `exclusive` или `combine`.

Путь к Knossos и launch mode сохраняются в локальных Editor Settings, а не в `project.godot`:

- `executable` — рекомендуемый mode. Можно указать Linux/macOS/Windows executable или путь к
  `.app`; URL передаётся отдельным argv и корректно сохраняет пробелы в пути;
- `deeplink` — вызывает зарегистрированный системный handler. На macOS он способен поднять
  приложение, но Godot 4.6 не передаёт Apple `openURLs` event в GDScript, поэтому целевой URL
  теряется. На macOS следует использовать `executable`.

Если executable или `.app` отсутствует, HTML остаётся собранным, но запуск завершается понятной
ошибкой в dock. Это позволяет исправить настройку и нажать Build & Run ещё раз.

## Профили

- `strict` — default Editor/CLI release build. Неподдерживаемый node/resource/external type,
  потерянный Script или несериализуемое сохранённое свойство блокирует запись.
- `compatible` — прежнее широкое ClassDB-поведение. Оно нужно для миграции существующих сцен,
  но не доказывает переносимость в другой VRWeb client/version.

Текущий compatibility catalog имеет версию `0.2-mvp1` и является кодовым source of truth:
`addons/vrweb_tools/vrweb_compatibility.gd`.

| Категория | Strict MVP |
|---|---|
| Nodes | `Node`, `Node3D`, mesh/static body/collision/area/marker, directional/omni/spot light, sprite и positional audio |
| Special | `VRWebSpawner`/`SpawnerPoint`, `Resource`, `ExtResource`, `ExtScene` |
| Meshes | box/sphere/capsule/cylinder/plane/quad/array mesh |
| Materials | `StandardMaterial3D` |
| Collision resources | box/sphere/capsule/cylinder/convex/concave shapes |
| External types | texture/image, MP3/Ogg/WAV, mesh/array mesh и packed scene |

Public classes, которые host явно предоставляет через `VrwebExportRegistry`, также допустимы.
Knossos использует это для avatar vocabulary; сторонний Maker Kit не зависит от registry provider.

## Completion для ручного HTML

Release archive содержит `schemas/vrweb-html-data.json` в формате HTML Custom Data 1.1
и `.vscode/settings.json`, который подключает его через `html.customData`. При открытии
корня Maker Kit в VS Code редактор предлагает strict VRWeb tags, Godot properties, enum/bool
values и показывает hover descriptions.

Schema не ведётся вручную: `vrweb_schema_generator.gd` берёт теги из
`VrwebCompatibility`/`VrwebFormat`, а property-level attributes — из Godot `ClassDB`. После
изменения vocabulary её нужно перегенерировать:

```bash
godot --headless --path . \
  --script res://addons/vrweb_tools/vrweb_schema_cli.gd -- \
  --output=res://schemas/vrweb-html-data.json
```

Release builder запускает ту же команду с `--check` и останавливает сборку, если committed
schema отстала. Completion помогает писать markup, но strict exporter/importer остаётся
авторитетным validator-ом.

Та же schema и asset bundler проверяются portable harness-ом:

```bash
python3 tests/run_maker_portability.py
```

В GitHub Actions он запускается на macOS, Windows и Linux с официальным Godot 4.6.3.

Strict world требует `VRWebSpawner`, сообщает об отсутствии collision, ограничивает 2048 nodes,
1024 subresources и 256 external resources, предупреждает о mesh тяжелее 100 000 triangles и
проверяет URL scheme. Это первичная переносимость, не performance guarantee конкретного клиента.

## Локальные assets и переносимый `dist/`

Для project-local картинки, аудио или glTF выберите node, заполните property/type как для
обычного URL и нажмите **Привязать local asset…**. Пустой property создаёт local `ExtScene`.
В `.tscn` сохраняется authoring-only `VrwebLocalAsset(source_path="res://...")`; публичный HTML
получает обычный относительный `<ExtResource path="assets/...">` и не знает этот Godot-класс.

При Editor/CLI build:

- source PNG/JPEG/WebP/SVG, MP3/Ogg/WAV, GLB или glTF читается напрямую из проекта, без
  копирования `.godot/imported`;
- файл получает content-addressed имя `assets/<world>/<name>.<sha-prefix>.<ext>`;
- для `.gltf` относительные `buffers[].uri` и `images[].uri` копируются и переписываются;
- data URI остаётся inline, а remote dependency внутри local glTF отклоняется;
- missing path, несовпадение регистра, выход за `res://` и неизвестный format блокируют build;
- `<world>.assets.json` записывает source path, MIME, размер и полный SHA-256 каждого файла.

Существующий `VrwebExtResource` с HTTP(S)-URL продолжает работать без bundling. Поэтому весь
`dist/` self-contained только в той мере, в какой автор заменил внешние URL local declarations.
Каждый output имеет отдельный namespace/manifest; успешный rebuild удаляет только устаревшие
файлы, перечисленные предыдущим manifest этого мира. Соседние страницы и произвольные файлы в
`dist/` не затрагиваются.

## Проверка опубликованного сайта

После загрузки `dist/` на HTTP(S)-хостинг запустите:

```bash
godot --headless --path /path/to/project \
  --script res://addons/vrweb_tools/vrweb_verify_published.gd -- \
  --base-url=https://example.com/world \
  --page=world.html \
  --manifest=world.assets.json \
  --report=res://dist/published-report.json
```

Verifier загружает страницу, manifest и каждый перечисленный asset с учётом HTTP redirects.
Network error, non-2xx status, unsafe relative path, неверный размер или SHA-256 являются errors
и возвращают exit code `1`. Несовпадение либо отсутствие `Content-Type` записывается только как
warning и не блокирует публикацию.

Hosting checklist:

- HTML, `<world>.assets.json` и весь `assets/<world>/` публикуются с сохранением регистра;
- относительная структура не переписывается CDN/deploy script;
- redirects заканчиваются доступным `2xx`, а не login/error HTML;
- cache для content-addressed assets может быть долгим/immutable, для HTML и manifest — коротким;
- CORS нужен для cross-origin assets/modules; same-origin bundle его не требует;
- перед релизом published verifier должен завершиться без errors, MIME warnings оцениваются
  отдельно по фактической способности целевого клиента декодировать байты.

## Состав и границы

В addon входят общий HTML parser/DOM, portable declarative materializer, lossless HTML importer,
exporter, URL/local resource metadata, content-addressed asset bundler, spawner, `.vrmod` package
builder, editor UI, strict diagnostics и headless build. Зависимости направлены как
**format/SDK → addon → Knossos**.

При открытии `.html/.htm` portable importer находит первый настоящий `<vrweb>`, материализует
strict vocabulary как editable subtree и сохраняет точные HTML prefix/suffix в read-only metadata.
Save заменяет только `<vrweb>` и отклоняет запись, если исходный block параллельно изменился на
диске. Scripted/runtime-only tags дают diagnostics и read-only scene вместо частичного импорта.

Knossos adapter добавляет procedural preview остального HTML к уже импортированной portable
scene. Avatar import и runtime загрузка external resources также остаются в
`integrations/knossos/vrweb_tools`; переносимый addon их не импортирует.

## Trusted scripting modules

У scripted node автор явно выбирает `inline`, `package` или отсутствие экспорта. Панель VRWeb
показывает trust boundary и редактирует переносимые module metadata: `id`, SemVer `version`,
декларативные `permissions`, обязательные `requires` и `optional` capabilities. Значения
сохраняются в metadata узла; для `package` addon записывает их в `vrweb-module.json` и export
report. Defaults соответствуют VRWeb Scripting API v1.

`permissions` нужны пользователю Knossos для review, но не ограничивают обычный GDScript:
`trusted-gdscript` получает права процесса. Inline предназначен для одного самодостаточного
файла; зависимости, сцены и assets требуют `.vrmod`. Package builder, dependency walker,
manifest, ZIP и integrity находятся полностью в addon. Knossos остаётся следующим слоем:
валидирует и исполняет уже собранный package.

Копируемый `modules/interaction_example.gd` в starter показывает полный минимальный lifecycle:
`mount(context)`/`unmount()`, activate, replicated state, declared assets, lifecycle-safe timer
и log. Он использует только публичный context и одновременно собирается clean-project harness-ом.

Starter содержит две сцены с одинаковым `InteractivePanel`:
`scripting_inline_demo.tscn` встраивает script в HTML, а `scripting_package_demo.tscn` создаёт
sibling `.vrmod`. Inline удобен для одного файла; package следует выбирать при появлении
dependencies/assets или необходимости version/permissions/capabilities в manifest. Clean
harness собирает обе сцены strict-профилем и проверяет marker/package output.

Negative suite `tests/test_maker_scripting_negatives.tscn` фиксирует diagnostics для отсутствующей
package dependency, ошибки компиляции downloaded GDScript, неверного cross-origin integrity и
неизвестной обязательной capability. Это runtime regressions, а не дополнительные режимы UI.

Служебные source roots `templates/`, `schemas/`, clean-project fixture и raw negative/golden
fixtures помечены `.gdignore`: основной Knossos project не импортирует вложенный starter,
generated schema и тестовые данные. Release builder и harness копируют или читают нужные файлы
явно, поэтому эти границы не попадают в самостоятельный Maker Kit и не мешают его импорту.

Экспортированный Knossos имеет узкий `--vrweb-maker-self-test`: он читает заранее собранный
`lights.vrmod` из PCK и проверяет integrity, sandboxed unpack/cache, capabilities, runtime
compilation, mount/input и вложенные assets. Это подтверждает направление поставки
`addon build → Knossos consume`; клиент не является вторым package builder-ом.

Версионный archive, starter, compatibility metadata, changelog и clean-project smoke-test собираются
общим `build.sh`. Runtime test выполняется кнопкой Build & Run либо в Knossos через опубликованный
URL; доступность deploy проверяет отдельный published-base verifier. Оставшиеся release-проверки
ведутся в [общем roadmap](roadmap.md#p1--vrweb-maker-kit-будущая-release-проверка).
