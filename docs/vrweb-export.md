# VRWML — инструментарий редактора (сборка и экспорт сцен)

> **Суть:** authoring для [VRWML](space/vrwml-format-and-pipeline.md). Сцену собирают в
> редакторе Godot обычными узлами, жмут **Экспорт** — и плагин генерирует HTML-документ
> с блоком `<vrwml>` либо standalone `.vrwml`. Плюс авторинг внешних ресурсов по URL,
> импорт avatar VRWML в редактируемую `.tscn` и дебаг-превью ресурсов.

Плагин: `addons/vrweb_tools/` (включается в Project → Plugins, уже включён в `project.godot`).
Док-панель «VRWeb» появляется справа-снизу. Установка в чистый проект, starter и headless CLI
описаны в [maker-kit.md](maker-kit.md).

---

## Что делает плагин

| Действие | Результат |
|---|---|
| Scene → Export As… → **VRWML Scene…** → `VRWML scene` | сериализует открытую сцену в standalone `.vrwml`, включая корень сцены |
| Scene → Export As… → **VRWML Scene…** → `HTML with VRWML wrapper` | сериализует открытую сцену в `.html` с блоком `<vrwml>`; dialog option выбирает `combine`/`exclusive` |
| **Preview Avatar VRWML…** | временно добавляет проверенный Avatar только в 3D viewport без `owner`; SceneTree dock не меняется и `.tscn` не загрязняется |
| **Очистить Avatar preview** | удаляет временный Avatar и его незавершённые resource loaders |
| **Avatar VRWML → редактируемая TSCN…** | fallback для документа с `ExtResource`: дожидается ресурсов и сохраняет materialized editable `.tscn` |
| **Привязать к узлу** | вешает внешний ресурс (URL+тип) на выбранный узел — в его метадату |
| **Убрать привязку** | снимает привязку свойства/`<ExtScene>` |
| **Загрузить превью** | качает все `<ExtResource>` сцены и временно подставляет (без сохранения) |
| **Очистить превью** | снимает превью (обнуляет свойства, сносит вставленные сцены) |
| Открыть `.html`/`.htm` из FileSystem | открывает `<vrwml>` как editable scene, а HTML вокруг — как видимый read-only procedural preview |
| **Сохранить импортированный HTML** / Save | заменяет только исходный `<vrwml>…</vrwml>`, не нормализуя остальной HTML |

### Переносимое поведение

Godot `script` не сериализуется и не публикуется. Такой script является реализацией authoring-
проекта, а strict exporter сообщает о непереносимом поведении. Исполняемое поведение страницы
поставляется готовым WebAssembly component и связывается через `VRWebModule`/`VRWebComponent`.
Формат, lifecycle и sandbox boundary описаны в
[документе модулей](space/scripting-modules.md).

В Maker Kit для этого служит authoring-only `VrwebWasmComponent`: у него выбирают готовый
`.vrmod`, module id и export. При HTML build exporter проверяет package, публикует его по
content hash и создаёт обе декларации. В editor код не исполняется; production preview доступен
через **Build & Run in Knossos**. Standalone `.vrwml` не несёт delivery declaration и потому
отклоняет такой узел.

---

## Как собирать сцену

1. Корень сцены — любой `Node3D`. **Прямые дети корня** становятся корнями блока `<vrwml>`
   (как в читателе: всё, кроме `<Resource>`, — корни добавляемой сцены).
2. Узлы ставятся обычные движковые: `MeshInstance3D`, `OmniLight3D`, `StaticBody3D`,
   `CollisionShape3D`, `Sprite3D`, `AudioStreamPlayer3D` и т.д. Тег экспорта = класс узла
   (`node.get_class()`), атрибуты = свойства, **отличающиеся от дефолта** класса.
3. Ресурсы в свойствах (`MeshInstance3D.mesh = BoxMesh`, `CollisionShape3D.shape`, материалы)
   экспортируются как `<Resource>` с дедупом по инстансу и ссылкой `SubResource:::<id>`.
4. **Спавн:** узел `VrwebSpawner` (`@export mode: first|random`) + дети `Marker3D` —
   экспортятся как `<VRWebSpawner>`/`<SpawnerPoint>`. Сам спавнер в сцену клиента не идёт.

Для standalone VRWML корень не является служебным holder-ом и тоже сериализуется. Scripted
avatar-классы получают публичные теги через `VrwmlClassRegistry`; Script/source code в этот
режим не экспортируются. Стандартные avatar-классы и контекстные ограничения описаны в
[vrwml-format-and-pipeline.md](space/vrwml-format-and-pipeline.md).

