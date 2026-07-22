# Локальные ресурсы — тестовый/офлайн-запуск HTML

Документ описывает, как открывать HTML-документы **без сети**: из файловой системы ОС
или из бандла приложения. Нужно для тестирования трансляции HTML→3D на фиксированных
страницах и для офлайн-демо, не поднимая веб-сервер.

## Две схемы

| Схема | Что адресует | Резолвится в путь |
|---|---|---|
| `vrweblocal://<абсолютный путь>` | файл из файловой системы ОС | сам путь (с ведущим `/`) |
| `vrwebresource://<относительный путь>` | бандл-контент клиента | `res://vrweb/builtin/<путь>` |

`vrwebresource://` — **часть стандарта**: схема общая, но контент у каждого клиента свой.
Все клиенты знают о таких путях (например `vrwebresource://index.html`) и встречаются на них
независимо от реализации — как dashboard-страница в разных браузерах. Knossos как референсный
клиент кладёт под этот корень свой обязательный встроенный контент: дашборд/туториал и
документы предметов тулбара.

### Подпуть `vrwebresource://examples/` — примеры Maker Kit

Демонстрации возможностей **стандарта VRWeb** — это в первую очередь показ того, что умеет
стандарт, а не конкретный Knossos. Поэтому они принадлежат аддону Maker Kit
(`addons/vrweb_tools/examples`), а не клиенту. Аддон всегда релизится вместе с Knossos и
бандлится в клиент, так что Knossos дополнительно **монтирует** их под своим подпутём
`vrwebresource://examples/` → `res://addons/vrweb_tools/examples/`.

Важно: это НЕ отдельная схема и НЕ часть стандарта — просто выбор Knossos, что забандлить под
своим (per-client) `vrwebresource://`. Другой клиент этих путей может не иметь; никакой клиент
не обязан «реализовывать примеры». Отдельную схему под это заводить нельзя — она создавала бы
ложное впечатление, что примеры стандартизированы.

Примеры ввода в адресной строке:

```
vrwebresource://index.html                  встроенный дашборд клиента (Knossos)
vrwebresource://examples/index.html         хаб примеров Maker Kit
vrwebresource://examples/state_switch.html  демо стандарта
vrweblocal:///Users/me/sites/demo/page.html
```

> `vrweblocal://` + абсолютный путь `/Users/...` даёт три слеша подряд
> (`vrweblocal:///Users/...`) — это нормально: после `://` идёт путь, начинающийся с `/`.

## Как это работает

Обе схемы ведут себя как обычный **origin**: всё после `://` — это путь (без хоста).
Относительные ссылки и картинки на локальной странице резолвятся внутри той же схемы,
поэтому переходы между локальными страницами и подгрузка локальных картинок работают как на
обычном сайте. Встроенный контент и примеры — это один origin `vrwebresource://` (весь контент
доверенный, забандленный в приложение), поэтому дашборд и примеры могут ссылаться друг на друга;
граница изоляции проходит между схемами (`vrweblocal` ↔ `vrwebresource` ↔ сеть), а не внутри
бандла.

- `logo.svg` на `vrwebresource://index.html` → `vrwebresource://logo.svg`
- `state_switch.html` на `vrwebresource://examples/index.html` → `vrwebresource://examples/state_switch.html`
- `../logo.svg` на `vrwebresource://examples/rooms/gallery.html` → `vrwebresource://examples/logo.svg`
- `#anchor` → якорь на той же странице
- абсолютный `https://...` со ссылки на локальной странице → уходит в сеть как обычно
  (внешний портал)

`..` за пределы корня схемы отбрасывается — выйти из песочницы `res://vrweb/builtin/`
или `res://addons/vrweb_tools/examples/` (или подняться выше корня ФС) нельзя.

## Тег `<base href>` — переопределение базы

По стандарту HTML `<base href="...">` в `<head>` задаёт **базовый адрес** документа: все
относительные URL страницы (ссылки `<a>`, картинки `<img>`, видео `<video>`, внешние ресурсы
`<ExtResource>`) резолвятся относительно него, а не относительно адреса страницы. Клиент это
учитывает: `main._resolve_base_url(doc, page_url)` находит первый `<base href>` и резолвит его
(сам href может быть относительным или protocol-relative — резолвится относительно адреса
страницы). Результат (`_base_url`) идёт как база в `VrwebBuilder.build`, `WorldGenerator.generate`
и в навигацию по ссылкам (`_activate_transition` → `_navigate`).

Без `<base>` база = адрес страницы (`final_url`), как раньше. Важно: `seed`, история и комната
мультиплеера по-прежнему ключуются по `final_url` (реальный адрес страницы), а не по базе —
`<base>` влияет только на резолвинг относительных URL внутри страницы.

## URL из HTML-атрибутов

HTML-атрибуты вроде `<img src="/games/Space Invaders.gif">` могут содержать пробелы:
браузеры перед сетевым запросом кодируют их как `%20`. `HTTPRequest` в Godot такой
автонормализации не делает и ждёт уже корректный URL, поэтому `PageFetcher.resolve_url()`
минимально экранирует пробелы в `http(s)`-адресах. Это важно не только для картинок/GIF,
но и для видео, внешних сцен и других ресурсов, которые идут через общий резолвинг.

## Где в коде

