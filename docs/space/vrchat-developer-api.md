# Возможности VRChat для разработчиков: обзор и выводы для VRWeb

> **Проверено:** 17 июля 2026 года по официальной документации VRChat. Под «API мира» ниже
> понимается SDK Worlds и Udon, а не внутреннее HTTP API сервиса.

## Короткий ответ

VRChat даёт автору мира существенно больше, чем изменение Unity-сцены и синхронизацию
переменных. Мир может читать положение и позу игроков, менять локальную locomotion, телепортировать
локального игрока, управлять слышимостью голосов и avatar audio, масштабом аватара, камерой,
интеракциями, UI, физикой, видео и загружаемым контентом. Есть постоянное хранилище на аккаунте,
автоматические per-player объекты, AI Navigation, PhysBones/Contacts, MIDI, OSC и Creator Economy.

Главное архитектурное ограничение: **Udon исполняется отдельно на каждом клиенте и не получает
произвольной власти над удалённым игроком**. Большинство mutating-операций `VRCPlayerApi` работает
только для `Networking.LocalPlayer`. Чтобы переместить другого игрока, нужно сетевым событием
попросить его клиент выполнить `TeleportTo` над собой. Это модель distributed client authority,
а не серверная игровая симуляция.

## Слои API

| Слой | Что даёт | Чего не даёт |
|---|---|---|
| Unity + allowlisted components | Готовая сцена, Transform, Animator, physics, audio, UI, particles, NavMesh и безопасное подмножество компонентов | Произвольные MonoBehaviour и библиотеки в опубликованном мире |
| Udon / UdonSharp | События Unity/VRChat, логика по кадрам, работа с объектами и разрешённым подмножеством C#/Unity API | Полный .NET, reflection, произвольный доступ к ОС и сети |
| World networking | Synced variables, network events, ownership, object transform/physics sync, object pools, network statistics | Единый авторитетный серверный game loop и произвольное создание сетевых prefab в runtime |
| Player API | Чтение игроков, позы, tracking/bones, velocity; локальные locomotion/teleport/scale/haptics; настройка слышимости других игроков | Прямое принудительное управление удалённым клиентом, микрофоном или самим аватарным Animator другого игрока |
| Persistence | `PlayerData` и `PlayerObject`, сохранённые между заходами | Общемировую БД, запись данных чужого аккаунта, обмен persistence между мирами |
| Remote content | Загрузка строк/JSON, изображений и видео по URL | Общий `fetch`, произвольные HTTP headers/methods, WebSocket или backend socket из Udon |
| Avatar SDK | Animator layers, expression parameters/menu, PhysBones, Contacts, Constraints, Raycast | Udon/произвольный C# внутри аватара |
| External integration | OSC для avatar parameters, input, trackers, eye tracking и scaling; MIDI input/playback | Общий стабильный публичный REST API VRChat |

## Игроки: что можно читать

