# Уроки hybrid desktop/VR-архитектуры VRChat

> Статус: архитектурное исследование на июль 2026. Это анализ публичной документации VRChat,
> creator docs, release notes и публичных bug reports. Внутренняя реализация клиента VRChat
> закрыта, поэтому предположения о внутренних границах ниже явно помечены как выводы, а не факты.

## Зачем это изучать

VRChat много лет поддерживает один социальный мир одновременно для desktop, PCVR, standalone VR,
controller tracking, hand tracking, 3-point и full-body tracking, humanoid и generic avatars. Это
почти тот же класс задачи, который появляется у Knossos. Особенно полезны не отдельные UI-паттерны,
а места, где исторически сцепились avatar, tracking, input, network и presentation.

Главный вывод для Knossos: **режим клиента, источник ввода, пространственная pose и визуальный
аватар — четыре независимых измерения**. Их нельзя сворачивать в один `VRMode`, один
`TrackingType` или один `PlayerRig`.

## Краткая карта решений

| Область | Что видно у VRChat | Что закладываем в Knossos |
|---|---|---|
| Запуск | один PC-клиент, `--no-vr` принудительно включает desktop | один PC executable, явные `desktop/vr/auto` launch modes |
| Input | desktop, controllers и hands имеют разные bindings и UI-жесты | semantic actions + per-hand source arbitration + context routing |
| Spatial pose | humanoid IK тесно связан с типом rig | `PresenceRig` существует независимо от аватара |
| Generic avatars | поддерживаются, но tracking может игнорироваться | pose никогда не выключается из-за типа аватара |
| Viewpoint | avatar descriptor хранит отдельную view position | системный `view` обязателен; avatar alignment только рекомендует offset |
| UI | Quick/Main/Action menus работают в world space, VR выбирает рукой | `UIHost` + XR surfaces + pointer capture, без head-locked основного UI |
| Hand tracking | жесты конкурируют с системными меню и controller input | жест не имеет права молча отключить hardware action |
| IK/FBT | отдельная calibration, measurement и lock policies | физическая calibration отдельно от avatar fit/solver policy |
| Networking | IK, playable parameters и speech имеют разные sync semantics | motion pose, avatar parameters и voice — разные логические потоки |
| Safety/perf | ranks, blocking, fallback avatars и impostors | fallback presence всегда доступен; avatar budgets и safe mode до public avatars |

## 1. Один клиент, несколько режимов запуска

VRChat распространяет PC-клиент, который может работать с HMD или как desktop application;
официальный `--no-vr` принудительно включает desktop mode. Способ передачи launch options зависит
от launcher: Steam поддерживает их напрямую, Oculus PC требует shortcut, Quest их не поддерживает:
<https://docs.vrchat.com/docs/launch-options>.

Это подтверждает выбранную для Knossos схему одного PC executable и нескольких launch entries.
Отдельный standalone artifact нужен из-за платформы, а не из-за другого gameplay client.

### Что улучшить относительно этого подхода

- Иметь симметричные explicit modes `desktop` и `vr`, а не только отрицательный `--no-vr`.
- Различать `requested_mode` и `actual_mode`: VR initialization может завершиться fallback.
- Разрешать режим до создания мира, camera, input и UI; не делать hot switch.
- Без args запускать desktop, чтобы не будить OpenXR/SteamVR без намерения пользователя.
- Сразу иметь диагностический `auto`, но не делать его default до runtime-тестов.

## 2. Не путать client mode, tracking level и input modality

VRChat даёт аватарам встроенные `VRMode` и `TrackingType`. Документация предупреждает, что
`TrackingType` меняется во время инициализации и при отключении tracking points; animator не должен
попадать в состояния без выхода. Значение `1` означает generic rig, для которого tracking может
существовать у пользователя, но игнорироваться аватаром. Значения `0/1/2` в VR могут быть
переходными, а рабочие body modes начинаются с 3-point:
<https://creators.vrchat.com/avatars/animator-parameters/>.

