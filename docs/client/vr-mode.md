# VR-режим и полный контроль аватара

> Статус: план работ. VR-режим должен стать ещё одним представлением клиента Knossos в
> спектре graceful degradation: тот же инстанс, тот же сетевой слой, те же аватары, но локальный
> источник позы берётся из XR-трекинга, а не из мыши/клавиатуры.

## Цель

Нужно уметь запускать приложение в VR так, чтобы пользователь:

- видел мир через HMD;
- управлял перемещением и взаимодействиями VR-контроллерами или hand tracking;
- видел своё тело в зеркалах и, где уместно, свои руки от первого лица;
- передавал другим пользователям богатую позу: от 3-точечного трекинга
  `(head, left hand, right hand)` до full body `(head, hands, waist, feet, knees, elbows...)`;
- оставался совместимым с десктопными пользователями и существующей сетью.

## Техническая опора

Godot уже даёт нужный нижний уровень:

- OpenXR включается как XR-интерфейс, после инициализации viewport переводится в `use_xr`; в
  XR-сцене нужны `XROrigin3D`, `XRCamera3D` и обычно два `XRController3D`.
  Официальная документация: <https://docs.godotengine.org/en/stable/tutorials/xr/setting_up_xr.html>.
- `XRServer` управляет интерфейсами, трекерами, `world_origin`, `world_scale` и умеет
  перецентрировать HMD через `center_on_hmd`.
  Документация: <https://docs.godotengine.org/en/stable/classes/class_xrserver.html>.
- Hand tracking в Godot/OpenXR можно подавать в скелет руки через `XRHandModifier3D`.
  Документация: <https://docs.godotengine.org/en/stable/tutorials/xr/openxr_hand_tracking.html>.
- Full body через HTC/Vive trackers в OpenXR представлен ролями трекеров:
  `left_foot`, `right_foot`, `waist`, `chest`, `left_knee`, `right_knee`,
  `left_elbow`, `right_elbow` и т.д. Они подключаются как `XRController3D` под
  `XROrigin3D`.
  Документация: <https://docs.godotengine.org/en/stable/tutorials/xr/openxr_body_tracking.html>.

Проект сейчас на Godot 4.6 (`project.godot`, `config/features=PackedStringArray("4.6", ...)`),
поэтому план ниже предполагает актуальный OpenXR-стек Godot 4.x.

Опыт и публичные failure modes VRChat, на которых основаны дополнительные архитектурные решения
этого плана: [vrchat-hybrid-lessons.md](vrchat-hybrid-lessons.md).

## Главный архитектурный принцип

Не делаем отдельный "VR-аватар" и не переписываем сеть. Делаем новый источник локальной позы.

Сейчас поток такой:

```text
Player + mouse/keyboard
  -> AvatarParameterSource
  -> AvatarParameters.snapshot()
  -> NetworkManager.send_state(pos, yaw, params)
  -> RemotePlayer/AvatarHost у других
```

Для VR поток должен стать таким:

```text
TrackingRig: DesktopTrackingRig или XRTrackingRig
  -> PresencePoseSource -> PlayerMotionSnapshot -> NetworkManager.send_motion(...)
  -> RemotePlayer/PresenceRig -> optional AvatarHost pose adapter

AvatarParameterSource -> AvatarParameters -> NetworkManager.send_avatar_params(...)
```

То есть существующая шина `AvatarParameters` остаётся контрактом для простых сигналов
(`VRMode`, `TrackingType`, скорости, voice, gestures), а motion pose получает отдельный логический
контракт. Сетевой транспорт не интерпретирует их содержимое, но rates/lifecycle у motion и avatar
parameters различаются. Existing `_recv_state` остаётся legacy path на время миграции.

Первой целевой платформой должен быть **PCVR через OpenXR**. Standalone Android/Quest надо
рассматривать отдельным потоком после рабочего PCVR vertical slice: у него другой бюджет GPU/CPU,
экспорт, разрешения, ввод текста, файловые диалоги и ограничения нативных зависимостей. Общая XR-
архитектура должна быть переносимой, но требовать standalone-поддержку от первого MVP слишком
рискованно.

## Режим запуска и состав билдов

Для desktop OS на первом этапе нужен **один бинарник на платформу**, способный запустить один из
двух client modes. Два независимых PC-билда создадут лишний риск расхождения ресурсов, протокола,
настроек и исправлений, хотя код и контент у режимов общие. Пользователю можно дать две launch
entries/ярлыка — «Knossos» и «Knossos VR» — но они должны вести в один executable с разными args.

Публичный режим запуска:

| Режим | Поведение |
|---|---|
| `desktop` | OpenXR не используется; создаются desktop tracking/actions/UI implementations |
| `vr` | клиент пытается поднять OpenXR и XR rig; ошибка показывается явно с возможностью продолжить в desktop |
| `auto` | клиент пытается поднять XR и молча деградирует в desktop; не делать default, пока не проверено, что это не будит runtime/SteamVR без намерения пользователя |

Default без аргумента — `desktop`. Надёжный приоритет выбора:

```text
CLI / launch entry -> desktop
```

Не следует автоматически включать VR из сохранённого setting: при Vulkan GDScript прочитает его
слишком поздно, после engine startup. Setting может хранить последнюю UI-конфигурацию режима, но
фактический следующий запуск задаёт shortcut/launcher или restart action с аргументами.

Канонические команды:

```bash
# Явный desktop
knossos --xr-mode off -- --client-mode=desktop

# Явный VR
knossos --xr-mode on -- --client-mode=vr

# Диагностический auto/fallback
knossos --xr-mode on -- --client-mode=auto
```

`--xr-mode on/off` — аргумент самого Godot и стоит до разделителя `--`. Пользовательский
`--client-mode=...` стоит после разделителя и читается через `OS.get_cmdline_user_args()`; это
рекомендуемый Godot способ передавать custom arguments без конфликта с engine flags:
<https://docs.godotengine.org/en/stable/classes/class_os.html#class-os-method-get-cmdline-user-args>.

Сейчас проект использует `renderer/rendering_method="gl_compatibility"`. Для non-Vulkan backend
Godot позволяет вызвать `OpenXRInterface.initialize()` во время работы приложения. Для Vulkan
OpenXR должен быть включён при старте процесса; движковый `--xr-mode on` решает это и потому сразу
входит в каноническую VR-команду. Детали: 
<https://docs.godotengine.org/en/stable/tutorials/xr/openxr_settings.html>.

