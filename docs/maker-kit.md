# VRWeb Maker Kit

Maker Kit — переносимый Godot 4.6 addon для создания VRWML-сцен в Godot и сборки standalone
`.vrwml` либо HTML с embedded `<vrwml>`. Локальный `.tscn` является source of truth только для
этого Godot-workflow. Addon не содержит клиент Knossos и не требует его autoload-ы; Knossos
подключает дополнительные preview/import возможности отдельным adapter-ом.

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
5. Выбрать Scene → Export As… → **VRWML Scene…**, формат `.html` и профиль `strict`.

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

## Выбор формы поставки

- standalone `.vrwml` — любая самостоятельная декларативная сцена: мир, аватар, предмет или
  композиция объектов;
- HTML `combine` — процедурное HTML-окружение плюс VRWML;
- HTML `exclusive` — HTML служит оболочкой, визуализируется только VRWML;
- `inline` — небольшой самодостаточный GDScript-компонент;
- `.vrmod` — модуль с кодом, сценами, assets и manifest.

Все формы создают VRWML-сцену; разделения формата на «миры» и «аватары» нет. Точный словарь —
в [каталоге тегов](space/vrwml-tags.md).

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

## Локальные профили Maker Kit

- `strict` — default Editor/CLI профиль безопасности и проверенной поддержки Knossos.
  Неподдерживаемые части пропускаются с diagnostics; структурно непригодный результат или
  несериализуемая потеря может блокировать запись.
- `compatible` — прежнее широкое ClassDB-поведение. Оно нужно для миграции существующих сцен,
  но не доказывает переносимость и может быть менее безопасным.

Это не два словаря VRWML: стандарт всегда включает все классы Godot и специальные теги из
[общего каталога](space/vrwml-tags.md). Профили — локальные решения конкретного клиента.
Текущая policy Maker Kit имеет версию `0.2-mvp1` (`policy_version` в build report,
`vrwml_policy` в `compatibility.json`) и задаётся кодом:
`addons/vrweb_tools/vrweb_compatibility.gd`.

| Категория | Проверенная/разрешённая база strict policy Knossos |
|---|---|
| Nodes | `Node`, `Node3D`, mesh/static body/collision/area/marker, directional/omni/spot light, sprite и positional audio |
| Special | `VRWebSpawner`/`SpawnerPoint`, `Resource`, `ExtResource`, `ExtScene` |
| Meshes | box/sphere/capsule/cylinder/plane/quad/array mesh |
| Materials | `StandardMaterial3D` |
| Collision resources | box/sphere/capsule/cylinder/convex/concave shapes |
| External types | texture/image, MP3/Ogg/WAV, mesh/array mesh и packed scene |

Public classes, которые host явно предоставляет через `VrwebExportRegistry`, также допустимы.
Knossos использует это для своих реализаций стандартных avatar-тегов; сторонний
Maker Kit не зависит от registry provider.

## Completion для ручного HTML

Release archive содержит `schemas/vrweb-html-data.json` в формате HTML Custom Data 1.1
и `.vscode/settings.json`, который подключает его через `html.customData`. При открытии
корня Maker Kit в VS Code редактор предлагает теги, разрешённые локальной strict policy, Godot
properties, enum/bool
values и показывает hover descriptions.

Schema не ведётся вручную: `vrweb_schema_generator.gd` берёт теги из
`VrwebCompatibility`/`VrwebFormat`, а property-level attributes — из Godot `ClassDB`. После
изменения этой policy её нужно перегенерировать:

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

## Preview, импорт и границы

В addon входят общий HTML parser/DOM, portable declarative materializer, lossless HTML importer,
exporter, URL/local resource metadata, content-addressed asset bundler, spawner, `.vrmod` package
builder, editor UI, strict diagnostics и headless build. Зависимости направлены как
**format/SDK → addon → Knossos**.

При открытии `.html/.htm` portable importer находит `<vrwml>`, материализует максимум доступного
как editable subtree и сохраняет точные HTML prefix/suffix в metadata. Неизвестные или
запрещённые policy части пропускаются с diagnostics. Save заменяет только `<vrwml>` и не
затирает параллельно изменённый на диске исходный блок.

Knossos adapter добавляет procedural preview остального HTML к уже импортированной portable
scene. Avatar import и runtime загрузка external resources также остаются в
`integrations/knossos/vrweb_tools`; переносимый addon их не импортирует.

## Trusted scripting modules

У scripted node автор явно выбирает `inline`, `package` или отсутствие экспорта. Панель VRWeb
показывает trust boundary и редактирует переносимые module metadata: `id`, SemVer `version`,
декларативные `permissions`, обязательные `requires` и `optional` capabilities. Значения
сохраняются в metadata узла; для `package` addon записывает их в `vrweb-module.json` и export
report. Defaults соответствуют VRWeb Scripting API v1.

`permissions` нужны для review, но не ограничивают обычный GDScript: `trusted-gdscript`
получает права процесса. Inline предназначен для одного самодостаточного файла; зависимости,
сцены и assets требуют `.vrmod`. Модули являются частью VRWML, хотя текущий GDScript-механизм
имеет provisional-статус. Полный контракт, trust model, lifecycle и multiplayer — только в
[scripting-modules.md](space/scripting-modules.md).

Версионный archive, starter, policy metadata, changelog и clean-project smoke-test собираются
общим `build.sh`. Технические детали и тестовая матрица находятся в
[документе реализации exporter-а](vrweb-export.md), незавершённые работы — в
[roadmap](roadmap.md#p1--vrweb-maker-kit-будущая-release-проверка).
Корневой changelog при этом является необязательным release input: если файла нет, builder
оставляет предупреждение и кладёт в archive служебную заметку вместо падения сборки.