`AvatarAnimationTreeApplier.animation_tree` экспортируется как относительный
`animation_tree_path: NodePath`. Массив `bindings` использует обычные ссылки
`SubResource:::id` на публичные ресурсы `AvatarParamBinding`, включая восстановление typed
array при импорте.

Avatar preview/import пропускают запрещённые или неизвестные части и сохраняют максимум
доступного дерева. `AvatarVrwmlPolicy` добавляет structured diagnostics; результат отклоняется
только если после materialization не осталось пригодного корня `Avatar`.

### Внешние ресурсы (URL) — `VrwebExtResource` в метадате

Типы вроде `Sprite3D.texture` не примут произвольный ресурс, поэтому ext-ресурс хранится
не в самом свойстве, а в **метадате узла** (`VrwebExtResource` — `addons/vrweb_tools/vrweb_ext_resource.gd`):

| meta-ключ | значение | экспорт |
|---|---|---|
| `vrweb_ext` | `{ "<свойство>": VrwebExtResource }` | `свойство="ExtResource:::<id>"` + `<ExtResource>` |
| `vrweb_ext_scene` | `VrwebExtResource(type=PackedScene)` | узел → `<ExtScene src="ExtResource:::<id>">` |

Проще всего через док: выбрать узел, вписать **свойство** (напр. `texture`) и **URL**,
выбрать тип → **Привязать к узлу**. Пустое поле свойства = привязка `<ExtScene>` (узел станет
плейсхолдером внешней GLTF/GLB-сцены).

Для локального source вместо URL используется **Привязать local asset…**. Такой binding хранит
`VrwebLocalAsset` в той же метадате, а build копирует web-source в `dist/assets` и подставляет
относительный URL. Форматы, manifest и ограничения описаны в [maker-kit.md](maker-kit.md).

---

## Дебаг-превью

«Загрузить превью» собирает заявки `{defs, targets}` из меты сцены (та же форма, что у
читателя) и качает их через общий `VrwebExtInjector` (один код с рантаймом, см. ниже).
Текстуры/звук/меш подставляются в реальные свойства, скачанная `<ExtScene>` добавляется
ребёнком **без owner** — поэтому в `.tscn` не сериализуется.

`ImageLoader` определяет realtime-ссылки через чистый `BlobProtocol`, не обращаясь для
обычного HTTP-превью к runtime-autoload `BlobStore`: autoload в editor context является
placeholder, пока его скрипт намеренно не работает как `@tool`. Само хранилище вызывается
только после распознавания валидного `vrwebblob://` URL и находится динамически в `/root`;
если editor context не предоставляет рабочий store, загрузчик завершает заявку с `null`.

> ⚠️ Превью **свойств** (texture/stream/mesh) пишется в реальное свойство — если сохранить
> сцену с активным превью, оно запечётся в `.tscn`. Жмите **Очистить превью** перед
> сохранением; автоматического save-hook сейчас нет.

---

## Как устроено в коде