Режим разрешает ранний `ClientModeResolver` до создания `Player`, мира и UI. После выбора режим
не меняется горячо: смена desktop <-> VR означает чистый restart, чтобы не оставлять старые camera,
viewport, input focus, audio listener и render resources. Настройки могут показывать команды
«Перезапустить в VR»/«Перезапустить в desktop»; на desktop exports это можно реализовать через
`OS.set_restart_on_exit(...)`, передав тот же набор engine/user args. Если storefront/OS плохо
поддерживает self-restart, используются две launch entries вокруг того же бинарника.

Поведение ошибок:

- explicit `vr`: показать в mirror window причину, команды retry / continue desktop / exit;
- `auto`: записать причину в лог и продолжить в desktop;
- explicit `desktop`: не пытаться инициализировать OpenXR и не запускать XR runtime;
- фактический режим после fallback хранить отдельно от requested mode, чтобы не объявлять
  `VRMode=1` и не создавать XR input source при неуспешной инициализации.

Отдельный артефакт нужен только при реальном техническом различии: standalone Android/Quest,
другой renderer/export template, несовместимые native dependencies, требования магазина или
существенно иной набор ресурсов. Даже тогда это должны быть разные export presets/пакеты одного
проекта, а не две ветки клиента.

## Целевая архитектура

Не следует делать один широкий `PlayerRig`, который одновременно знает про камеру, кнопки,
локомоцию, луч, UI и аватар. Такая граница быстро сломается при появлении hand tracking, второй
руки, teleport и дополнительных трекеров. Нужны небольшие независимые роли:

```text
XRBootstrap / ClientMode
  -> TrackingRig             позы головы, рук и трекеров + их validity
  -> PresenceRig             стабильные view/hand/aim/grip/tool/grab anchors
  -> PlayerActionSource      семантические действия и оси
  -> LocomotionController    движение CharacterBody3D и comfort options
  -> InteractionPointer(s)   дальний луч / позже near touch
  -> InteractionRouter       кому принадлежит hover/press/drag/scroll
  -> GrabInteractor(s)       захват предметов от left/right grab anchors
  -> ToolContext             aim pose и точка крепления активного инструмента
  -> PresencePoseSource      нейтральная пространственная поза пользователя
  -> UIHost                  desktop overlay или XR surfaces
```

Реализации desktop и XR подставляются только на краях:

| Контракт | Desktop | XR |
|---|---|---|
| `TrackingRig` | camera transform | HMD, controllers/hands, body trackers |
| `PresenceRig` | синтетические view/hand anchors | anchors из tracking poses с fallback при потере |
| `PlayerActionSource` | текущий `InputMap` | OpenXR action map с теми же semantic actions |
| `LocomotionController` | walk/fly/jump | smooth move, snap turn, teleport, recenter |
| `InteractionPointer` | camera ray | dominant/off-hand ray, позже direct touch |
| `GrabInteractor` | virtual hand near camera / keyboard action | left/right palm/grab volume + grip/pinch |
| `ToolContext` | camera aim + desktop hand anchor | hand aim + controller/hand anchor |
| `UIHost` | `CanvasLayer`/обычный viewport | tablet/pinned `SubViewport` surfaces |

`Player` остаётся владельцем `CharacterBody3D`, позиции, коллизий, респауна и lifecycle. Он
композирует перечисленные компоненты, но не читает мышь, XR-кнопки или `XRController3D` напрямую.
`XRBootstrap` выбирает режим один раз при старте и гарантирует desktop fallback при недоступном
runtime. Горячее переключение desktop/XR в первом релизе не требуется.

### Пространственный риг существует без аватара

Аватар — сменная визуализация пользователя, а не источник камеры, рук или взаимодействий. Между
сырым tracking и всеми игровыми системами нужен обязательный `PresenceRig`, который существует
даже при полностью статичном, нечеловекообразном или отсутствующем аватаре:

```text
Player / RemotePlayer
  -> PresenceRig
      -> root
      -> view
      -> left_hand
          -> grip / aim / palm / index_tip / tool / grab
      -> right_hand
          -> grip / aim / palm / index_tip / tool / grab
      -> optional body anchors: waist / chest / feet / knees / elbows
  -> AvatarHost                 optional visual consumer
  -> PresenceFallbackRenderer   visualizes anchors not consumed by avatar
```

Назначение anchors:

| Anchor | Кто использует |
|---|---|
| `view` | локальная камера/listener; у remote — направление взгляда и позиция voice emitter |
| `aim` | laser pointer, дальнее взаимодействие, ray-based tools |
| `grip` | pose контроллера и предметы, которые держат в руке |
| `palm` / `index_tip` | hand tracking, direct touch, pinch и жесты |
| `tool` | крепление визуала и рабочая pose карандаша/стилуса |
| `grab` | центр и ориентация виртуального захвата, physics query/constraint |

Для desktop эти точки синтетические: `view` совпадает с камерой, основная рука располагается у
камеры, `aim` повторяет camera ray. Для XR `view` идёт от HMD, руки — от controllers или hand
tracking. При краткой потере tracking `PresenceRig` применяет ограниченный fallback, но не меняет
контракт для tools/UI/grab.

Камера не должна искать голову или кость в аватаре. В XR `XRCamera3D` всегда следует HMD внутри
tracking space; в desktop `Camera3D` использует eye height игрока. Аватар может дать рекомендуемое
смещение/масштаб своего визуального root относительно `PresenceRig`, но не становится владельцем
камеры. Поэтому аватар без головы, летающий объект или абстрактная форма не ломают обзор.

`InteractionPointer`, `ToolContext`, планшет и grab system получают anchors только от
`PresenceRig`. Они никогда не читают кости аватара. Смена или асинхронная загрузка аватара не
должна сдвигать курсор, ронять предмет, переносить инструмент или менять tracking origin.

### Стыковка разных типов аватаров

Humanoid IK — только один из способов потребить `PresencePose`. Нужна лестница интеграции:

| Уровень | Интеграция аватара | Результат |
|---|---|---|
| None | аватар не знает про pose | модель живёт по своим параметрам; системные view/hand proxies остаются видимыми |
| Partial anchors | явная карта `view/left_hand/right_hand/...` на произвольные `Node3D` | двигаются только поддержанные части; это подходит и non-humanoid моделям |
| Custom pose | собственный applier читает нейтральный `PresencePose` | щупальца, крылья, механизмы и другие нестандартные тела сами интерпретируют tracking |
| Humanoid IK | humanoid bone map + IK/retargeting | голова, руки и тело следуют 3/6/full-body tracking |

