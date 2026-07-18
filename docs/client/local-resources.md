# Локальные ресурсы — тестовый/офлайн-запуск HTML

Документ описывает, как открывать HTML-документы **без сети**: из файловой системы ОС
или из бандла приложения. Нужно для тестирования трансляции HTML→3D на фиксированных
страницах и для офлайн-демо, не поднимая веб-сервер.

## Две схемы

| Схема | Что адресует | Резолвится в путь |
|---|---|---|
| `vrweblocal://<абсолютный путь>` | файл из файловой системы ОС | сам путь (с ведущим `/`) |
| `vrwebresource://<относительный путь>` | файл из бандла приложения | `res://test_pages/<путь>` |

Примеры ввода в адресной строке:

```
vrwebresource://index.html
vrwebresource://rooms/gallery.html
vrweblocal:///Users/me/sites/demo/page.html
```

> `vrweblocal://` + абсолютный путь `/Users/...` даёт три слеша подряд
> (`vrweblocal:///Users/...`) — это нормально: после `://` идёт путь, начинающийся с `/`.

## Как это работает

Обе схемы ведут себя как обычный **origin**: всё после `://` — это путь (без хоста).
Относительные ссылки и картинки на локальной странице резолвятся внутри той же схемы,
поэтому переходы между локальными страницами и подгрузка локальных картинок работают
как на обычном сайте.

- `logo.svg` на `vrwebresource://index.html` → `vrwebresource://logo.svg`
- `rooms/gallery.html` → `vrwebresource://rooms/gallery.html`
- `../logo.svg` на `vrwebresource://rooms/gallery.html` → `vrwebresource://logo.svg`
- `#anchor` → якорь на той же странице
- абсолютный `https://...` со ссылки на локальной странице → уходит в сеть как обычно
  (внешний портал)

`..` за пределы корня схемы отбрасывается — выйти из песочницы `res://test_pages/`
(или подняться выше корня ФС) нельзя.

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
| `PageFetcher.LOCAL_SCHEME` / `RESOURCE_SCHEME` / `RESOURCE_ROOT` | константы схем и корень ресурсов |
| `PageFetcher.is_local(url)` | признак локальной схемы |
| `PageFetcher.is_bundle_resource(url)` | признак бандл-ресурса (`vrwebresource://` → `res://`) — грузить через `ResourceLoader` |
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

## Тестовые страницы

В `test_pages/` лежит мини-сайт для проверки:

```
test_pages/
  index.html          корневая страница (img logo.svg, ссылки, секции)
  about.html          ссылки index.html и rooms/gallery.html
  external_script.html выполняет два linked-файла и inline-контроллер
  external_model.luau объявляет общий utility-класс SpeedModel
  external_tiny.luau  использует SpeedModel и объявляет SpinnerView
  logo.svg            картинка рядом с index.html
  rooms/
    gallery.html      картинки art.svg и ../logo.svg
    art.svg           картинка в подпапке
```

Открыть: ввести `vrwebresource://index.html` в адресной строке и ходить по ссылкам.

## Экспорт (важно)

В **редакторе** `res://` читается прямо из папки проекта, поэтому `.html`/`.svg` из
`test_pages/` доступны без настройки. В **собранном** билде есть два разных подвоха —
по типу файла:

**1. Неимпортируемые файлы (`.html`) не попадают в `.pck` автоматически.** `.html` —
не ресурс Godot, импортёр его не трогает, и при `export_filter="all_resources"` он в
бандл не пакуется → `FileAccess` его не находит. Решение: `include_filter="test_pages/*"`
в `export_presets.cfg` (Project → Export → Resources → «Filters to export non-resource
files/folders»). Уже прописано в обоих пресетах.

**2. Импортируемые ресурсы (`.svg`/`.png`/аудио/glTF) ремапятся.** Их Godot конвертирует
при импорте: по `res://test_pages/logo.svg` в билде лежит не svg, а
`res://.godot/imported/logo.svg-<md5>.ctex` (отсюда «лишние символы» в имени), а `.import`
содержит `[remap]` на этот файл. `FileAccess` ремапы **не следует** — сырых байтов по
исходному пути нет. Поэтому бандл-ресурсы грузятся через **`ResourceLoader.load()`**
(он ремап учитывает и возвращает уже готовый `Texture2D`/`AudioStream`/`PackedScene`),
а не побайтово.

**Единая ось ветвления** (не «локальный vs сетевой»):

| Источник | Как грузим |
|---|---|
| `vrwebresource://` → `res://…` (бандл-ресурс) | `ResourceLoader.load()` — следует import-ремапу |
| `vrweblocal://` → файл ОС | сырые байты через `FileAccess` (ОС-файлы не импортируются) |
| `http(s)://` | сырые байты через `HTTPRequest` |
| `vrwebblob://sha256/<hex>` (realtime-ресурс) | сырые байты из `BlobStore` (локальный кэш или p2p-догрузка у пиров) — см. [realtime-resources.md](../network/realtime-resources.md) |

Развилка инкапсулирована в загрузчиках: `PageFetcher.is_bundle_resource(url)` отличает
бандл-ресурс, и для него `ImageLoader`/`VrwebResourceLoader` идут в `ResourceLoader`; для
файла ОС и сети — прежний байтовый путь. `.html` на `vrwebresource://` сам уходит в
байтовую ветку: `ResourceLoader.exists()` для неимпортируемого `.html` вернёт false.