Проблема такой модели не в самих параметрах, а в соблазне использовать один enum сразу для:

- готовности tracking;
- количества точек;
- типа avatar rig;
- controller versus skeletal hands;
- выбора input bindings.

### Решение Knossos

Хранить независимо:

```text
ClientMode              DESKTOP / VR
TrackingStatus          INITIALIZING / ACTIVE / DEGRADED / LOST
BodyTrackingLevel       NONE / THREE_POINT / FOUR_POINT / FIVE_POINT / SIX_POINT / EXTENDED
TrackingCapabilities    HEAD, HANDS, FINGERS, HIP, FEET, KNEES, ELBOWS, CHEST...
InputSourceLeft/Right   MOUSE_SYNTHETIC / CONTROLLER / HAND / EXTERNAL / LOST
AvatarConsumption       consumed anchors per FIRST_PERSON / MIRROR / REMOTE
```

`VRMode` и совместимый числовой `TrackingType` можно продолжать публиковать в avatar parameter
bus, но они являются derived view, а не источником решений клиента. State machines обязаны иметь
переход из любого состояния при изменении capabilities.

## 3. Generic/non-humanoid avatars показывают опасность avatar-driven tracking

VRChat официально поддерживает Generic avatars и рекомендует их для существ, сильно отличающихся
от человека. У generic avatar меньше humanoid-specific playable layers, а анимацию автор строит
самостоятельно: <https://creators.vrchat.com/avatars/> и
<https://creators.vrchat.com/avatars/rig-requirements/>.

Но публичная документация fallback system прямо говорит: если исходный avatar generic, а fallback
humanoid, fallback не получает IK, потому что pose information отсутствует. Публичный bug report
также описывает generic avatars, у которых remote tracking API не возвращает положение головы,
хотя у пользователя есть camera/tracking pose:
<https://docs.vrchat.com/docs/avatar-fallback-system>,
<https://feedback.vrchat.com/udon/p/some-avatars-have-no-head-tracking-data>.

Это самый важный антипример для Knossos: оптимизация «аватар не humanoid — значит pose не нужна»
ломает fallback visualization, world logic, voice origin и accessibility.

### Решение Knossos

- `PresencePose` производится и передаётся независимо от `avatar_uri` и rig type.
- `PresenceRig.view/hands/aim/grip/tool/grab` существует даже без `AvatarHost`.
- Avatar adapter потребляет произвольное подмножество anchors.
- Fallback renderer использует ту же pose, поэтому смена generic -> fallback не теряет руки.
- World API, voice emitter и user selection получают presence anchors, а не avatar bones.
- Нельзя снижать сетевой pose payload только потому, что текущий avatar её не визуализирует:
  получатель может скрыть, заменить или ещё не загрузить этот avatar.

## 4. Viewpoint надо отделить от head bone, но ограничить avatar offsets

VRChat Avatar Descriptor хранит view position отдельно от rig. Creator docs предлагают поставить
её между глазами, а если у аватара нет головы — в любое уместное место. Там же отмечено, что
необычно большая голова и неудачная view position могут поднимать ноги при движении головы:
<https://creators.vrchat.com/avatars/creating-your-first-avatar/#view-position>.

Это решает non-humanoid camera, но создаёт связь camera calibration с avatar proportions. В
публичных reports встречаются off-center viewpoint, расхождения при unusual proportions и запросы
на сильные offsets; VRChat ограничивает экстремальное удаление view от avatar:
<https://feedback.vrchat.com/bug-reports/p/view-point-position-is-off-center>,
<https://feedback.vrchat.com/sdk-bug-reports/p/trying-to-get-view-position-behind-model>.

### Решение Knossos

- `PresenceRig.view` принадлежит HMD/desktop camera и никогда не вычисляется из head bone.
- Avatar profile может задать **bounded visual alignment**: куда поместить visual root относительно
  view/root, но не переносит саму XR camera.