Каждый pose applier должен сообщать `consumed anchors`, а не просто флаг «VR-compatible», причём
отдельно по render context: `FIRST_PERSON`, `MIRROR`, `REMOTE`. Например, текущий `LocalAvatar`
может корректно двигать руки для зеркала, но весь его слой скрыт из first-person camera — значит,
first-person proxies убирать нельзя. `PresenceFallbackRenderer` визуализирует всё, что осталось
непривязанным в текущем контексте:

- локально: нейтральные controller/hand proxies, laser и hit cursor; логический `view` не рисуется
  перед глазами, но доступен в debug visualization;
- удалённо: нейтральные руки и при необходимости небольшой view-direction marker рядом с
  абстрактным аватаром;
- при partial integration: fallback остаётся только для неприменённых рук/точек;
- пользовательская настройка может принудительно показывать interaction hands, даже если аватар
  заявил собственные, если они плохо читаются от первого лица.

Системные proxies должны быть лёгкими, нейтральными и отличаться по left/right. Они являются не
аварийной отладочной геометрией, а гарантированной частью VR UX: пользователь всегда понимает,
откуда идёт луч, где находится виртуальная кисть и чем будет выполнен grab.

### Маршрутизация действий

В VR один trigger потенциально означает нажатие UI, работу инструментом или действие с миром.
Приоритет должен быть явным:

```text
modal/system UI -> captured target -> hovered XR surface -> active tool -> world interactable
```

Получатель, принявший `press`, захватывает pointer до `release`; уход луча с поверхности не должен
случайно завершать действие на другом объекте. `InteractionRouter` также владеет hover enter/move/
exit, drag и scroll. Это устраняет текущую неявность, где `Player` отдельно вызывает
`hover_at`, `interact_at` и `scroll_by` разными лучами.

Для совместимости существующие объекты первое время подключаются адаптером к текущим методам
`interact_at(point)`, `hover_at(point)`, `scroll_by(dir)`. Новый контракт получает полный hit:
collider, world position, normal, локальную позицию поверхности, pointer id и timestamp. UV для
планшета вычисляется самой плоской XR-поверхностью из локальной точки, а не ожидается от physics
raycast.

## Что нужно развязать в коде

Текущий `Player` совмещает несколько ролей:

- физическое тело (`CharacterBody3D`);
- десктопную камеру `Camera3D`;
- мышиный look;
- луч взаимодействия `RayCast3D`;
- движение WASD/полёт;
- хаб ввода инструментов;
- источник параметров аватара.

Для VR это надо разложить на компоненты целевой архитектуры:

| Слой | Desktop | VR |
|---|---|---|
| Риг трекинга | desktop camera pose | `XROrigin3D`, `XRCamera3D`, `XRController3D`, hand/body trackers |
| Локомоция | WASD/мышь, текущий `CharacterBody3D` | thumbstick/snap turn/teleport + room-scale physical movement |
| Взаимодействие | один луч из камеры | луч/касание от руки, выбор dominant hand, дальний pointer |
| Инструменты | `ToolManager` под камерой, ЛКМ/ПКМ | `ToolManager` должен получать абстрактные события `primary/secondary` и pose руки |
| Аватар | параметры из тела и камеры | параметры + реальные transforms HMD/рук/трекеров |

Целевой вид: `Player` остаётся владельцем позиции в мире и жизненного цикла, а tracking, actions,
locomotion, interaction и tools получают узкие контракты. Это позволит запускать один и тот же мир
в desktop и VR без двух параллельных клиентов.

## Трекинг и уровни качества

Нужно явно поддержать несколько уровней, потому что у пользователей разные устройства.

| Уровень | Данные | Что делаем |
|---|---|---|
| Desktop | `pos`, `yaw`, `LookPitch`, velocity | текущее поведение |
| VR 3-point | HMD + left/right controller | голова и кисти точные; тело/локти/ноги решает IK |
| VR hand tracking | HMD + skeletal hands | кисти/пальцы точные; действия берём из жестов или fallback-кнопок |
| VR 6-point | HMD + hands + waist + feet | IK для корпуса и ног с хорошей устойчивостью |
| Full body | дополнительные knees/elbows/chest | меньше угадывания, больше прямого маппинга трекеров |

Внутреннее состояние нельзя сводить к одному enum. Нужны независимые значения:

- `TrackingStatus`: `INITIALIZING`, `ACTIVE`, `DEGRADED`, `LOST`;
- `BodyTrackingLevel`: `NONE`, `THREE_POINT`, `FOUR_POINT`, `FIVE_POINT`, `SIX_POINT`,
  `EXTENDED`;
- `TrackingCapabilities`: bitmask реальных точек/возможностей;
- `InputSourceLeft/Right`: `MOUSE_SYNTHETIC`, `CONTROLLER`, `HAND`, `EXTERNAL`, `LOST`.

`AvatarParams.TRACKING_TYPE` остаётся компактным **derived** представлением полноты body tracking
для аниматоров:

- `0` desktop;
- `1` VR / 3-point;
- `2` VR / 4-5-point partial body;
- `3` VR / 6-point (`view + hands + waist + feet`);
- `4` extended full body с дополнительными anchors/hints.

Нельзя смешивать полноту тела и способ ввода в одном enum: skeletal hands могут работать и с
3-point, и с full body. Поэтому дополнительно нужен bitmask `TrackingCapabilities`, например
`CONTROLLERS`, `SKELETAL_HANDS`, `WAIST`, `FEET`, `KNEES`, `ELBOWS`, `CHEST`, `EYE_GAZE`.
`AvatarParams.VR_MODE` становится `1` в любом XR-режиме. Эти значения нужны аниматорам для
переключения слоёв и позволяют добавлять новые сочетания устройств без разрастания enum.

Animator/applier обязан корректно выйти из любого tracking state: capabilities могут измениться
при инициализации, потере tracker, переходе controller <-> hands и смене avatar. Ни `TrackingType`,
ни наличие skeletal hands не выбирают input bindings напрямую.

## Формат и доставка сетевой позы

Production target — отдельный `PlayerMotionSnapshot`: root и presence anchors являются одним
coherent sample, но не попадают в `AvatarParameters`:

```gdscript
{
  &"version": 1,
  &"sequence": 1842,
  &"sample_time_ms": 123456,
  &"root_position": Vector3.ZERO,
  &"root_yaw": 0.0,
  &"tracking_status": 1,
  &"capabilities": 0b001111,
  &"points": {
    &"view": Transform3D,
    &"left_hand": Transform3D,
    &"right_hand": Transform3D,
    &"waist": Transform3D,
    &"left_foot": Transform3D,
    &"right_foot": Transform3D,
  },
  &"valid": PackedStringArray(["view", "left_hand", "right_hand", "waist"]),
}
```

Все points передаются в метрах в локальных координатах presence root. У каждой точки есть validity:
потерянный tracker нельзя молча продолжать считать актуальным. Fingers лучше вынести в отдельный
компактный optional-блок curl/splay или суставов после измерения трафика.

Текущий `_recv_state(pos, yaw, params)` сохраняется для desktop/старых peers. Для transition spike
можно временно вложить `_tracking_pose` в `params`, чтобы проверить Godot serialization без полной
смены RPC. Но production migration должна добавить версионированный `_recv_motion_v1(snapshot)` и
capability negotiation. Avatar parameter path остаётся change-driven/slower и не раздаёт pose
transforms всем applier'ам.

Локальная поза применяется каждый XR frame без сетевого ограничения. Сеть семплирует её отдельно,
а удалённая сторона держит небольшой pose buffer и интерполирует по `sequence/sample_time_ms`.
Root position и tracking points попадают в один motion sample, чтобы руки не отставали от тела.
`AvatarParameters`, voice и grabbed object state имеют отдельные logical streams и lifecycle.

Риски:

- `Transform3D` в словаре Godot RPC надо проверить на фактическую сериализацию через WebRTC
  data-channel; если появятся проблемы или лишний трафик, переводим в компактный словарь
  `origin: Vector3`, `basis: Basis` или квантизованные `pos + quat`.
- Частоту нельзя выбирать на глаз. Spike должен измерить packet size/jitter на 15/20/30 Гц и
  визуальную ошибку рук; после этого фиксируется rate и interpolation delay.
- Входящие данные недоверенные: обязательны лимит версии/числа points/размера hand data,
  проверка finite transforms, допустимой дистанции точки от root и отбрасывание старых sequence.
- При потере пакетов удалённая рука кратко экстраполируется с лимитом, затем плавно возвращается
  к IK/fallback pose; бесконечно держать последнюю позу нельзя.

## Presence pose, аватары и IK

Нужен нейтральный слой между tracking data, пространственными системами и конкретным аватаром:

```text
XR trackers
  -> PresencePoseSource
  -> PresencePose
      -> PresenceRig -> camera / pointers / tools / grab / fallback proxies
      -> Avatar pose adapter (optional)
          -> anchor mapping / custom applier / humanoid IK
```

Почему не писать transforms прямо в кости:

- у разных аватаров разные пропорции, bind pose и имена костей;
- 3-точечный VR требует синтеза локтей/плеч/таза/ног;
- full body и hand tracking должны использовать тот же интерфейс, но с меньшим количеством
  угадывания;
- удалённый аватар получает позу по сети с задержкой и должен интерполировать её иначе, чем
  локальное тело.

Минимальная реализация не должна требовать humanoid:

1. Ввести `PresencePose`: root, view, left/right hand anchors, optional body trackers и validity.
2. Создать `PresenceRig` и fallback proxies. Камера, pointers, tools и grab должны заработать уже
   на этом шаге с аватаром, который вообще не обрабатывает pose.
3. Добавить простой `AvatarAnchorApplier`: явное соответствие canonical anchor -> произвольный
   `Node3D`, без требования `Skeleton3D`.
4. Добавить custom pose contract для нестандартных аватаров.
5. Добавить `AvatarPoseApplier` для humanoid: bone map, retargeting и IK.
6. Для bundled pack иметь тестовые аватары четырёх классов: no integration, partial anchors,
   custom non-humanoid и humanoid IK. Автоматический humanoid mapping можно делать позже.

Локальное представление в VR состоит из двух независимых частей:

- first-person presence: avatar-provided hands либо системные hand/controller proxies; камера и
  interaction anchors существуют независимо от них;
- mirror avatar: текущий `LocalAvatar` решает задачу "вижу себя в зеркалах" и при наличии адаптера
  получает `PresencePose`; неприменённые anchors при необходимости видны отдельными proxies.

## Перемещение и room-scale

В XR есть два движения одновременно:

- физическое движение пользователя внутри tracking space;
- виртуальное движение по миру через контроллер.

Godot прямо предупреждает, что `XROrigin3D` представляет tracking space, а не тело игрока:
<https://docs.godotengine.org/en/stable/tutorials/xr/xr_room_scale.html>.

Для Knossos лучше идти через character-body-centric вариант:

- `Player`/`CharacterBody3D` остаётся виртуальным телом и сетевой позицией;
- `XROrigin3D` находится внутри него;
- HMD offset учитывается при расчёте головы, interaction rays и локального аватара;
- если пользователь физически вышел за допустимую зону, тело мягко подтягивается или показывается
  boundary/comfort warning;
- `XRServer.center_on_hmd(...)` используется для recenter по явной команде.

MVP locomotion:

- левый stick: движение относительно направления головы или левой руки, выбрать настройкой;
- правый stick: snap turn 30/45 градусов;
- отдельная команда recenter;
- teleport можно добавить как comfort mode, но не делать единственным способом, потому что
  Knossos уже устроен как прогулка по пространству.

## Взаимодействие с миром и инструментами

Существующий контракт объектов хороший: `interact_at(point)`, `hover_at(point)`, `scroll_by(dir)`.
Нужно заменить источник луча и само понятие "прицела":

- desktop: луч из камеры, как сейчас;
- VR: луч из dominant hand controller, контроллера или pinching hand;
- near interaction: позже, через `Area3D`/physics shape руки, но не для MVP.

Захват предметов должен идти отдельным `GrabInteractor` от `PresenceRig.grab`, а не от меша или
кости аватара. Визуальная кисть может отсутствовать или не совпадать с человеческой анатомией, но
виртуальный grab volume, выбранная рука, held transform и release velocity остаются определёнными.
Двуручный объект хранит два pointer/hand id. При смене аватара активный constraint не пересоздаётся;
при потере tracking применяется ограниченный fallback либо контролируемый release по правилам
конкретного объекта.