| Файл | Роль |
|---|---|
| `addons/vrweb_tools/vrweb_exporter.gd` | `VrwebExporter.export_scene(root, mode)` — сериализатор (зеркало `VrwebBuilder`) |
| `addons/vrweb_tools/vrweb_format.gd` | Переносимые имена тегов, prefixes и modes; export path больше не компилирует `VrwebBuilder` ради констант |
| `addons/vrweb_tools/vrweb_export_registry.gd` | Опциональный bridge public VRWeb classes: чистый проект работает без provider, Knossos подключает avatar registry через project setting |
| `addons/vrweb_tools/vrweb_compatibility.gd` | Локальная versioned policy проверенной поддержки и budgets Maker Kit; не словарь стандарта VRWML |
| `addons/vrweb_tools/vrweb_cli.gd` | Headless strict build с JSON report и ненулевым exit code при ошибке |
| `addons/vrweb_tools/vrweb_launcher.gd` | Переносимый `vrweblocal://` launcher: executable либо системный deeplink без зависимости от Knossos-кода |
| `addons/vrweb_tools/vrweb_published_verifier.gd` | Правила manifest/HTTP response: status/size/hash errors, MIME warning |
| `addons/vrweb_tools/vrweb_verify_published.gd` | Headless проверка уже опубликованных HTML, manifest и assets с JSON report |
| `addons/vrweb_tools/html_node.gd`, `html_parser.gd` | Общий portable HTML DOM/tokenizer; Knossos runtime использует addon API |
| `addons/vrweb_tools/vrweb_markup_materializer.gd` | Strict declarative `<vrwml>` → editable Godot subtree без runtime actors |
| `addons/vrweb_tools/vrweb_portable_html_scene_codec.gd` | Lossless envelope metadata, portable HTML import и structured diagnostics |
| `addons/vrweb_tools/vrweb_portable_html_scene_importer.gd` | Единственный editor importer `.html/.htm`, регистрируемый portable plugin |
| `addons/vrweb_tools/vrweb_ext_resource.gd` | `VrwebExtResource` (url+type) + ключи меты |
| `addons/vrweb_tools/vrweb_local_asset.gd` | Authoring declaration `res://` asset; наружу экспортируется как обычный relative `ExtResource` |
| `addons/vrweb_tools/vrweb_asset_bundler.gd` | Изолированный content-addressed `dist/assets/<world>`, glTF dependency rewrite и per-world manifest |
| `addons/vrweb_tools/vrweb_spawner.gd` | `VrwebSpawner` — узел-маркер правил спавна |
| `integrations/knossos/vrweb_tools/vrweb_ext_preview.gd` | Knossos adapter: сбор меты + runtime-превью внешних ресурсов |
| `addons/vrweb_tools/vrweb_tools_plugin.gd` | `EditorPlugin` — док и обработчики кнопок |
| `integrations/knossos/vrweb_tools/vrwml_avatar_scene_importer.gd` | Knossos adapter: `.vrwml` появляется в Import/FileSystem dock как Avatar scene |
| `integrations/knossos/vrweb_tools/vrweb_html_scene_codec.gd` | Knossos adapter: добавляет procedural preview вокруг portable imported `<vrwml>` |
| `integrations/knossos/vrweb_tools/knossos_tools_integration.gd` | Опционально подключает runtime preview/import UI к переносимому plugin через project setting |
| `scripts/world_generator.gd` | Единая полная 3D-сборка runtime и синхронного editor preview; в editor заменяет только интерактивные scripted actors |
| `addons/vrweb_tools/vrweb_html_document.gd` | Lossless-поиск диапазона первого настоящего `<vrwml>` вне comment/raw-text |
| `addons/vrweb_tools/vrweb_html_scene_saver.gd` | Явная замена только блока и защита от внешнего конфликта |
| [scripts/vrwml_class_registry.gd](../scripts/vrwml_class_registry.gd) | Симметричное отображение public VRWML tag ↔ Godot implementation |
| [actors/avatar/avatar_vrwml_policy.gd](../actors/avatar/avatar_vrwml_policy.gd) | Контекстная allowlist/budgets для avatar VRWML |
| [scripts/vrweb_ext_injector.gd](../scripts/vrweb_ext_injector.gd) | `VrwebExtInjector.inject(ext, image_loader, host)` — общая докачка/вставка ext-ресурсов (рантайм + превью) |

Сериализация значений — `var_to_str` (даёт `Transform3D(...)`/`Vector3(...)`/числа/`"строки"`),
ровно то, что читатель разбирает через `str_to_var`. Значения HTML-экранируются
(`& < > "` → сущности), а `HtmlParser._decode_entities` декодирует обратно — round-trip строк
с кавычками сохраняется.

### Нативный импорт `.vrwml`

Плагин регистрирует `.vrwml` через `EditorSceneFormatImporter`. После filesystem scan файл
получает обычный Godot Import lifecycle и открывается из FileSystem dock как импортированная
сцена. Для редактирования используется стандартный workflow Godot — inherited/local scene.

Scene importer синхронный, поэтому создаёт сцену с незаполненными внешними свойствами и
diagnostics. Явная команда editable copy использует асинхронные loaders, дожидается ресурсов и
сохраняет более полную локальную `.tscn`.

Содержимое док-панели находится в `ScrollContainer`: при недостаточной высоте прокручивается
сама панель, а не раздувается весь нижний dock.

### Нативное открытие и частичное сохранение `.html`

HTML importer разделяет сцену на два слоя:

- дети `<vrwml>` материализуются обычными редактируемыми узлами;
- в `combine` DOM за пределами `<vrwml>` проходит полный production pipeline
  `TopologyBuilder → SpaceLayout → WorldGenerator`: комнаты, дверные проёмы, полы и стены
  коридоров, настенные объекты и атмосфера совпадают с runtime-сборкой;
- `Portal`, `RichPanel`, video и `ImagePanel` не исполняются как игровые scripted actors:
  ссылки/текст/video получают встроенные статические панели, а картинки — `QuadMesh`, в который
  после открытия сцены существующий `ImageLoader` прогрессивно подставляет реальную текстуру;