- Alignment валидируется по finite/range и имеет reset.
- Voice, pointer и grab продолжают использовать canonical presence anchors.
- В debug mode одновременно показываются raw HMD, canonical view и avatar alignment target.

## 5. IK 2.0 показывает, что calibration — самостоятельный продуктовый слой

VRChat IK 2.0 добавил больше tracking points, сохранение calibration, выбор измерения по arm span
или height и lock policies `Lock Hip`, `Lock Head`, `Lock Both`. Эти policies сознательно выбирают,
какое ограничение нарушить при несовместимых пропорциях. Есть отдельный locomotion toggle для FBT:
<https://docs.vrchat.com/docs/ik-20-features-and-options>.

FBT guide перечисляет реальные источники нестабильности:

- неверный user height и playspace offset;
- резкие изгибы spine/rest pose;
- несовместимые proportions;
- tracker binding к неправильной части тела;
- rig hacks, которые ломаются после обновления solver;
- необходимость повторной calibration и визуальных tracker spheres.

Источник: <https://docs.vrchat.com/docs/full-body-tracking>.

### Решение Knossos: два слоя calibration

1. `TrackingCalibrationProfile` — физический пользователь и устройства:
   tracker roles/serials, controller offsets, floor, user height, handedness, playspace origin.
2. `AvatarFitProfile` — конкретный avatar adapter:
   visual scale/alignment, body proportions, solver lock policy, anchor offsets, seated overrides.

Первый слой можно переиспользовать после смены аватара. Второй кэшируется по устойчивому avatar id
и версии adapter. Смена avatar не должна заставлять заново определять tracker roles.

Дополнительно нужны:

- outlier rejection по расстоянию от predicted anchor;
- health/validity на каждую точку;
- плавная деградация full body -> 6/3-point;
- явная политика disconnect: краткий hold/extrapolation, затем controlled fallback, а не вечная
  заморозка;
- solver policies вместо скрытых «исправлений» rig;
- calibration scene с raw и solved markers;
- versioned calibration migration при изменении solver.

## 6. Scaling затрагивает больше, чем mesh

VRChat avatar scaling синхронизирует eye height и предоставляет параметры `ScaleFactor`,
`EyeHeightAsMeters` и другие. Worlds могут ограничивать scaling; экстремальные значения официально
не поддерживаются: <https://docs.vrchat.com/docs/adjusting-your-avatars-height> и
<https://docs.vrchat.com/docs/osc-avatar-scaling>.

История запросов показывает типичную ошибку: масштабировать avatar root/viewpoint, но забыть IPD,
controller reach и IK, из-за чего визуальное тело и реальные input poses расходятся:
<https://feedback.vrchat.com/avatar-30/p/feedback-add-support-for-scaling-the-avatar-including-view-position-and-ipd>.

### Решение Knossos

Различать:

- `avatar_visual_scale` — только visual representation/retargeting;
- `presence_scale` — редкий системный режим, который согласованно меняет world perception,
  locomotion, reach, near interaction, audio distances, clips, UI и network representation.

Не менять `XRServer.world_scale` как побочный эффект смены аватара. Любой presence scaling требует
отдельного design review и тестов comfort/IPD; в MVP avatar scale не меняет физическую reach.

## 7. UI и pointers: hand identity должна быть явной

VRChat разделяет Quick Menu, Main Menu и radial Action Menu. В VR меню работают с controller/hand
interaction, а desktop при открытии Quick Menu переводит mouse в screen-space UI mode. Action Menu
имеет разные способы выбора (`Flick` и trigger-confirm), может открываться на любой руке и имеет
отдельное desktop управление:
<https://docs.vrchat.com/docs/action-menu>,
<https://docs.vrchat.com/docs/vrchat-202141>.

Hand tracking добавил wrist/palm openers и pinch interaction. Причиной дополнительных opener modes
стал конфликт исходного жеста с dashboard gesture некоторых VR streaming apps:
<https://docs.vrchat.com/docs/vrchat-202441>.

Публичные reports показывают характерные ошибки:

