# VRWeb — инструментарий редактора (сборка и экспорт сцен)

> **Суть:** обратное к [vrweb-tags.md](space/vrweb-tags.md) направление. Сцену собирают в
> редакторе Godot обычными узлами, жмут **Экспорт** — и плагин генерирует HTML-документ
> с блоком `<vrweb>` либо standalone `.vrwml`. Плюс авторинг внешних ресурсов по URL,
> импорт avatar VRWML в редактируемую `.tscn` и дебаг-превью ресурсов.

Плагин: `addons/vrweb_tools/` (включается в Project → Plugins, уже включён в `project.godot`).
Док-панель «VRWeb» появляется справа-снизу.

---

## Что делает плагин

| Действие | Результат |
|---|---|
| Scene → Export As… → **VRWeb Scene…** → `VRWML scene` | сериализует открытую сцену в standalone `.vrwml`, включая корень сцены |
| Scene → Export As… → **VRWeb Scene…** → `HTML with VRWeb wrapper` | сериализует открытую сцену в `.html` с блоком `<vrweb>`; dialog option выбирает `combine`/`exclusive` |
| **Preview Avatar VRWML…** | временно добавляет проверенный Avatar только в 3D viewport без `owner`; SceneTree dock не меняется и `.tscn` не загрязняется |
| **Очистить Avatar preview** | удаляет временный Avatar и его незавершённые resource loaders |
| **Avatar VRWML → редактируемая TSCN…** | fallback для документа с `ExtResource`: дожидается ресурсов и сохраняет materialized editable `.tscn` |
| **Привязать к узлу** | вешает внешний ресурс (URL+тип) на выбранный узел — в его метадату |
| **Убрать привязку** | снимает привязку свойства/`<ExtScene>` |
| **Загрузить превью** | качает все `<ExtResource>` сцены и временно подставляет (без сохранения) |
| **Очистить превью** | снимает превью (обнуляет свойства, сносит вставленные сцены) |

### Аудит пользовательских скриптов

По умолчанию плагин их не экспортирует: `script` не сериализуется как обычное свойство. Для
выбранного scripted node теперь есть явная кнопка **«Экспортировать inline»**: exporter пишет
source в `<script type="application/vrweb+gdscript">`, а узел — как `<VRWebComponent>`.
Без opt-in геометрия/сохранённые свойства остаются, поведение теряется и выводится warning.

Это нельзя исправлять автоматическим экспортом каждого найденного Script: сцена может содержать
служебный/editor-код, который автор не собирался публиковать. Нужен явный режим на scripted node:

| Режим | Экспорт |
|---|---|
| `off` (по умолчанию) | текущее поведение; плагин показывает предупреждение о потере Script |
| `inline` | **реализован:** source попадает в `<script type="application/vrweb+gdscript">`, узел — в `<VRWebComponent module="#id" class="default">` |
| `package` | **первый срез реализован:** GDScript и literal relative file-зависимости собираются в sibling `.vrmod`; HTML ссылается через `<VRWebModule integrity="sha256-…">` |

`inline` допустим только для самодостаточного GDScript без module-local файлов. Если exporter
видит scene/asset/script dependencies, он предлагает `package`. `@tool`, autoload, GDExtension,
C# и literal `</script` для inline отклоняются. Полный контракт и план реализации —
[scripting-modules.md](space/scripting-modules.md).

Inline round-trip (script, `@export`-свойство, базовое свойство и дети) проверяет
`tests/test_inline_export.tscn`. Первый package round-trip проверяет
`tests/test_package_export.tscn`: плагин находит literal relative `load()`/`preload()`, создаёт
manifest и ZIP, вычисляет integrity, а чистый runtime собирает экспортированный HTML. `.gd`
становятся кодовыми зависимостями; остальные файлы входят в `manifest.assets`. Логическое имя
строится из basename, а коллизия получает стабильный SHA-256 suffix пути.

Для текстовых `.tscn`/`.tres` граф обходится рекурсивно: `res://`-ссылки переписываются в
относительные module-local пути, зависимости включаются в пакет, а известный Resource type
записывается в manifest. Это проверено сценой, которая после распаковки загружает вложенный
`.tres` уже без исходного проекта.

Для распространённых импортируемых source-форматов (изображения, аудио, glTF/GLB) exporter
загружает импортированный Godot Resource и сохраняет его как bundled `.res` внутри пакета.
Ссылка `.tscn/.tres` переписывается на этот `.res`; поэтому runtime не зависит от исходного
`.godot/imported`. Сквозной тест покрывает цепочку `.tscn → SVG → bundled Texture2D`.