- в `exclusive` HTML DOM вообще не строится — во viewport остаётся только `<vrwml>`;
- этот preview пакуется в import cache со служебной меткой, а после открытия plugin переводит
  его в internal-поддерево: оно видно во viewport, скрыто в SceneTree и всегда исключается
  exporter-ом;
- runtime scripted actors (`RichPanel`, video, mirror, component и неизвестные public classes)
  не запускаются как `@tool`. Если они встречены внутри `<vrwml>`, весь декларативный слой
  остаётся read-only, чтобы частичный editor build не мог удалить их при сохранении.

Save и кнопка **«Сохранить импортированный HTML»** перечитывают исходный файл, экспортируют
только обычных детей корня в новый `<vrwml>` и заменяют исходный диапазон блока. Scanner
пропускает HTML comments и содержимое `script/style/textarea/title`, поэтому текст
`"<vrwml>"` внутри JS не принимается за сцену. Prefix и suffix сохраняются буквально, включая
пробелы и CRLF. Хэш исходного блока запоминается при импорте; если сам `<vrwml>` параллельно
изменили на диске, запись отклоняется до переимпорта.

Форматный saver для расширения `.html` намеренно не регистрируется: Godot вызывает такие
saver-ы и при создании import cache, что смешало бы импорт с пользовательской записью source.
Запись выполняет только editor plugin над live edited scene.

### Нативный экспорт `.vrwml`

Плагин добавляет `VRWML Scene…` в штатное меню Godot `Scene → Export As…` через
`EditorPlugin.get_export_as_menu()`. Команда экспортирует текущую открытую сцену тем же
`VrwebExporter`, что используется остальным pipeline, и показывает обычный resource file dialog.

Тип файла в Save As определяет envelope: `*.vrwml` сохраняет чистый VRWML, `*.html` — HTML с
вложенным `<vrwml>`. Штатная option `HTML scene mode` выбирает `combine` или `exclusive` и для
`.vrwml` игнорируется. Формат намеренно определяется расширением, а не отдельным dropdown:
так filename, file filter и стандартное предупреждение о перезаписи всегда относятся к одному
реальному output path.

Это именно **export**, а не `Save Scene As`: исходная `.tscn` остаётся редактируемым source of
truth, её путь не меняется, а `.vrwml` создаётся как производный переносимый документ. Поэтому
регистрировать `ResourceFormatSaver<PackedScene>` для `.vrwml` не нужно: такой saver смешал бы
authoring и distribution lifecycle и мог бы переключить открытую сцену на импортируемый файл.

Кнопки scene export из dock удалены как дубликаты; dock остаётся для preview/import, scripts и
external-resource tooling.

---

## Проверка

- Headless round-trip: `godot --headless --path . --script res://tests/test_export.gd`
  (собирает сцену → экспорт → `HtmlParser` → `VrwebBuilder` → сверка узлов/ресурсов/ext/спавна).
- Переносимый export core без runtime builder:
  `godot --headless --path . res://tests/test_maker_export_core.tscn`; тест сравнивает HTML с
  byte-for-byte golden fixture.
- Чистый внешний Godot-проект с полным addon и включённым `plugin.cfg`:
  `bash tests/run_maker_clean_addon.sh`. Harness копирует весь `addons/vrweb_tools` в новый
  временный проект без Knossos/autoload-ов, загружает EditorPlugin и выполняет реальный экспорт.
- Avatar VRWML round-trip и generated drift: `godot --headless --path . res://tests/test_avatar_vrwml.tscn`.
  Для регенерации `avatars/avatar_N.vrwml`: добавить `-- --write-vrwml`.
- Lossless HTML envelope: `godot --headless --path . --script res://tests/test_html_scene_document.gd`.
- HTML import/internal preview/save/conflict: `godot --headless --path . res://tests/test_html_scene_import.tscn`.
- В редакторе: собрать мини-сцену, выбрать `Scene → Export As… → VRWML Scene…`, затем выбрать
  `VRWML scene` или `HTML with VRWML wrapper` в file type selector. Для HTML дополнительно
  проверить оба значения `HTML scene mode`.

---

## Единый roadmap

Все незавершённые задачи exporter-а и внешних ресурсов ведутся в
[едином roadmap](roadmap.md#p1--exporter-и-внешние-ресурсы).

Оставшиеся release-проверки Maker Kit также ведутся в
[общем roadmap](roadmap.md#p1--vrweb-maker-kit-будущая-release-проверка). Format constants, public-class
registry и package integrity находятся в переносимом addon.
Rich HTML preview, avatar import и external preview вынесены в Knossos integration adapter,
который подключается только в референсном проекте через `vrweb/tools/integration_script`.