Через [`VRCPlayerApi`](https://creators.vrchat.com/worlds/udon/players/) мир получает список
игроков и события join/leave, локального игрока, instance owner/master, display name, player ID,
VR/desktop, VRC+, suspended state и владение объектами. Это identity только внутри текущего
инстанса; логин пользователя и чувствительные account-поля миру не выдаются.

Для каждого игрока можно читать:

- world position, rotation и velocity;
- положение и rotation humanoid bones;
- tracking data головы, рук и origin;
- grounded state, avatar eye height и события смены аватара/масштаба;
- held pickup для локального игрока;
- network simulation time и сетевую статистику;
- пересечения capsule игрока с trigger, collider и particles;
- события respawn, suspend/resume, смены языка и input method;
- положение, rotation и velocity пользовательского drone.

Это позволяет делать nameplates, зоны, мини-игры, hit detection, IK-зависимые эффекты,
персональные UI и компенсацию сетевой задержки. Положение костей — наблюдение за уже
отрендеренной позой, а не возможность переписать скелет чужого аватара.

## Игроки: что можно менять

### Позиция и движение

[`TeleportTo`](https://creators.vrchat.com/worlds/udon/players/player-positions/) меняет position
и rotation **только локального игрока**. Есть флаг, должен ли удалённый рендер плавно
интерполировать скачок. Station может запретить teleport. Для другого участника паттерн такой:

1. отправить targeted/broadcast network event с намерением и координатами;
2. на его клиенте проверить отправителя и правила мира;
3. вызвать `Networking.LocalPlayer.TeleportTo(...)`.

`SetVelocity` задаёт скорость локального игрока. Отдельный
[`Player Forces API`](https://creators.vrchat.com/worlds/udon/players/player-forces/) задаёт walk,
run и strafe speed, jump impulse, gravity strength и `Immobilize`. Поэтому в Udon можно делать
launch pads, zero gravity, slowdown, checkpoint respawn и vehicles/stations. Но прямого
`SetPosition(remotePlayer)` с авторитетным исполнением нет.

### Аватар, руки и ощущения

Мир может для локального игрока:

- ограничить или запретить ручное avatar scaling и установить eye height;
- включить/выключить pickups;
- посадить игрока в Station;
- вызвать haptic pulse в левой или правой руке;
- управлять пользовательским drone (`TeleportTo`, `SetVelocity`);
- через camera settings/dolly ограниченно влиять на screen/handheld camera.

Мир не может заменить произвольному удалённому игроку аватар или напрямую управлять его
Animator. Avatar pedestal позволяет самому пользователю переключиться на заданный avatar.

### Голос и звук аватара

[`Player Audio API`](https://creators.vrchat.com/worlds/udon/players/player-audio/) локально
настраивает, как текущий клиент слышит конкретного игрока: gain, near/far distance, volumetric
radius и low-pass для voice; аналогичные ограничения gain/radius/spatialization для звуков
аватара. Это позволяет делать комнаты, рации, сцены и локальный mute. Мир не читает PCM
микрофона, не включает микрофон за пользователя и не меняет то, что слышат остальные клиенты,
без выполнения той же логики у них.

## Сцена, объекты и взаимодействия

Udon видит GameObject/Transform и безопасное подмножество Unity API: lifecycle и physics events,
Animator, Rigidbody, Collider, raycasts, materials, shaders, RenderTexture, audio, particles,
lights, Unity UI и TextMesh Pro. [`UI Events`](https://creators.vrchat.com/worlds/udon/ui-events/)
и `VRC_UIShape` дают world-space UI; input events абстрагируют jump/use/grab/drop/move/look и
переназначенные контроллеры.

Готовые [VRChat scene components](https://creators.vrchat.com/worlds/components/) включают:

- pickup и interactable objects;
- stations/seats;
- mirrors, portals и avatar pedestals;
- spatial audio;
- camera dolly;
- PhysBones, Contacts и Constraints в мирах;
- `VRC_ObjectSync` для transform и Rigidbody;
- `VRC_ObjectPool` для синхронизированного включения заранее подготовленных объектов.

[`VRCTween`](https://creators.vrchat.com/worlds/udon/vrctween/) анимирует transforms, paths, UI,
renderers, lights и audio. [`VRCGraphics`](https://creators.vrchat.com/worlds/udon/vrc-graphics/)
даёт Blit, GPU instancing, shader globals, async GPU readback и ограниченные camera/quality
settings. [`AI Navigation`](https://creators.vrchat.com/worlds/udon/ai-navigation/) поддерживает
NavMesh agents, runtime baking, dynamic obstacles и off-mesh links.

Сетевые runtime-объекты обычно не создаются из произвольного prefab. Для late join и стабильных
network IDs VRChat предлагает заранее упакованный object pool; его owner активирует/возвращает
объекты, а active state синхронизируется. Локальный `Instantiate` существует, но сам по себе не
создаёт канонический сетевой объект.

## Сеть

Базовая модель подробно сравнена с нашей в
[`replicated-state.md`](../network/replicated-state.md):

- `UdonSynced` fields — snapshot state для late joiners, manual или continuous sync;
- parameterized network events — одноразовые вызовы текущим адресатам;
- у каждого сетевого GameObject один owner, только он публикует synced fields;
- ownership можно передать, при уходе owner он переназначается;
- `VRC_ObjectSync` отдельно синхронизирует transform и Rigidbody;
- доступны sender identity (`NetworkCalling.CallingPlayer`), congestion/simulation time и
  per-object/per-player network statistics.

Security не возникает автоматически: клиент автора события недоверенный, `master` нельзя
считать ролью доступа, а получатель/owner должен валидировать намерение. Современный
`[NetworkCallable]` явно отмечает сетевые методы и может задавать rate limit.

## Данные и сохранение между заходами

[`PlayerData`](https://creators.vrchat.com/worlds/udon/persistence/player-data/) — типизированный
key-value store на игрока и мир. Локальный игрок может писать только собственные данные; читать
можно данные игроков текущего инстанса после `OnPlayerRestored`. Поддерживаются числа, bool,
string, byte arrays, vectors, quaternion и colors.

[`PlayerObject`](https://creators.vrchat.com/worlds/udon/persistence/player-object/) автоматически
создаёт принадлежащую игроку копию шаблона с неизменяемым ownership. Его synced variables могут
быть persistent. Это удобная модель для health/inventory/tool/collider/nameplate без постоянной
передачи ownership.

VRChat хранит на своих серверах на один аккаунт в одном мире до 100 KB compressed PlayerData и
отдельно 100 KB PlayerObject data. Данные доступны во всех инстансах и на всех устройствах, но
не шарятся между разными мирами и не образуют общую серверную таблицу лидеров. Для глобальной
БД всё равно нужен внешний backend, с которым Udon может общаться лишь через ограниченные
каналы загрузки.

Для runtime-структур есть DataList/DataDictionary/DataToken и VRCJSON. Контейнеры полезны
локально и для JSON, но не являются автоматически реплицируемой произвольной объектной БД.

## Интернет, медиа и устройства

Udon не получает универсальный web API, но имеет специализированные каналы:

- [`String Loading`](https://creators.vrchat.com/worlds/udon/string-loading/) загружает text/JSON;
- [`Image Loading`](https://creators.vrchat.com/worlds/udon/image-loading/) загружает texture до
  2048×2048 с явным управлением памятью;
- [`Video Players`](https://creators.vrchat.com/worlds/udon/video-players/) проигрывают обычное
  видео и streams через Unity/AVPro;
- URL ограничены allowlist, если пользователь не включил untrusted URLs;
- Udon не получает общий `fetch`, POST/PUT, cookies, WebSocket и произвольное сетевое соединение.

[`MIDI`](https://creators.vrchat.com/worlds/udon/midi/) даёт note on/off и control change от
локального инструмента либо синхронного MIDI playback. Отдельный
[`OSC API`](https://docs.vrchat.com/docs/osc-overview) соединяет внешний процесс/устройство с
клиентом VRChat: avatar parameters и scaling, virtual input controller, body trackers и eye
tracking. OSC — интеграция с клиентом пользователя, а не API Udon для обращения к интернету.

## Аватары — отдельный programmable layer

Avatar SDK не запускает Udon. Поведение задаётся декларативной системой:

- Unity Animator в playable layers Base/Additive/Gesture/Action/FX;
- built-in и custom expression parameters (`bool`, 8-bit `int`, quantized `float`);
- Expressions Menu, Parameter Driver и OSC как источники параметров;
- PhysBones для secondary motion и grabbing;
- Contacts для avatar↔avatar/world/item сигналов;
- Constraints, avatar Raycast и first-person Head Chop.

Синхронизируется до 256 бит custom expression parameters; всего разрешено до 8192 custom
parameters с учётом unsynced. Это узкая avatar/animator шина, а не общий scripting API мира.
Подробнее о различии avatar parameters и world state — в
[`replicated-state.md`](../network/replicated-state.md).

## Creator Economy

Для допущенных продавцов есть
[`Store` API в Udon](https://creators.vrchat.com/economy/sdk/udon-documentation/): проверить
владение продуктом у игрока, получить owners в инстансе, открыть store/listing, получить события
покупки/истечения и отправить server-checked product event. Это позволяет открывать предметы,
зоны или способности на основе покупки. Платёжные данные и самостоятельное проведение платежа
Udon не получает.

## Внешнее HTTP API VRChat — отдельная и нестабильная область

У VRChat есть backend endpoints для account/social/world/avatar/group/invite/favorites и upload,
которыми пользуются клиент и сайт. Но VRChat прямо пишет, что **не документирует их как публичный
API**, может менять без уведомления и не поддерживает сторонние приложения. Community
documentation существует, но является unofficial. Creator Guidelines также запрещают сторонним
приложениям загружать worlds/avatars за пользователя. Поэтому это нельзя считать платформенным
контрактом, сравнимым с Udon или будущим API VRWeb. Официальная позиция:
[`API Usage / Bots`](https://hello.vrchat.com/creator-guidelines#api-usage-bots).

## Что особенно полезно перенять в VRWeb

У нас уже есть scene handles, локальный `document.player.set("position", ...)`, capability contract и
типизированный Replicated State. Наиболее ценные следующие слои:

1. **Полный local-player capability**, а не только position: rotation/velocity, locomotion
   profile, gravity/jump, immobilize, haptics, avatar scale и tracking reads. Все mutators должны
   оставаться локальными; remote action — проверяемая команда целевому клиенту.
2. **Player-scoped objects** с гарантированным owner. Это лучше для inventory/health/tools,
   чем постоянная передача ownership общих scene objects.
3. **Account-scoped page persistence** с ясной границей: self-write, bounded typed values,
   событие restored и отсутствие скрытой общемировой БД.
4. **Раздельные content loaders** или один fetch capability с явными media/type/size/rate
   policy. VRChat показывает пользу runtime JSON/images/video, но allowlist-only модель для Web
   слишком закрыта; у нас это должно быть пользовательской политикой capability.
5. **Player audio routing**: per-listener gain/range/spatial rules дают гораздо больше, чем
   единый voice volume, и естественно ложатся на наш voice layer.
6. **Interactions beyond click**: pickup/grab/use/drop, triggers/collisions, stations,
   haptics, contacts и tracking-aware input.
7. **Network observability**: authority time у нас уже есть; стоит также экспонировать bounded
   RTT/simulation delay/congestion для адаптивной частоты, но не сырые transport internals.
8. **Доменное разделение**: avatar stream, scene state, transient events, persistence, media и
   commerce должны иметь разные контракты, даже если делят codecs/transport снизу.

Не стоит переносить зависимость от instance master как авторизацию, невозможность нормального
backend request API и неявную client-authority без sender validation. Для открытого VRWeb также
нужна специфицированная серверная интеграция, которой у Udon фактически нет.

## Основные официальные источники

- [Udon overview and API sections](https://creators.vrchat.com/worlds/udon/)
- [Player API](https://creators.vrchat.com/worlds/udon/players/)
- [Networking](https://creators.vrchat.com/worlds/udon/networking/)
- [Persistence](https://creators.vrchat.com/worlds/udon/persistence/)
- [Scene Components](https://creators.vrchat.com/worlds/components/)
- [Avatar Components](https://creators.vrchat.com/avatars/avatar-components/)
- [Animator Parameters](https://creators.vrchat.com/avatars/animator-parameters/)
- [OSC API](https://docs.vrchat.com/docs/osc-overview)
- [Creator Guidelines: API Usage / Bots](https://hello.vrchat.com/creator-guidelines#api-usage-bots)