- trigger/grip неожиданно переключает active menu hand, иногда на невидимый pointer;
- hand tracking detection отключает controller menu button или оставляет laser привязанным к
  пальцу после возврата controllers;
- gesture lock блокирует одной руке UI interaction;
- открытый Quick Menu влияет на turning, даже когда laser не наведён на menu;
- фиксированное положение menu неудобно для части accessibility-сценариев.

Источники:
<https://feedback.vrchat.com/bug-reports/p/oddly-switching-of-quick-menu-operating-hand>,
<https://feedback.vrchat.com/open-beta/p/1530-vrc-beta-controller-menu-button-useless-when-using-hand-tracking>,
<https://feedback.vrchat.com/bug-reports/p/1480-unable-to-switch-between-using-controllers-and-hand-tracking-forced-to-use>,
<https://feedback.vrchat.com/bug-reports/p/hand-tracking-bug-cannot-interact-with-menu-with-left-hand-if-hand-gestures-are>,
<https://feedback.vrchat.com/open-beta/p/1381-turning-is-less-responsive-when-qm-is-open>.

### Решение Knossos

- У каждого pointer постоянный `pointer_id` и `hand`; нет скрытой глобальной «активной руки».
- Hover не переключает dominant hand. Только explicit setting/action меняет preference.
- Target, принявший press, удерживает capture до release той же руки и того же source generation.
- `InputSourceArbiter` работает отдельно для каждой руки и каждого semantic action.
- Обнаружение skeletal hands не отключает controller actions. Controller и hand могут сосуществовать;
  arbitration учитывает activity/confidence и ручной override.
- Menu gesture настраивается, имеет hold/debounce и никогда не является единственным способом
  открыть UI; hardware menu action остаётся fallback.
- UI context блокирует только потреблённые actions. Открытый tablet не должен менять turning,
  пока stick/action не захвачен UI.
- Tablet имеет off-hand, pinned-world и accessible head-follow placement; recenter доступен всегда.
- Pointer/debug visualization показывает hand, source, hovered target и captured target.

## 8. World-space precision — отдельный VR-риск

Публичный VRChat report описывает сильный jitter UI pointer далеко от world origin, включая
tablet/main menu: <https://feedback.vrchat.com/bug-reports/p/pointer-jitter-when-far-from-spawn>.
Это типичный эффект float precision, особенно заметный у тонкого laser и близкого UI.

### Решение Knossos

- XR tracking и hand anchors хранятся в локальном пространстве `PresenceRig`/`XROrigin3D`.
- Пересечение tablet plane и перевод в UV выполняются в local surface coordinates.
- Не строить laser как длинный mesh в абсолютных global coordinates; origin/direction обновлять из
  локальной pose и ограничивать длину.
- Добавить precision test на больших координатах мира до tablet MVP.
- Если пространства допускают километровые offsets, предусмотреть floating origin/world rebasing,
  не меняющий logical network coordinates.

## 9. First-person avatar требует отдельного render context

VRChat автоматически скрывает head bone локального avatar, чтобы голова не перекрывала обзор.
Компонент Head Chop позволяет автору отдельно управлять first-person visibility костей; изменения
не влияют на mirrors и remote users:
<https://creators.vrchat.com/avatars/avatar-components/vrc-headchop/>.

Это подтверждает наш контракт `consumed anchors` по контекстам `FIRST_PERSON/MIRROR/REMOTE`, но
копировать bone-scale hack не обязательно.

### Решение Knossos

- Visibility задаётся render layers/material/mesh policy, а не изменением pose source.
- Avatar adapter отдельно сообщает first-person-safe visuals.
- Head/near-camera geometry имеет bounded hide/fade policy.
- Системные interaction proxies не исчезают только потому, что руки видны в mirror.
- Camera collision и near clip тестируются на giant/small/headless avatars.

## 10. Pose, animation parameters и voice должны иметь разные sync semantics

