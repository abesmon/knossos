# docs / space

Здесь собраны документы про то, как из веб-страницы получается **3D-пространство**: правила
процедурной генерации из обычного HTML и правила сборки сцены из vrweb-тегов. Это ядро Слоя 1
из обзора ([../README.md](../README.md)).

Как эти правила воплощены в коде пайплайна — в [implementation.md](../implementation.md).
Public API внешних scripting modules и capability contract — в [scripting-api.md](scripting-api.md).
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

- [geometry-lab.md](geometry-lab.md) — `SpaceLayout`, единый генератор пространства (формы комнат
  из пентамино, примыкание, коридоры); кормит и 3D-мир, и отладочный вид сверху.
- [world-visualization.md](world-visualization.md) — визуализация мира из стилей документа: небо,
  солнце, палитра из «визуального паспорта» страницы.

## Кастомные сцены

- [vrweb-tags.md](vrweb-tags.md) — vrweb-теги: собственный синтаксис сцены поверх HTML, режимы
  `combine`/`exclusive`, загрузка внешних GLB-ресурсов.
- [vrwml-format-and-pipeline.md](vrwml-format-and-pipeline.md) — целевой standalone-формат
  `.vrwml` поверх существующей class-name/property-модели, стандартные avatar-классы и
  двусторонний editor/runtime-пайплайн без публичной зависимости от `.tscn`.