Для MVP нужен локальный test grabbable с контрактом `grab_begin/update/end`, чтобы проверить pose,
offset и release velocity. Сетевой захват — отдельная надстройка над тем же контрактом: до начала
движения клиент получает право управления объектом по существующей модели authority/ownership,
владелец транслирует transform, а release фиксирует финальное состояние. Нельзя передавать захват
как часть pose аватара: это состояние объекта и у него другой lifecycle и правила доверия.

В VR взгляд должен быть только направлением головы, а не основным указателем. Gaze-click плохо
масштабируется: утомляет шею, мешает просто смотреть на объект, конфликтует с чтением текста и
плохо работает, когда пользователь разговаривает или осматривается. Основной VR-контракт:

```text
XR hand/controller pose
  -> InteractionPointer
  -> hover_at / interact_at / scroll_by / drag
```

Нужен новый компонент `InteractionPointer`:

- источник pose: камера для desktop, dominant hand для VR;
- shape: дальний ray, позже near sphere/capsule для касания;
- состояние: `hovered`, `pressed`, `dragging`, `scrolling`;
- визуал: тонкий лазер/луч, точка попадания, состояние active/blocked;
- фильтры слоёв: панели/порталы/инструменты/служебный UI;
- fallback: если hands/controllers потеряны, временно можно включить gaze pointer.

Кнопки и жесты:

- controller mode: trigger = primary, grip/secondary button = secondary, stick/trackpad = scroll;
- hand tracking mode: pinch index/thumb = primary, stronger pinch или middle pinch = secondary;
- dominant hand выбирается в настройках, off-hand может держать планшет или инструменты;
- hover должен быть независим от primary, чтобы видео-панели и rich panels могли проявлять UI
  ещё до клика, как сейчас это делает `_dispatch_hover`.

Между raw controller/hand input и `PlayerActionSource` нужен per-hand `InputSourceArbiter`:

- controller и skeletal hand могут существовать одновременно;
- источник выбирается отдельно для каждой руки и semantic action, а не одним global mode;
- появление hand tracking не отключает hardware menu/trigger bindings;
- ручной override имеет приоритет над auto detection;
- смена source увеличивает `source_generation`: старый press не может завершиться release от
  нового устройства;
- menu gesture имеет hold/debounce и настраивается; hardware menu action всегда остаётся fallback;
- debug UI показывает выбранный source и причину arbitration.

`ToolManager` надо отвязать от мыши:

- вместо ЛКМ/ПКМ он должен получать абстрактные `primary_pressed/released`,
  `secondary_pressed`, `scroll`, `pose`;
- `PlayerTool.make_held_node()` должен уметь крепиться не только под камеру, но и под узел руки;
- drawing tool в VR должен рисовать из кончика руки/стилуса, а не из screen ray;
- image placement и bubble tool могут остаться ray-based.

## UI и настройки

Экран настроек, чат, консоль и системные оверлеи сейчас рассчитаны на 2D overlay. В VR нельзя
просто рисовать это поверх глаз игрока:

- overlay на HMD ломает глубину и фокус;
- он перекрывает мир независимо от позы головы;
- мелкий текст тяжело читать из-за vergence/accommodation;
- клики становятся неочевидными: пользователь не понимает, чем именно он "жмёт" UI.

Базовая модель для VR: основные функции desktop UI доступны на VR-планшете, но UI не должен быть
жёстко привязан именно к планшету.

```text
UI state/controllers
  -> UI presentation (`Control` tree)
  -> UIHost
      -> DesktopUIHost (`CanvasLayer` / root viewport)
      -> XRSurfaceHost (`SubViewport` -> `ViewportTexture` -> mesh)
          -> Tablet3D / pinned panel / VR keyboard
```

Планшет не должен быть отдельной копией бизнес-логики настроек. На первом этапе можно переносить
один и тот же `Control` tree между desktop host и tablet host. Если одна панель должна одновременно
существовать в mirror window и VR, состояние/команды выносятся из сцены, а presentation создаётся
дважды. Один `Control` нельзя одновременно держать в двух viewport.

Текущий desktop layout не надо механически уменьшать на текстуру. Для VR сохраняются те же models,
commands и по возможности общие widgets, но layout обязан поддерживать крупные hit targets,
читаемую плотность, scroll и ограниченный размер поверхности. Особенно надо отдельно проверить
плотный экран настроек, чат, file picker, clipboard и системные диалоги.

### VR-планшет

Поведение:

- планшет можно вызвать системным действием, например кнопкой menu на off-hand;
- по умолчанию он закреплён у недоминантной руки, как физический clipboard/tablet;
- альтернативный режим: закрепить планшет в мире перед пользователем, чтобы работать двумя руками;
- планшет не должен быть head-locked, кроме аварийного fallback для устройств без рук/контроллеров;
- размер, дистанция и DPI должны быть стабильными, чтобы текст был читаемым;
- при открытии планшета pointer dominant hand автоматически начинает попадать в его UI.
- tablet surface захватывает pointer между press/release и не пропускает то же действие в мир;
- при потере tracking планшет остаётся доступен через временный head-follow fallback и gaze/confirm.

Какие UI переносить первыми:

- настройки;
- чат: история + ввод;
- список пользователей/статус сети;
- space console;
- диалоги выбора/подтверждения, насколько они применимы в VR.

Ввод текста:

- MVP: фокус в поле планшета + ввод с физической клавиатуры mirror window;
- следующий шаг: VR keyboard как отдельная панель рядом с планшетом;
- voice dictation можно рассмотреть позже, но не как обязательную зависимость.
- нативные `FileDialog`, clipboard и открытие внешних приложений в MVP явно уходят в mirror window
  с понятным состоянием ожидания на планшете; позже им нужны отдельные VR-потоки.

Технический шов:

- сделать `VRTablet` как 3D-обёртку вокруг `SubViewport`;
- добавить общий `XRSurfaceHost` и `ViewportPointerBridge`: local hit на известной плоскости -> UV
  -> viewport coordinates -> `InputEventMouseMotion/Button`; поддержать wheel, drag, focus и
  pointer capture, а не только одиночный click;
- вычислять hit/UV в локальных координатах surface и добавить large-world precision test, чтобы
  laser/tablet не дрожали далеко от world origin;
- desktop overlay остаётся существующим путём;
- UI-команды/состояние не должны знать, запущены они в overlay или на XR surface.

Минимальная последовательность:

- spike/MVP boot: оставить desktop overlay на mirror window и не считать это полноценным VR UX;
- первый полноценный VR UX: планшет через `SubViewport` на плоскости в мире;
- ввод текста: сначала системная клавиатура/desktop fallback, позже VR keyboard;
- настройки VR: режим поворота, locomotion direction, dominant hand, hand/controller mode,
  recenter, comfort vignette, avatar body visibility, tablet attachment mode.

## Производительность

VR меняет бюджет:

- целевой framerate 90 Гц и выше, v-sync окна надо отключать при XR, как рекомендует Godot;
- physics ticks стоит поднять выше 60 для XR-сборки или режима;
- постпроцесс и зеркала критичны: зеркала с локальным аватаром могут стать дорогими в стерео;
- генерация/стриминг мира не должны стопорить главный поток, иначе в HMD это сразу заметно.

Отдельный фронт работ: профиль `xr` в настройках качества: ограничение зеркал, дальности,
стриминга ресурсов, видео-плееров и количества remote avatars с full-body позой. Нужны метрики,
а не только субъективная проверка: CPU/GPU frame time, dropped/reprojected frames, размер и частота
pose packets, interpolation error, время потери/восстановления tracker.

Целевые бюджеты уточняются на этапе 0 под выбранный HMD/runtime. Базовый acceptance: стабильная
частота устройства в типовом пространстве без постоянной reprojection; отсутствие заметных spike
при появлении UI, аватара, зеркала и сетевого пира.