VRChat разделяет sync semantics built-in parameters: `IK` обновляется примерно 10 раз/с и
интерполируется, `Playable` меняется медленнее, `Speech` может вычисляться локально из audio, а
`None` не синхронизируется. Custom synced parameters ограничены 256 bits; trigger parameters не
рекомендуются из-за desync:
<https://creators.vrchat.com/avatars/animator-parameters/>.

Документация Animator Tracking Control также явно отличает Networked IK от animation-controlled
parts: <https://creators.vrchat.com/avatars/state-behaviors/#animator-tracking-control>.

Из этого можно обоснованно вывести, что high-frequency body pose нельзя считать обычным набором
avatar animator parameters.

### Решение Knossos

Логически и в production wire format разделить:

```text
PlayerMotionSnapshot   root + PresencePose + sequence/time/validity   unreliable, frequent
AvatarParameters       gestures/modes/toggles/animation state         change-driven/slower
Voice                  encoded audio; local RMS drives Voice param     independent stream
Identity               nick/avatar URI/capabilities                    reliable
ObjectState            grab ownership/transforms                       own lifecycle
```

Временная упаковка `_tracking_pose` внутрь старого `_recv_state(..., params)` допустима только для
serialization spike и backward-compatible prototype. Production target — отдельный motion envelope,
чтобы:

- avatar parameter appliers не получали большие transforms;
- independently выбирать rate/compression/LOD;
- root и anchors оставались одним coherent sample;
- generic/hidden/loading avatar не влиял на pose delivery;
- записывать/replay motion отдельно от avatar settings;
- не заставлять animation changes конкурировать с motion bandwidth.

## 11. Tracking targets должны оставаться доступны custom avatars

VRChat позволяет animator state отключать tracking для части тела и отдавать её animation. Но
публичный feature request отмечает ограничение: после отключения tracking avatar creator не имеет
удобного доступа к исходной IK target для additive recoil, sword motion или custom constraints:
<https://feedback.vrchat.com/feature-requests/p/make-it-possible-to-reference-ik-targets-for-avatars>.

### Решение Knossos

- `PresencePose` immutable input текущего frame.
- Avatar adapter пишет только в solved/output pose и не мутирует canonical anchors.
- Custom adapter получает raw/canonical target и может добавить visual offset.
- Tools/grab используют canonical или отдельный gameplay offset, а не visual hand bone.
- Debug показывает raw -> canonical -> solved -> rendered transforms.

Так recoil может быть визуальным, gameplay aim — стабильным, а custom non-humanoid solver не
лишает систему исходных tracking data.

## 12. Performance и safety нельзя добавлять после появления user avatars

VRChat пришлось построить Performance Ranks, per-user filtering, fallback avatars, impostors и
Safety system. Avatar может быть заменён из-за platform mismatch, file size, performance, loading,
error или safety block:
<https://creators.vrchat.com/avatars/avatar-performance-ranking-system/>,
<https://docs.vrchat.com/docs/avatar-fallback-system>,
<https://creators.vrchat.com/avatars/avatar-impostors/>,
<https://docs.vrchat.com/docs/vrchat-safety-and-trust-system>.

Для Knossos это ещё важнее из-за внешних `.tscn`: кроме frame time существует риск выполнения
недоверенного script/GDExtension API, уже отмеченный в [avatars.md](avatars.md).

### Решение Knossos

До публичного каталога/remote avatars нужны:

- immutable `PresenceRig`, nameplate и voice, которые переживают block/loading/error;
- гарантированный system fallback avatar/proxies;
- hard budgets: download/uncompressed size, textures, materials, meshes, bones, animations,
  particles/lights/audio, update cost и bounds;
- staged load: parse/validate -> budget -> instantiate в ограниченном environment -> reveal;
- per-user hide/show и quality override;
- emergency safe mode одним действием в desktop и VR;
- avatar LOD/update throttling по distance/visibility/room load;
- диагностическая причина fallback, а не безымянная капсула;
- запрет avatar code влиять на camera, `PresenceRig`, network authority или system UI.

