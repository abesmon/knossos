# Карандаш и ластик (штрихи)

> Штрихи — объекты [эфемерного слоя](../network/ephemeral-changes.md): универсальный
> `kind="vrweb-node"` со специальным VRWML-тегом `<VRWebStroke>`.
> Инструменты рисования с июля 2026 — **переносимые предметы**
> ([pencil.html](../../test_pages/items/pencil.html) /
> [eraser.html](../../test_pages/items/eraser.html), слот 2 тулбелта — см.
> [tools.md](tools.md) и [portable-tools.md](../space/portable-tools.md)); клиентский
> `DrawingTool` удалён. Этот документ описывает штрих как предметную сущность: контракт
> данных, материализацию и поведение item-инструментов.

## Что это

- Кнопка **2** достаёт карандаш-предмет в руку. Зажатая **ЛКМ** ведёт штрих по прицелу —
  по поверхности (точка луча + отступ по нормали) или в воздухе перед камерой, если луч ни
  во что не упёрся. Отпускание — один `op=add` в слой.
- Повторное **2** — ластик (стирает свои штрихи под прицелом), ещё раз — инструмент убран.
  Цикл `НЕТ → КАРАНДАШ → ЛАСТИК → НЕТ` сохранился, но циклит его `ItemToolbelt` сменой
  предмета в руке.
- Один непрерывный штрих = **один** эфемерный объект, рендерится **одним** мешем
  (труба вдоль полилинии): один draw-call на штрих, без физ-коллайдеров.

## Слои

| Слой | Файл | Роль |
|---|---|---|
| **Данные/геометрия** (чистая, агностичная) | [scripts/ephemeral/stroke_path.gd](../../scripts/ephemeral/stroke_path.gd) `StrokePath` | flat↔точки, Douglas–Peucker, хит-тест полилинии — используется материализацией; item-скрипты делают эквивалент на Luau |
| **Протокол** | `SceneChanges` / `NetworkManager` | `kind="vrweb-node"`, `props.tag="VRWebStroke"`, строковые `props.attrs`; обычные `add`/`remove` |
| **Материализация** | [actors/stroke/stroke.gd](../../actors/stroke/stroke.gd) `StrokeActor` + [vrweb_builder.gd](../../scripts/vrweb_builder.gd) | специальный тег строится общим путём `vrweb-node`; один меш; группа `ephemeral_stroke` |
| **Инструменты** | [items/pencil.html](../../test_pages/items/pencil.html), [items/eraser.html](../../test_pages/items/eraser.html) | Luau в realm предмета: `use`/`use_end` + `document.player.aim` → `document.scene` |
| **Тесты** | [tests/test_stroke_path.gd](../../tests/test_stroke_path.gd), [tests/test_vrweb_stroke.gd](../../tests/test_vrweb_stroke.gd), [tests/test_item_tools.gd](../../tests/test_item_tools.gd) | чистая геометрия; документный тег VRWML; полный цикл рисования/стирания item-инструментами |

## Данные штриха

Каноническая разметка: `<VRWebStroke points="[x0,y0,z0,…]" color="Color(r,g,b,1)" width="0.02"/>`.
В realtime-слое это `props: {tag:"VRWebStroke", attrs:{points, color, width}}`; значения
атрибутов — строки VRWML. Точки — **мировые**
координаты (`parent=""`), поэтому `StrokeActor` стоит в начале координат, а вершины абсолютны.
Полный контракт объекта — в
[ephemeral-changes.md](../network/ephemeral-changes.md#штрихи-второй-инструмент).

## Поток рисования (финализация при отпускании)

1. **use** (нажатие ЛКМ с карандашом в руке): скрипт начинает копить точки.
2. **ведение** (`document.on_update`): точка = `aim.position + normal*0.01` при попадании,
   иначе `aim.origin + direction*1.2` (рисование в воздухе). Прореживание шагом 3 см,
   потолок 200 точек (props-бюджет слоя). Превью — временные `CSGSphere3D`-точки через
   `document.create` (снимаются при финализации/отмене).
3. **use_end**: если точек ≥ 2 — один `document.scene.add` с `kind="vrweb-node"` и тегом
   `VRWebStroke`.
   Никаких `update` по ходу: один штрих — ровно один объект, минимум трафика.
4. **drop** (выпал из руки посреди ведения — G/кража): незавершённый штрих отменяется.

**Офлайн** слой работает standalone-машиной
([ephemeral-changes.md](../network/ephemeral-changes.md#доступ-скриптов-к-слою)) — рисование
вне комнаты живёт в локальной сессии и заменяется снимком комнаты при подключении.

## Ластик

Пока ЛКМ зажата, скрипт раз в ~0.12 с берёт `document.scene.objects("vrweb-node")`, оставляет
только объекты с `props.tag="VRWebStroke"`, фильтрует по
`bindings.creator == свой user_id` (чужие всё равно отклонил бы authority) и проверяет дистанцию точки
прицела до полилинии (та же математика, что `StrokePath.distance_to_polyline`, на Luau);
попадание → `document.scene.remove(id)`.

## Минимум мешей

Один `StrokeActor` = один `MeshInstance3D` с одним `ImmediateMesh` (труба из `SIDES` граней,
параллельный перенос рамки без закрутки), `StandardMaterial3D` unshaded. Хит-тест — чистая
математика по полилинии, **без** физ-коллайдеров на сегментах.

## Точки расширения

- **Цвет/толщина**: цвет — стабильный оттенок по `user_id` (считается в Luau); UI выбора —
  дело самого item'а (например, use по палитре).
- **Частичное стирание**: разрезать штрих на два (remove + 2×add) — отложено.
- **Граффити-права**: стирать чужие штрихи — политика по тегу внутри `vrweb-node`
  (capabilities), как предусмотрено в
  [ephemeral-changes.md](../network/ephemeral-changes.md#права).
- **Персистенция**: `ttl=0` делает штрихи кандидатами на выгрузку — как прочие эфемерные
  объекты.