Структурированный export report реализован: `ok/errors/warnings`, package id/file/hash/integrity,
списки файлов и assets. Editor plugin не записывает HTML при package-ошибке. Повторная сборка
одинаковых входов проверяется на byte-identical `.vrmod`.

Проверка всех поддерживаемых форматов на каждой целевой платформе и сложные import options ещё
не реализованы.

Package-срез намеренно отклоняет `@tool`, `class_name`, абсолютные `res://`-ссылки,
выход пути за каталог проекта и непереносимые ссылки. Это пока проверка переносимости
пакета, а не sandbox для исполняемого GDScript.

---

## Как собирать сцену

1. Корень сцены — любой `Node3D`. **Прямые дети корня** становятся корнями блока `<vrweb>`
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
режим не экспортируются. Поддерживаемое avatar-подмножество и ограничения описаны в
[vrwml-format-and-pipeline.md](space/vrwml-format-and-pipeline.md).

`AvatarAnimationTreeApplier.animation_tree` экспортируется как относительный
`animation_tree_path: NodePath`. Массив `bindings` использует обычные ссылки
`SubResource:::id` на публичные ресурсы `AvatarParamBinding`, включая восстановление typed
array при импорте.

Avatar preview/import работают fail-closed: запрещённый класс, resource type, Script/property
или превышенный budget попадает в structured diagnostics `AvatarVrwmlPolicy`, после чего
частично собранное дерево не показывается и не сохраняется.

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

---

## Дебаг-превью

«Загрузить превью» собирает заявки `{defs, targets}` из меты сцены (та же форма, что у
читателя) и качает их через общий `VrwebExtInjector` (один код с рантаймом, см. ниже).
Текстуры/звук/меш подставляются в реальные свойства, скачанная `<ExtScene>` добавляется
ребёнком **без owner** — поэтому в `.tscn` не сериализуется.

> ⚠️ Превью **свойств** (texture/stream/mesh) пишется в реальное свойство — если сохранить
> сцену с активным превью, оно запечётся в `.tscn`. Жмите **Очистить превью** перед
> сохранением. Автоматический save-hook — будущая итерация.

---

## Как устроено в коде

| Файл | Роль |
|---|---|
| `addons/vrweb_tools/vrweb_exporter.gd` | `VrwebExporter.export_scene(root, mode)` — сериализатор (зеркало `VrwebBuilder`) |
| `addons/vrweb_tools/vrweb_ext_resource.gd` | `VrwebExtResource` (url+type) + ключи меты |
| `addons/vrweb_tools/vrweb_spawner.gd` | `VrwebSpawner` — узел-маркер правил спавна |
| `addons/vrweb_tools/vrweb_ext_preview.gd` | `VrwebExtPreview` — сбор меты + превью + очистка |
| `addons/vrweb_tools/vrweb_tools_plugin.gd` | `EditorPlugin` — док и обработчики кнопок |
| `addons/vrweb_tools/vrwml_avatar_scene_importer.gd` | Нативный `EditorSceneFormatImporter`: `.vrwml` появляется в Import/FileSystem dock как Godot scene |
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

Scene importer синхронный, поэтому документ с `<ExtResource>` он отклоняет вместо создания
частичной сцены. Для такого документа остаётся явная команда editable copy: она использует
асинхронные loaders, дожидается ресурсов и только затем сохраняет `.tscn`.

Содержимое док-панели находится в `ScrollContainer`: при недостаточной высоте прокручивается
сама панель, а не раздувается весь нижний dock.

### Нативный экспорт `.vrwml`

Плагин добавляет `VRWeb Scene…` в штатное меню Godot `Scene → Export As…` через
`EditorPlugin.get_export_as_menu()`. Команда экспортирует текущую открытую сцену тем же
`VrwebExporter`, что используется остальным pipeline, и показывает обычный resource file dialog.

Тип файла в Save As определяет envelope: `*.vrwml` сохраняет чистый VRWML, `*.html` — HTML с
вложенным `<vrweb>`. Штатная option `HTML scene mode` выбирает `combine` или `exclusive` и для
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
- Avatar VRWML round-trip и generated drift: `godot --headless --path . res://tests/test_avatar_vrwml.tscn`.
  Для регенерации `avatars/avatar_N.vrwml`: добавить `-- --write-vrwml`.
- В редакторе: собрать мини-сцену, выбрать `Scene → Export As… → VRWeb Scene…`, затем выбрать
  `VRWML scene` или `HTML with VRWeb wrapper` в file type selector. Для HTML дополнительно
  проверить оба значения `HTML scene mode`.

---

## Единый roadmap

Все незавершённые задачи exporter-а и внешних ресурсов ведутся в
[едином roadmap](roadmap.md#p1--exporter-и-внешние-ресурсы).