Static performance rank полезен как heuristic, но не заменяет runtime CPU/GPU/memory telemetry:
сама документация VRChat предупреждает, что static rank не видит все shaders/animator costs.

## 13. Debug UI — часть архитектуры, не вспомогательный overlay

VRChat имеет tracking/IK settings, calibration spheres и Action Menu debug view с animator
parameters/tracking states. Для сложной комбинации avatar + tracking + input + network это
необходимость, а не creator luxury:
<https://docs.vrchat.com/docs/action-menu>,
<https://docs.vrchat.com/docs/full-body-tracking>.

Knossos XR diagnostics должны показывать:

- requested/actual client mode и OpenXR runtime/session state;
- raw devices, roles, validity, confidence и last update;
- per-hand selected input source и причины arbitration;
- canonical `PresenceRig` anchors;
- pointer hover/capture/action context;
- raw/canonical/solved/rendered pose;
- avatar consumed anchors по render context;
- fallback reason;
- calibration profile/version;
- pose packet rate/bytes/jitter/loss/interpolation delay;
- CPU/GPU frame time и avatar cost.

Diagnostics должны работать в mirror window, VR tablet и записываться в compact support dump.

## Изменения, которые надо внести в наш фундамент сейчас

### P0 — до первого XR interaction vertical slice

1. `ClientModeResolver` с requested/actual mode.
2. `PresencePose` и avatar-independent `PresenceRig`.
3. Per-hand `InputSourceArbiter`; controller и hands могут быть активны одновременно.
4. `InteractionRouter` с stable pointer id и capture.
5. Render contexts `FIRST_PERSON/MIRROR/REMOTE` и fallback proxies.
6. XR diagnostics/debug renderer.
7. Characterization test с generic/headless/no-integration avatar.
8. Large-coordinate pointer/tablet precision test.

### P1 — до сетевой VR-позы

1. Отдельный `PlayerMotionSnapshot`, не зависящий от avatar parameters.
2. Validity/status/capabilities вместо одного tracking enum.
3. Pose validation, rate/compression experiment и interpolation buffer.
4. Generic/hidden/loading avatar получает тот же remote presence pose.
5. Voice emitter следует `PresenceRig.view`, не head bone.

### P2 — до humanoid FBT

1. `TrackingCalibrationProfile` отдельно от `AvatarFitProfile`.
2. Solver lock policies и degradation matrix.
3. Versioned calibration migration и device-role diagnostics.
4. Test avatars: none/partial/custom generic/humanoid with bad proportions.
5. Tracker disconnect/outlier/reconnect traces.

### P3 — до внешних avatar URLs в VR production

1. Avatar load sandbox и hard budgets.
2. Fallback reasons, per-user hide/show и emergency safe mode.
3. Runtime avatar telemetry и adaptive quality.
4. Проверка, что block/unload avatar не уничтожает presence, voice, held tools или grab state.

## Что сознательно не копируем у VRChat

- Не кодируем тип avatar rig внутри tracking level.
- Не прекращаем network pose для generic avatar.
- Не делаем avatar viewpoint владельцем XR camera.
- Не используем глобальную неявную active hand для UI.
- Не позволяем hand detection отключать hardware bindings.
- Не смешиваем body pose с custom animator parameter budget.
- Не привязываем physical tracker calibration к конкретному avatar.
- Не скрываем first-person proxies по одному общему «VR-compatible» флагу.
- Не ждём появления performance incidents, прежде чем ввести avatar budgets/fallback.

## Источники и степень уверенности

Высокая уверенность: официальные VRChat user/creator docs по launch options, controls, animator
parameters, Generic avatars, viewpoint, FBT/IK, Head Chop, performance, safety и fallbacks.

Средняя уверенность: выводы о внутренних границах sync и input routing. Они основаны на публичных
контрактах и наблюдаемом поведении, но не на исходном коде VRChat.

Публичные Canny reports используются как примеры failure modes. Они не доказывают текущую
реализацию или наличие бага в последнем build, но хорошо показывают классы ошибок, которые должны
попасть в наши regression tests.
