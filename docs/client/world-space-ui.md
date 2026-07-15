# World-space UI

World-space UI - это любой плоский интерфейс или медиа-поверхность, размещённая в 3D-сцене:
изображение, текстовая панель, видеоэкран, будущая таблица, кнопочная панель, форма.

## Иерархия

База всех таких элементов - [`WorldUiSurface`](../../actors/world_ui/world_ui_surface.gd).
Она отвечает за:

- единый collision layer 2 и `collision_mask = 0`, чтобы игрок проходил сквозь панели, а
  луч взаимодействия их видел;
- перевод мировой точки попадания в UV `(0,0)..(1,1)` с началом сверху слева; наследник
  возвращает `ui_size()` и, если root не совпадает с центром плоскости, `ui_center_local()`;
- отражение `u` на обратной стороне двухсторонней панели, чтобы клик совпадал с видимым
  незеркальным содержимым;
- общий контракт `pointer_enter`, `hover_at`, `pointer_exit`, `interact_at`, `scroll_by`,
  `is_active_at`, `aim_hint_at`;
- сигнал `size_changed` для позднего reflow, когда фактический размер становится известен
  после загрузки текстуры, кадра видео или layout текста; наследники вызывают общий
  `notify_size_changed(new_size)`, а не эмитят базовый сигнал напрямую.

[`WorldUiCanvas`](../../actors/world_ui/world_ui_canvas.gd) наследуется от `WorldUiSurface`
и добавляет reusable 2D canvas на `SubViewport`: фронт/изнанку, коллайдер, unlit-материал с
viewport-текстурой и прокидывание mouse motion, left click и wheel в обычные Godot
`Control`-узлы. Шаблон сцены - [`world_ui_canvas.tscn`](../../actors/world_ui/world_ui_canvas.tscn).

Текущие наследники:

- `ImagePanel -> WorldUiSurface`: лёгкая медиа-поверхность без `SubViewport`;
- `RichPanel -> WorldUiCanvas`: `RichTextLabel`, inline-ссылки и скролл внутри canvas;
- `VrwebVideoScreen -> WorldUiSurface`: видео texture surface плюс playback UI;
- будущие таблицы, кнопки, формы и scroll views должны начинаться с `WorldUiCanvas`.

`Portal` и `Bubble` не наследуются от этой базы: они интерактивные 3D-объекты, но не UI-панели.

## Что взяли из VRChat/Unity

VRChat `VRC_UIShape` устроен вокруг одной идеи: world-space `Canvas` получает отдельную форму,
через которую игрок может point/click/scroll с дистанции. Ручная настройка требует правильного
слоя, box collider, world-space render mode, UI-элементов внутри canvas и отключённой navigation
у controls, иначе движение игрока начинает управлять UI. См. официальную документацию
VRChat: https://creators.vrchat.com/worlds/components/vrc_uishape/

Unity рекомендует думать в двух единицах сразу: pixel resolution canvas и физический размер в
метрах, а масштаб выводить как `meter_width / canvas_width`. Это совпадает с нашей метрикой
`PIXEL_PER_METER = 128.0`: layout живёт в пикселях SubViewport, а сцена получает размер в метрах.
Источник: https://docs.unity3d.com/2022.3/Documentation/Manual/HOWTO-UIWorldSpace.html

В VRChat UI events дополнительно ограничены allowlist'ом методов из соображений безопасности:
https://creators.vrchat.com/worlds/udon/ui-events/ . В Knossos это переводится в локальное
правило: world-space UI не должен напрямую выполнять сетевые или навигационные side effects из
произвольного Control. Панель эмитит узкое событие наружу (`link_activated`, video command,
tool action), а владелец сцены решает, что с ним делать.

## Проблемы VRChat, которые нельзя повторять

- Неправильный слой/collider. У нас layer/mask задаются в `WorldUiSurface._ready`, а не в каждом
  наследнике вручную.
- Дублированный hit-test. Поверхность возвращает `ui_size()`, а world->UV считается один раз в
  базе. Наследники получают UV/px и не пересчитывают `to_local` сами.
- Зависший hover. `Player._dispatch_hover` хранит текущую поверхность и явно вызывает
  `pointer_exit` при смене цели или уходе луча.
- Невидимые блокеры. Для canvas-панелей декоративные `Control`-узлы должны получать
  `mouse_filter = MOUSE_FILTER_IGNORE`, если они не являются hit-target; это тот же класс
  проблем, что `Raycast Target` у перекрывающих Unity Graphics.
- Управление UI клавишами движения. Пока мышь захвачена для прогулки, обычный overlay UI не
  фокусируется; для будущих world-space форм нужно явно входить в режим фокуса, а не давать
  WASD/стики менять `Control` navigation.
- Одна сторона панели. Наши canvas и изображения имеют отдельную back-грань и отражение `u` в
  общей базе, поэтому клик сзади попадает в тот же визуальный элемент, который видит игрок.

## Как добавлять новый элемент

Если новый элемент - это таблица, кнопки, форма, список или другой 2D Control UI:

1. Инстансить или наследовать `actors/world_ui/world_ui_canvas.tscn`.
2. Положить постоянные `Control`-узлы внутрь `SubViewport` в `.tscn`.
3. Размер менять через `configure_canvas_geometry(size_m)`, а не напрямую через mesh/collider.
4. Для специфичного поведения переопределять hooks `_on_ui_accept`, `_on_ui_scroll`,
   `_ui_is_active`, `_ui_hint` только если обычного canvas input недостаточно.
5. Сетевые действия и навигацию наружу отдавать через сигналы, а не выполнять из произвольного
   дочернего Control.

Если элемент - просто текстура/медиа без `Control`-дерева, наследоваться напрямую от
`WorldUiSurface` и реализовать `ui_size()` плюс нужные hooks.
