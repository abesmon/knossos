# docs / space

Практические руководства для авторов контента:

- [subject-bindings-guide.md](subject-bindings-guide.md) — назначаемые роли `creator`,
  `holder`, `presenter`, `editor`, `driver`: policies, атомарные reducers и сложные сценарии.

Здесь собраны документы про то, как из веб-страницы получается **3D-пространство**: правила
процедурной генерации из обычного HTML и правила сборки декларативной сцены из VRWML. Это ядро Слоя 1
из обзора ([../README.md](../README.md)).

Этот раздел задаёт независимые от движка правила и контракты VRWeb. Он не предписывает
GDScript-классы, структуру Godot-сцен, конкретные API рендера или обходные пути движка.
То, как эти правила воплощены в Godot-клиенте Knossos, описано отдельно в
[client/implementation.md](../client/implementation.md).
При расхождении документов нормативным источником для процедурной генерации и организации
пространства считается `space/`; `client/` фиксирует только текущее поведение реализации.
Public page scripting API и capability contract — в [scripting-api.md](scripting-api.md).
Единая passthrough/audit boundary декларативного контента — в
[content-policy.md](content-policy.md).

## От HTML к топологии

- [content-sectioning.md](content-sectioning.md) — вычленение осмысленного контента и
  сегментация страницы по заголовкам.
- [html-to-3d-topology.md](html-to-3d-topology.md) — как дерево HTML сворачивается в топологию
  пространства (комнаты, соединители, связи) без координат.
- [clustering.md](clustering.md) — кластеризация: как из дерева кластеров получаются комнаты.
- [css-cascade.md](css-cascade.md) — мини-каскад CSS на GDScript: вычисленные стили элементов,
  которые кормят топологию и визуализацию.

## От топологии к геометрии

- [geometry-lab.md](geometry-lab.md) — предписанный алгоритм организации пространства: формы
  комнат из пентамино, примыкание, коридоры и детерминированность; конкретный 3D-рендер клиента
  вынесен в [client/implementation.md](../client/implementation.md).
- [world-visualization.md](world-visualization.md) — визуализация мира из стилей документа: небо,
  солнце, палитра из «визуального паспорта» страницы.

## Кастомные сцены

- [vrwml-format-and-pipeline.md](vrwml-format-and-pipeline.md) — нормативная модель VRWML:
  единый формат сцен, все Godot-классы, специальные стандартные классы и формы доставки.
- [vrwml-tags.md](vrwml-tags.md) — подробный реализованный каталог стандартных тегов VRWML,
  режимы композиции, загрузка внешних GLB-ресурсов и ограничения текущего Knossos runtime.

## Предметы и инструменты

- [grabbable.md](grabbable.md) — нормативный контракт предметов, которые участник берёт в
  руку: тег, hold-состояние, точки крепления, события.
- [portable-tools.md](portable-tools.md) — архитектура переносимых инструментов: почему
  инструмент это предмет со скриптом, что уже есть и куда расти.
- [tool-authoring.md](tool-authoring.md) — руководство автора: как собрать свой
  инструмент-предмет, паттерны ввода, артефакты, лимиты и чек-лист.

## Исследования других платформ

- [vrchat-developer-api.md](vrchat-developer-api.md) — карта SDK/Udon, Player API, persistence,
  media, avatars, OSC и внешнего HTTP API VRChat; ограничения и выводы для API VRWeb.
