# Система инструментов

> Пользовательские инструменты — **переносимые предметы** (items): блок «VRWML + Luau»,
> который клиент спавнит в мир и берёт в руку; вся логика инструмента живёт в самом item,
> клиент лишь достаёт и убирает предметы (модовая модель,
> [docs/space/portable-tools.md](../space/portable-tools.md)). В клиенте остались только
> **системные** механики: пузырь навигации и тонкий тулбелт хоткеев.

## Модель: инструмент = предмет

Инструмент — обычный [grabbable](grabbable.md)-предмет со скриптом
([item-runtime](../network/ephemeral-changes.md#переносимые-предметы-kindvrweb-item)):
его можно взять, носить, положить, отобрать (по `theft`-политике), его видно другим игрокам
в руке. Поведение — Luau в собственном realm предмета со стандартным capability pool:
`use`/`use_end` + `document.player.aim` — действие, `document.scene` — артефакты,
`document.files.pick` — импорт файлов. Артефакты инструментов (штрихи, картинки, пузыри) —
обычные объекты [эфемерного слоя](../network/ephemeral-changes.md).

## Стандартные item-инструменты (бандл)

| Слот | Item | Поведение |
|---|---|---|
| **2** (цикл: нет → карандаш → ластик → нет) | [pencil.html](../../test_pages/items/pencil.html) | зажатая ЛКМ ведёт штрих по прицелу (поверхность или воздух), отпускание — один `kind="stroke"` в слой; превью — временные CSG-точки; выпадение из руки отменяет незавершённый штрих |
| | [eraser.html](../../test_pages/items/eraser.html) | зажатая ЛКМ стирает СВОИ штрихи под прицелом (`document.scene.objects("stroke")` + хит-тест полилинии в Luau; чужие отклонил бы авторитет) |
| **3** (тумблер) | [image_frame.html](../../test_pages/items/image_frame.html) | ЛКМ фиксирует точку прицела и открывает `files.pick("image")`; картинка уезжает в блоб-стор и ставится `vrweb-node`-объектом `<VRWebImage>` (разворот по нормали стены или лицом к игроку) |

Item-инструменты — обычные страницы-документы: их можно править без пересборки клиента, а
сторонние инструменты подключаются тем же механизмом (`kind="vrweb-item"` с любым `src`).

## Клиентская часть

```
Player (хаб ввода: _unhandled_input, именованные действия)
├── ToolManager (actors/tools/tool_manager.gd) — СИСТЕМНЫЕ инструменты (пузырь), без слотов
│   └── BubbleTool  ← программный вызов (main._drop_leave_bubble)
└── (в мире) ItemToolbelt (actors/tools/item_toolbelt.gd) ← tool_slot_2 / tool_slot_3
    └── спавнит vrweb-item + авто-захват в руку; уборка = release + remove
```

- **[item_toolbelt.gd](../../actors/tools/item_toolbelt.gd) `ItemToolbelt`** — тонкая
  обвязка: хоткей слота → `scene_action add {kind="vrweb-item"}` → ожидание материализации →
  `GrabManager.request_grab`. Живёт в мире (создаёт `main._rebuild_world`), находится через
  группу `item_toolbelt`. Знает только src бандловых item'ов и подсказки статус-строки;
  логики инструментов в нём нет.
- **[player_tool.gd](../../actors/tools/player_tool.gd) `PlayerTool` / `ToolManager`** —
  каркас системных инструментов (контракт «максимум один активный», маршрутизация ввода).
  Сейчас единственный жилец — **BubbleTool** (пузырь «ушёл сюда», вызывается программно из
  `main` при навигации; см. [ephemeral-changes.md → Пузыри](../network/ephemeral-changes.md#пузыри-первый-инструмент)).
- **`Player`** остаётся хабом ввода: `tool_slot_2/3` идут в тулбелт; ЛКМ — приоритет:
  активный системный инструмент → `use` держимого предмета → взаимодействие (`interact_at`);
  G — положить предмет. См. [controls.md](controls.md) и [grabbable.md](grabbable.md).

## Границы

- **Спавн артефактов** — из скрипта item'а через `document.scene`
  ([scripting-api.md](../space/scripting-api.md#эфемерный-слой-сцены-vrwebscene-objects1));
  офлайн работает через standalone-режим слоя (артефакты сессионные).
- **UI (файловый диалог, статус-строка)** — у `main`: OS-пикер инжектируется в runtime как
  провайдер `document.files.pick`, подсказки тулбелта идут в статус-строку сигналом.
- **Новый инструмент** = item-документ (VRWML c `<VRWebGrabbable>` + `<script
  type="application/vrweb+luau">`) — клиент не меняется. Руководство автора —
  [docs/space/tool-authoring.md](../space/tool-authoring.md), архитектура —
  [portable-tools.md](../space/portable-tools.md).
- **Смоук-тесты**: [tests/test_item_tools.gd](../../tests/test_item_tools.gd)
  (`godot --headless tests/test_item_tools.tscn`) — тулбелт + все три item'а end-to-end;
  [tests/tool_system_test.gd](../../tests/tool_system_test.gd) — системный остаток
  (ToolManager/пузырь).

## История

До июля 2026 инструменты были вшитыми в клиент классами (`DrawingTool`,
`ImagePlacementTool` — наследники `PlayerTool` со слотами в `ToolManager`). Они заменены
item-инструментами без потери функциональности; чистые слои того периода живут дальше:
`StrokePath` (геометрия штриха — материализация `StrokeActor`) и контракт `kind="stroke"`
не менялись. Архив описания старой системы — в истории git этого файла и
[pencil-tool.md](pencil-tool.md).