До production внешних аватаров нужны системные ограничения, а не только XR quality preset:
download/uncompressed size, textures/materials/meshes/bones/animations, bounds, lights/particles/
audio и runtime update cost. Avatar проходит staged load/validation до reveal; при loading/error/
budget/safety block `PresenceRig`, fallback proxies, nameplate и voice продолжают работать. Нужны
per-user hide/show и emergency safe mode, доступный одной командой и в desktop, и в VR. Подробная
мотивация: [vrchat-hybrid-lessons.md](vrchat-hybrid-lessons.md#12-performance-и-safety-нельзя-добавлять-после-появления-user-avatars).

## Тестируемость без HMD

Разработка не должна останавливаться без подключённого шлема. Контракты выше позволяют сделать
`SimulatedTrackingRig` и `SimulatedActionSource`, управляемые мышью/клавиатурой или тестовым
скриптом. Они должны уметь:

- выдавать view/hands/body points и переключать validity;
- симулировать dominant/off-hand pointer, pinch/trigger, scroll и drag;
- переключать controller/hand sources независимо по рукам во время удерживаемого action;
- воспроизводить записанный pose trace;
- добавлять latency, jitter, packet loss и пропажу tracker;
- показывать debug overlay: tracking points, body root, rays, target/capture, packet rate.
- переключать аватары между no integration, partial, custom non-humanoid и humanoid, не меняя
  pose trace и состояние виртуальных рук.
- запускать pointer/tablet test на больших world coordinates.

Unit/integration tests покрывают action routing, pointer capture, pose validation/serialization,
tracking fallback и desktop regression. Реальный HMD всё равно обязателен на acceptance каждого
XR-этапа: симулятор не проверяет stereo comfort, ergonomics, tracking runtime и frame pacing.

## План работ

### Этап 0. Spike: OpenXR boot

Цель: доказать, что проект стабильно запускается в HMD.

- Зафиксировать support matrix первой версии: PCVR runtime, один основной HMD/controller profile,
  второй профиль для smoke test; standalone вынести за отдельный gate.
- Ввести `ClientMode.DESKTOP/VR/AUTO`, ранний `ClientModeResolver` и тесты приоритета CLI ->
  desktop.
- Включить/задокументировать OpenXR project settings, action map и XR shaders.
- Добавить минимальную `XRRig`-сцену: `XROrigin3D`, `XRCamera3D`, left/right `XRController3D`.
- Поддержать канонические engine/user args и restart actions; подготовить две launch entries одного
  PC executable.
- Проверить desktop fallback: если OpenXR не инициализирован, приложение работает как сейчас.
- Снять baseline CPU/GPU frame time и проверить tracking poses/actions на реальном устройстве.

Критерий готовности: можно открыть текущий мир в HMD, смотреть вокруг и видеть debug controller
poses; mode/fallback детерминированы; записаны baseline и известные ограничения runtime.

### Этап 1. Развязка Player от конкретного ввода

Цель: подготовить код к двум ригам.

- Ввести `TrackingRig`, `PresencePose`, `PresenceRig`, `InputSourceArbiter`, `PlayerActionSource`,
  `LocomotionController`, `InteractionPointer`, `InteractionRouter` и `ToolContext` как отдельные
  контракты.
- Сделать desktop implementations поверх текущей камеры и `InputMap`, не меняя bindings.
- Создать синтетические desktop view/hand/aim/grip/tool/grab anchors и debug renderer.
- Перевести `_try_interact`, `_dispatch_hover`, `_do_scroll` на `InteractionRouter` с legacy adapter.
- Перевести `ToolManager`/`PlayerTool` с `Camera3D` и mouse capture на `ToolContext` и semantic
  actions; точка крепления held node приходит из контекста.
- Добавить `SimulatedTrackingRig` и тесты press/capture/release, hover и приоритетов router.
- Добавить тест controller <-> hand transition во время hover/press без ghost release.
- Сохранить поведение desktop тестами.

Критерий готовности: desktop работает без изменений поведения; `Player` и tools не читают
конкретные mouse/XR nodes или кости аватара; interaction tests проходят без сцены HMD.

### Этап 2. VR locomotion и interaction MVP

Цель: в VR можно ходить по миру и нажимать порталы/панели.

- Подключить XR-реализации `TrackingRig` и `PlayerActionSource`.
- Наполнить `PresenceRig` из HMD/controllers и включить системные hand/controller proxies.
- Добавить OpenXR action bindings минимум для одного controller profile, с semantic actions,
  общими с desktop.
- Реализовать stick movement, snap turn, recenter.
- Реализовать dominant-hand `InteractionPointer`: ray, hover, cursor hit point, press/release,
  capture, drag и scroll; off-hand оставить готовой ко второму pointer.
- Пробросить primary/secondary в инструменты.
- Реализовать `GrabInteractor` от left/right grab anchors и локальный test grabbable; сетевое
  ownership оставить отдельным следующим срезом.
- Добавить настройки VR input.
- Проверить room-scale root correction, collision и корректный сетевой root при физическом шаге.

Критерий готовности: пользователь в HMD ходит по HTML-пространству, активирует порталы, берёт и
отпускает тестовый объект, видит других и слышит голос; взгляд не активирует объекты; потеря
controller имеет безопасный fallback; смена на аватар без головы/рук/скелета не влияет на камеру,
указатель, захват и инструменты.

### Этап 3. VR-планшет для desktop UI

Цель: в VR можно пользоваться настройками, чатом и служебным UI без head-locked overlay.

- Сделать общий `XRSurfaceHost`, затем `VRTablet` как mesh + `SubViewport` + `ViewportTexture`.
- Подключить настройки/чат через общий state/commands; адаптировать layout и hit targets для VR.
- Сделать `ViewportPointerBridge`: local hit -> UV -> motion/button/wheel/drag/focus events.
- Добавить режимы крепления: off-hand, pinned in world, аварийный head-follow fallback.
- Реализовать базовый ввод текста через физическую клавиатуру/mirror window.
- Явно обработать native file picker/clipboard/external links через mirror-window fallback.
- Добавить настройки dominant hand и tablet attachment.

Критерий готовности: пользователь в HMD открывает планшет, меняет настройки, читает/пишет чат
и закрывает UI, не выходя из VR.

### Этап 4. PresencePoseSource и сетевой контракт VR-позы

Цель: начать передавать view и руки.

- Расширить `AvatarParams`: оживить derived `VRMode`/`TrackingType` для animator compatibility.
- Добавить `TrackingStatus`, `BodyTrackingLevel`, `TrackingCapabilities` и отдельный
  `PlayerMotionSnapshot(root, presence_pose)`.
- Добавить `PresencePoseSource` для desktop, simulated и XR.
- Проверить временную упаковку `_tracking_pose` в legacy `params`, затем добавить production
  `_recv_motion_v1` и peer capability negotiation; motion и avatar parameters имеют разные rates.
- Добавить validation/budgets, sequence/time, validity, remote pose buffer и fallback.
- Проверить RPC-сериализацию и сравнить 15/20/30 Гц по трафику и визуальной ошибке.
- Обновить `docs/client/avatars.md` и `docs/network/multiplayer.md` по факту выбранного формата.

Критерий готовности: удалённый `PresenceRig` получает view/hands независимо от типа и готовности
аватара; при no integration удалённый клиент видит стабильные fallback hand/view markers.

### Этап 5. Стыковка аватаров и humanoid IK

Цель: разные классы аватаров используют столько tracking anchors, сколько умеют, без влияния на
базовую spatial presence.

- Сделать `AvatarAnchorApplier` для произвольных `Node3D` и контракт `consumed anchors` по
  `FIRST_PERSON`/`MIRROR`/`REMOTE`.
- Сделать custom `PresencePose` applier для non-humanoid аватаров.
- Сделать `AvatarPoseApplier` и bone map resource для humanoid skeleton.
- Реализовать 3-point IK: head, hands, shoulders/elbows, approximate torso.
- Реализовать правила совместной видимости avatar hands и fallback proxies без дублей.
- Реализовать first-person hands и mirror body без закрытия HMD; view anchor никогда не рендерится
  поверх локальной камеры.
- Разделить local render path (XR frame) и remote buffered path; один applier принимает оба.
- Прогнать матрицу no integration / partial / custom non-humanoid / humanoid.

Критерий готовности: humanoid двигает головой и руками, non-humanoid использует явные/custom
anchors, а no-integration аватар сохраняет полноценные hand proxies и все взаимодействия; старые
desktop-аватары продолжают работать через существующие applier'ы.

### Этап 6. Hand tracking и жесты

Цель: кисти и пальцы перестают быть просто контроллерами.

- Подключить `XRHandModifier3D` для bundled hand skeleton.
- Ввести версионированный `_hands` как отдельный optional-блок, не обязательный для всех клиентов.
- Ввести gesture state machine с hysteresis/debounce для pinch press/release; отдельный жест для
  scroll/drag выбирать только после тестов ложных срабатываний.
- Подключить per-hand `InputSourceArbiter`: hands не отключают hardware bindings, controller и hand
  могут сосуществовать, ручной override выше auto detection.
- Добавить деградацию: если hand tracking пропал, вернуться к controller pose без ghost actions.

Критерий готовности: пользователь с hand tracking видит свои пальцы, а базовые действия мира
работают без физических кнопок.

### Этап 7. Full body trackers

Цель: использовать дополнительные трекеры без смены архитектуры.

- Добавить сбор ролей `waist`, `chest`, `feet`, `knees`, `elbows`.
- Поднять `TrackingType` в зависимости от реально доступных точек.
- Расширить `PresencePose` и humanoid/custom applier: waist/feet anchors, knees/elbows hints.
- Добавить `TrackingCalibrationProfile`: user height, floor/playspace, device roles/serials, offsets,
  recenter; профиль не зависит от аватара.
- Добавить `AvatarFitProfile`: visual scale/alignment, proportions, solver lock policy и seated
  overrides; кэшируется по avatar id/version.
- Добавить UI диагностики трекеров.
- Добавить outlier rejection, tracker health и versioned migration calibration solver.

Критерий готовности: при наличии waist+feet ноги и корпус следуют трекерам; при пропаже трекера
система деградирует до 3-point/6-point без развала аватара.

### Этап 8. VR UX и production quality

Цель: VR-режим становится не демо, а полноценным способом пользоваться Knossos.

- Доработка world-space settings/chat/console поверх планшетной основы.
- Довести сетевой grab: authority/ownership, reconnect, simultaneous/two-hand conflict и release.
- Comfort settings: vignette, turn mode, movement speed, seated/standing.
- XR quality profile и профили mirror/video/remote avatars.
- Avatar budgets, staged load, fallback reasons, per-user hide/show и emergency safe mode.
- Автотесты контрактов pose snapshot, fallback и десктопной совместимости.
- Документация сборки под VR/OpenXR runtime.
- Acceptance на втором HMD/controller profile, длительная сессия и тест смешанной комнаты
  desktop + 3-point VR + full body.

Критерий готовности: VR проходит отдельный release checklist по comfort, доступности функций,
frame pacing, disconnect/reconnect и desktop/VR interoperability.

### Этап 9. Standalone gate

Цель: принять отдельное продуктовое решение по Android/Quest, не выдавая PCVR-поддержку за
готовность standalone.

- Проверить Godot Android OpenXR export, permissions, signing и store/runtime требования.
- Провести аудит нативных библиотек, WebRTC/voice/media, файловых операций и deep links.
- Сделать mobile XR quality profile и измерить типовое пространство на целевом устройстве.
- Спроектировать VR-native file/image selection вместо desktop dialog fallback.

Критерий готовности: есть измеренный scope standalone-релиза и решение go/no-go; при go он получает
собственный roadmap и performance budgets.

## Ближайшие следующие шаги

Это первый исполнимый цикл работ. Он не требует заранее выбрать IK или сетевой rate и заканчивается
демонстрацией на HMD, после которой можно уверенно оценивать дальнейшие этапы.

1. **Зафиксировать среду проверки.** Записать основной HMD, controller profile, OpenXR runtime,
   ОС/GPU и второй комплект для smoke test. Без этого нельзя корректно закрыть этап 0.
2. **Сделать короткие ADR.** Зафиксировать PCVR-first, один PC-бинарник, выбор режима только при
   старте, разделение tracking/actions/locomotion/interaction/UI и production motion envelope;
   `_tracking_pose` внутри legacy params допускается только как serialization spike.
3. **Client mode и OpenXR boot spike.** Добавить `ClientModeResolver`, XR bootstrap, минимальную
   tracking scene, action map, канонические `--xr-mode ... -- --client-mode=...`, явный fallback и
   debug-визуализацию view/hands в mirror window.
4. **Снять baseline.** Открыть существующее типовое пространство, записать frame time, ошибки
   runtime, controller poses/actions, поведение зеркал/видео и desktop fallback.
5. **Добавить characterization tests desktop.** До рефакторинга зафиксировать main action,
   hover, interact, scroll, tool priority, mouse capture и движение.
6. **Ввести spatial presence.** Реализовать `PresencePose`/`PresenceRig`, синтетические desktop
   view/hand/aim/grip/tool/grab anchors и debug/fallback renderer. Проверить это с пустым и
   нескелетным аватаром.
7. **Ввести input arbitration.** Реализовать per-hand `InputSourceArbiter`, stable source
   generation и тесты controller/hand transition во время press; hardware menu action не зависит
   от hand tracking detection.
8. **Ввести interaction contracts первым небольшим срезом.** Реализовать
   `InteractionPointer`/`InteractionRouter` и legacy adapter поверх `PresenceRig.aim`, оставив
   источником позы текущую камеру. Это проверит архитектуру без HMD.
9. **Развязать tools.** Ввести `ToolContext`, перенести held anchor/aim pose на
   `PresenceRig.tool/aim` и semantic actions; прогнать drawing/image/bubble на desktop.
10. **Подключить XR presence, pointer, grab и locomotion.** Наполнить anchors из HMD/controllers;
   затем trigger + ray + portal/rich panel, локальный test grabbable, smooth move, snap turn и
   recenter. Провести VR usability check с humanoid и абстрактным аватаром.
11. **Сделать tablet proof of concept.** Одна простая `Control`-сцена с button, slider, scroll,
   text field и drag проходит через `XRSurfaceHost`/`ViewportPointerBridge`; только после этого
   переносить реальные settings/chat. Повторить тест далеко от world origin.
12. **Закрыть vertical slice.** В HMD с аватаром без VR-интеграции открыть пространство, пройти
    портал, прокрутить панель, применить инструмент, взять тестовый объект, открыть планшет и
    изменить настройку. Камера, обе виртуальные руки, pointers и активный grab остаются на месте
    при смене/перезагрузке аватара; desktop smoke test остаётся зелёным.

После шага 4 проводится первый gate: если текущий renderer/зеркала не держат frame budget, до
рефакторинга аватара заводится XR quality profile. После шага 11 проводится второй gate: если
текущие settings слишком плотные для планшета, сначала отделяются state/commands и делается
адаптивный layout, а не наращивается input bridge.

Артефакты первого цикла: `ClientModeResolver`, две launch entries одного PC executable, рабочая XR
bootstrap scene, action map, support matrix, baseline report, контракты interaction/tools,
simulator/debug overlay, desktop regression tests и запись vertical slice. После него отдельно
декомпозируются этапы 4-5: pose protocol spike и 3-point IK.

## Что важно не делать раньше времени

- Не создавать отдельный VR network stack. В существующем transport появляется versioned motion
  envelope с собственным rate; avatar params, voice и object state остаются отдельными потоками.
- Не завязывать аватар напрямую на `XRController3D`. Аватар должен получать нейтральную позу,
  иначе desktop/remote/replay/fullbody быстро разойдутся.
- Не брать camera, pointer, tool или grab transforms из костей аватара. Они принадлежат
  `PresenceRig`; аватар только визуально потребляет часть anchors.
- Не скрывать системные hand proxies только потому, что аватар помечен как VR-compatible. Скрывать
  можно лишь конкретные anchors, которые applier действительно потребил и корректно визуализирует.
- Не начинать с full body. Сначала надо стабилизировать 3-point, потому что это базовый случай
  для большинства VR-устройств и fallback для всех остальных.
- Не делать VR-only инструменты. Инструменты должны жить на абстрактных действиях и pose-источнике,
  иначе каждый новый инструмент придётся писать дважды.
- Не делать head-locked UI как основной VR-интерфейс. Он годится только как emergency fallback;
  штатный UI должен жить в мире на планшете/панели и управляться рукой.
- Не оставлять gaze-click основным взаимодействием. Взгляд нужен для обзора, а указатель и действие
  должны идти от руки/контроллера.

## Открытые решения

- Основной HMD/runtime/controller profile для acceptance и второй профиль для smoke test.
- Формат transforms в `PlayerMotionSnapshot`: Godot `Transform3D` как есть или компактная
  сериализация.
- Частота отправки VR-позы и размер interpolation buffer по результатам тестов 15/20/30 Гц.
- IK: писать минимальный свой solver на GDScript или брать готовый Godot XR Tools/IK-компонент.
- Hand tracking input: какие жесты считаются primary/secondary и как избежать ложных срабатываний.
- UI-планшет: off-hand по умолчанию или pinned-world по умолчанию.
- Нужен ли UI одновременно в mirror window и планшете; если да, какие сцены первыми требуют
  отдельного state/controller от presentation.
- Внешний вид fallback hand/controller proxies и remote view-direction marker; когда пользователь
  принудительно оставляет interaction proxies поверх avatar-provided hands.
- Видимость локального avatar body от первого лица: только avatar hands, руки+торс или настройка;
  системные interaction proxies управляются отдельно.
- Поддержка seated mode: отдельная калибровка высоты и `AvatarParams.SEATED`.