| Место | Что делает |
|---|---|
| `PageFetcher.LOCAL_SCHEME` / `RESOURCE_SCHEME` | константы двух схем |
| `PageFetcher.RESOURCE_ROOT` | корень бандл-контента клиента (`res://vrweb/builtin/`) |
| `PageFetcher.EXAMPLE_MOUNT` / `EXAMPLE_ROOT` | подпуть `examples/` монтируется в демо аддона (`res://addons/vrweb_tools/examples/`) |
| `PageFetcher.is_local(url)` | признак локальной/бандл-схемы |
| `PageFetcher.local_scheme_of(url)` | схема локального/бандл-адреса (для same-origin проверок) или `""` |
| `PageFetcher.is_bundle_resource(url)` | признак бандл-ресурса (`vrwebresource://` → `res://`, включая mount `examples/`) — грузить через `ResourceLoader` |
| `PageFetcher.resolve_url()` | распознаёт схемы; `_normalize_local` / `_join_local` / `_collapse_dots` резолвят пути внутри схемы |
| `PageFetcher.to_file_path(url)` | vrweb-адрес → путь для `FileAccess`/`ResourceLoader` |
| `PageFetcher._fetch_local()` | читает HTML синхронно через `FileAccess` (HTML не импортируется — байты есть всегда) |
| `ImageLoader._load_local()` | бандл-ресурс → `ResourceLoader.load`; файл ОС → байты через `FileAccess` |
| `VrwebResourceLoader.request_scene/mesh/audio()` | бандл-ресурс → `ResourceLoader.load`; иначе сырые байты + статический декодер |

Ключевая идея: единственная точка ветвления — `is_local()`. Резолвинг общий
(`resolve_url`), поэтому остальной пайплайн (топология, геометрия, навигация, картинки)
работает с локальными страницами без изменений. `final_url`, который эмитит
`PageFetcher`, — та же vrweb-схема, так что относительные ссылки страницы продолжают
резолвиться корректно при дальнейшей навигации.

## Встроенный контент клиента (`vrwebresource://`)

В `res://vrweb/builtin/` лежит обязательный контент, который идёт именно из Knossos:
дашборд/туториал и документы предметов тулбара.

```
vrweb/builtin/
  index.html          дашборд клиента (img logo.svg, ссылки, ссылка на примеры)
  about.html          ссылки index.html и на хаб примеров
  logo.svg            картинка рядом с index.html
  items/
    pencil.html       карандаш тулбара (см. docs/space/tool-authoring.md)
    eraser.html       ластик тулбара
    image_frame.html  рамка-картинка тулбара
```

Открыть: ввести `vrwebresource://index.html` в адресной строке и ходить по ссылкам.
Ссылка «Примеры стандарта VRWeb» на дашборде ведёт в хаб демо через `vrwebresource://examples/`.

## Примеры стандарта (mount `vrwebresource://examples/`)

Демонстрации возможностей стандарта VRWeb поставляются с **Maker Kit** и физически лежат в
аддоне: `res://addons/vrweb_tools/examples/`. Knossos монтирует их под подпутём
`vrwebresource://examples/` (см. `PageFetcher.EXAMPLE_MOUNT`) — это выбор клиента, что
забандлить, а не отдельная схема. Это образцы разметки и Luau-скриптов для авторов миров
(css/изображения/grabbable/физика/remote call/remote data/shader lab/видео/экспорт
Godot-сцены и т.д.). Точка входа — `vrwebresource://examples/index.html`. Демо, которым нужны
внешние файлы (например `external_script.html` → `external_model.luau`), держат их рядом и
резолвят относительно, внутри той же схемы.

## Экспорт (важно)

В **редакторе** `res://` читается прямо из папки проекта, поэтому `.html`/`.svg` из
`vrweb/builtin/` и `addons/vrweb_tools/examples/` доступны без настройки. В **собранном**
билде есть два разных подвоха — по типу файла:

**1. Неимпортируемые файлы (`.html`) не попадают в `.pck` автоматически.** `.html` —
не ресурс Godot, импортёр его не трогает, и при `export_filter="all_resources"` он в
бандл не пакуется → `FileAccess` его не находит. Решение:
`include_filter="vrweb/*,addons/vrweb_tools/examples/*"` в `export_presets.cfg`
(Project → Export → Resources → «Filters to export non-resource files/folders»).
Уже прописано во всех пресетах.

**2. Импортируемые ресурсы (`.svg`/`.png`/аудио/glTF) ремапятся.** Их Godot конвертирует
при импорте: по `res://vrweb/builtin/logo.svg` в билде лежит не svg, а
`res://.godot/imported/logo.svg-<md5>.ctex` (отсюда «лишние символы» в имени), а `.import`
содержит `[remap]` на этот файл. `FileAccess` ремапы **не следует** — сырых байтов по
исходному пути нет. Поэтому бандл-ресурсы грузятся через **`ResourceLoader.load()`**
(он ремап учитывает и возвращает уже готовый `Texture2D`/`AudioStream`/`PackedScene`),
а не побайтово.

**Единая ось ветвления** (не «локальный vs сетевой»):

| Источник | Как грузим |
|---|---|
| `vrwebresource://` → `res://…` (бандл-ресурс, включая mount `examples/`) | `ResourceLoader.load()` — следует import-ремапу |
| `vrweblocal://` → файл ОС | сырые байты через `FileAccess` (ОС-файлы не импортируются) |
| `http(s)://` | сырые байты через `HTTPRequest` |
| `vrwebblob://sha256/<hex>` (realtime-ресурс) | сырые байты из `BlobStore` (локальный кэш или p2p-догрузка у пиров) — см. [realtime-resources.md](../network/realtime-resources.md) |

Развилка инкапсулирована в загрузчиках: `PageFetcher.is_bundle_resource(url)` отличает
бандл-ресурс, и для него `ImageLoader`/`VrwebResourceLoader` идут в `ResourceLoader`; для
файла ОС и сети — прежний байтовый путь. `.html` на `vrwebresource://`/`vrwebresource://examples/`
сам уходит в байтовую ветку: `ResourceLoader.exists()` для неимпортируемого `.html`
вернёт false.
