# VRWeb — инструментарий редактора (сборка и экспорт сцен)

> **Суть:** обратное к [vrweb-tags.md](space/vrweb-tags.md) направление. Сцену собирают в
> редакторе Godot обычными узлами, жмут **Экспорт** — и плагин генерирует HTML-документ
> с блоком `<vrweb>`. Плюс авторинг внешних ресурсов по URL и дебаг-превью, чтобы увидеть
> их прямо в редакторе без записи в файлы.

Плагин: `addons/vrweb_tools/` (включается в Project → Plugins, уже включён в `project.godot`).
Док-панель «VRWeb» появляется справа-снизу.

---

## Что делает плагин

| Действие (кнопка дока) | Результат |
|---|---|
| **Экспорт в HTML…** | сериализует открытую сцену в standalone `.html` с блоком `<vrweb>` |
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
| [scripts/vrweb_ext_injector.gd](../scripts/vrweb_ext_injector.gd) | `VrwebExtInjector.inject(ext, image_loader, host)` — общая докачка/вставка ext-ресурсов (рантайм + превью) |

Сериализация значений — `var_to_str` (даёт `Transform3D(...)`/`Vector3(...)`/числа/`"строки"`),
ровно то, что читатель разбирает через `str_to_var`. Значения HTML-экранируются
(`& < > "` → сущности), а `HtmlParser._decode_entities` декодирует обратно — round-trip строк
с кавычками сохраняется.

---

## Проверка

- Headless round-trip: `godot --headless --path . --script res://tests/test_export.gd`
  (собирает сцену → экспорт → `HtmlParser` → `VrwebBuilder` → сверка узлов/ресурсов/ext/спавна).
- В редакторе: собрать мини-сцену, привязать ext к `Sprite3D.texture`, «Загрузить превью»,
  «Экспорт в HTML…» в `res://test_pages/`, затем открыть `vrwebresource://<файл>.html` в клиенте.

---

## Дальше

- Save-hook, автоматически снимающий превью свойств перед сохранением.
- Песочница читателя (см. риск в [vrweb-tags.md](space/vrweb-tags.md)) — экспорт пишет доверенный
  контент, но клиент по-прежнему инстанцирует любой класс при чтении.
- Больше типов ext (материалы, видео), инлайн GLTF, экспорт `vr-on`/`vr-action`.
