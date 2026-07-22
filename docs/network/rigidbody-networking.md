# Сетевые Rigidbody-объекты

> **Статус на 2026-07-21:** профиль реализован в Knossos: binding-aware `SAMPLE`, стандартная
> physics-схема, `document.physics`, dynamic/proxy adapter, атомарный handoff и интеграция с
> `VRWebGrabbable`. Публичная внешняя демка находится в
> [`addons/vrweb_tools/examples/networked_rigidbody.html`](../../addons/vrweb_tools/examples/networked_rigidbody.html), руководство
> автора — в [networked-rigidbody.md](../space/networked-rigidbody.md). Физический объект остаётся
> обычным VRWML-тегом `<RigidBody3D>`; отдельный заменяющий тег не вводится.

Связанные документы: [Subject Bindings](subject-bindings.md),
[Replicated State](replicated-state.md), [grabbable](../space/grabbable.md).

## Что дали Subject Bindings

Для физического объекта теперь можно выразить именованные назначения без отдельной сущности
ownership:

- `controller` — пользователь, чьи действия принимает объект;
- `simulator` — пир, который вычисляет каноническую физику;
- `holder` — пользователь, который держит grabbable-предмет;
- `driver` — пользователь, управляющий транспортом.

Назначение можно менять атомарно вместе с каноническим state, проверять через
`assigned(slot)`, освобождать при disconnect и принудительно перехватывать по policy. Это
закрывает гонки захвата управления и проверку полномочий. Binding отвечает только на вопрос
«кто назначен» и не является транспортом transform, скоростей или импульсов.

## Реализованные слои

| Возможность | Реализация |
|---|---|
| Назначение simulator | Обычный `bindings.simulator`, меняемый reducer-транзакцией |
| Каноническое состояние и late join | Reliable `DELTA`/`SNAPSHOT` и периодические keyframes |
| Частый поток позы и скоростей | Binding-aware `SAMPLE` с `{assigned="simulator"}` |
| Доставка движения | `unreliable_ordered`; samples не меняют revision и не входят в snapshot |
| Удалённое отображение | Frozen proxy, interpolation buffer и короткая экстраполяция |
| Физическая роль клиента | Только simulator запускает обычное dynamic-тело |
| Передача симуляции | Одна транзакция меняет simulator, epoch, pose, скорости и tick |
| Disconnect | После reconnect grace authority забирает симуляцию через тот же handoff |
| Публичный контракт автора | `document.physics.bind` принимает handle обычного `<RigidBody3D>` |

`VRWebGrabbable` с одним прямым дочерним `RigidBody3D` использует тот же record: grab атомарно
меняет holder и simulator, release оставляет simulator бросившему, а свободное тело продолжает
публиковать physics samples.

### Почему не следует делать демо на `document.state`

Сторонняя страница технически может читать `transform`, `linear_velocity` и
`angular_velocity`, складывать их в state и применять на других клиентах. Такой прототип не
является качественным продуктовым путём:

1. каждый sample проходит requester → authority → reliable delta;
2. текущий Knossos применяет к этому пути локальный лимит 30 команд/с; это не норма VRWeb,
   но делает обходной путь непригодным для референсной демки этого клиента;
3. нет physics-tick callback, timestamped snapshot buffer и стандартной интерполяции;
4. несколько тел быстро создают очередь из уже устаревших reliable состояний;
5. page script должен сам решать freeze/proxy, teleport thresholds, sleep и смену simulator;
6. разные страницы реализуют несовместимые wire-схемы и по-разному ведут себя при lag.

Такое демо выглядело бы рабочим на localhost для одного тела, но не задавало бы переносимый и
надёжный API для внешних разработчиков.

## Реализованный минимальный контракт

Нужен сетевой профиль для обычного `<RigidBody3D>`. Он может переиспользовать Store,
PolicyEvaluator и bindings, но не заменяет Godot-тег новым классом и не должен заставлять
авторов вручную строить физический netcode. Opt-in можно выразить переносимым scripting API,
например `document.physics.bind("#ball", definition)`, где `#ball` адресует декларативный
`RigidBody3D`.

### Каноническое состояние

Одна reliable revision объекта содержит:

```text
bindings.simulator
pose                  [px, py, pz, qx, qy, qz, qw]
linear_velocity       [x, y, z]
angular_velocity      [x, y, z]
sleeping               bool
simulation_epoch       int
tick                   int
```

Reliable state фиксируется при создании, sleep/wake, teleport, grab/release, передаче
simulator и периодическом keyframe. Он нужен late joiner и recovery, но не каждому кадру.

### Частые samples

- Отправитель обязан быть назначен в `bindings.simulator`; identity берётся из транспорта.
- Sample содержит object id, state revision, simulation epoch, tick, pose и обе скорости.
- Доставка — `unreliable_ordered`; автор выбирает частоту, а конкретный клиент вправе
  фильтровать или пропускать поток по своей локальной policy.
- Получатель отбрасывает старую epoch/revision/tick и хранит небольшой interpolation buffer.
- Sample не меняет canonical revision и не входит в snapshot.
- Authority валидирует claim/handoff и keyframe; частый поток можно принимать напрямую от
  simulator только после проверки transport principal против канонического binding.

### Роли клиентов

- `simulator` запускает обычную динамику и публикует samples;
- остальные клиенты не симулируют это тело как независимый dynamic rigidbody, а отображают
  proxy с интерполяцией и ограниченной экстраполяцией;
- gameplay-значимые столкновения и импульсы вычисляет simulator;
- запросы `apply_impulse`, `teleport`, `wake` идут как проверяемые команды, а не как
  произвольные state patches.

### Handoff и восстановление

Передача управления должна одной reliable транзакцией зафиксировать последний pose/velocity,
увеличить `simulation_epoch` и назначить нового `simulator`. Новый пир начинает симуляцию из
этого keyframe; старые samples прежней epoch перестают быть применимыми. При disconnect
authority выбирает successor по policy или временно становится simulator сам. Если ни один
кандидат не готов, объект засыпает в последнем каноническом состоянии.

### Interaction-driven handoff

Lock одного simulator на весь срок жизни объекта не является обязательной моделью. Для
интерактивных тел право симуляции должно следовать за причинной локальной интеракцией:

- пока пользователь держит объект, `holder`, `controller` и обычно `simulator` указывают на
  него; он видит прямую локальную симуляцию, а не интерполированный proxy;
- при броске этот пользователь остаётся simulator хотя бы на время свободного полёта, поэтому
  исходный импульс и ближайшие столкновения считаются относительно его клиента;
- когда другой пользователь успешно хватает объект, одна каноническая транзакция назначает
  ему `holder`/`controller`/`simulator`, увеличивает `simulation_epoch` и завершает поток
  предыдущего simulator;
- новый simulator начинает из согласованной позы захвата; samples старой epoch после этого
  игнорируются всеми клиентами.

Захват можно показывать новому пользователю локально-оптимистично до ответа authority, чтобы
не добавлять round-trip к ощущению руки. Authority всё равно сериализует конкурентные claims.
При отказе клиент откатывает локальный захват к каноническому proxy; при принятии его локальная
симуляция становится источником новой epoch. Короткое пересечение работы старого и нового
simulator допустимо на транспорте, но не создаёт двух канонов благодаря проверке epoch и
binding отправителя.

Передавать simulator на каждое случайное столкновение нельзя: это создаст ping-pong между
пирами. Отдельный Rigidbody-specific язык handoff policy для этого не нужен: автор мира
описывает переход обычными командами и reducers того же subject, а access rules определяют,
кто вправе их вызвать. Reducer может учитывать `holder`/`controller`, cooldown, lease, порог
импульса или явный claim; environmental collision сам по себе обычно не меняет simulator.

### `bindings.simulator` как API передачи

`simulator` — обычный Subject Binding с зарезервированной доменной семантикой. Скрипт не
получает небезопасный локальный setter binding: он отправляет команду, authority проверяет её
access rule и исполняет детерминированный reducer. Reducer возвращает binding patch вместе с
физическим handoff-state одной транзакцией:

```lua
claim_simulation = {
  write_rule = "anyone",
  reducer = function(event)
    if not can_claim(event) then return {} end
    return {
      bindings = { simulator = event.context.actor_user_id },
      state = {
        simulation_epoch = event.state.simulation_epoch + 1,
        pose = validated_pose(event.args.pose),
        linear_velocity = validated_velocity(event.args.linear_velocity),
        angular_velocity = validated_velocity(event.args.angular_velocity),
      },
    }
  end,
}
```

Платформа следит за этим slot и автоматически переключает dynamic/proxy роль клиента и
проверяет отправителя samples. Однако свобода reducer ограничена обязательными инвариантами
динамического профиля: смена `simulator` должна увеличить `simulation_epoch` и включать
валидный handoff keyframe. Невалидная транзакция отклоняется целиком. Проверка объявленной
поддержки профиля назначаемым principal относится к будущему capability negotiation.

Binding и физические поля обязаны находиться в одном record: отдельный custom subject не даст
атомарности. Профиль предоставляет стандартную схему с базовыми командами по умолчанию и
способом объявить/подключить дополнительные reducer-команды мира к тому же subject. После
явного opt-in (`document.physics.bind` либо интеграция существующего `VRWebGrabbable`) отсутствие
custom reducers включает стандартное поведение: grab передаёт simulator держателю, release
оставляет его бросившему, disconnect восстанавливает authority.

## Покрытие публичной демки

Текущая внешняя страница и тесты проверяют:

1. обычный `<RigidBody3D>` со стандартным claim и локальным импульсом;
2. custom reducer, самостоятельно меняющий `bindings.simulator` с cooldown;
3. композицию `VRWebGrabbable` + прямой дочерний `<RigidBody3D>` для grab/throw/handoff;
4. два WebRTC-клиента: поток simulator, proxy на другом клиенте и смену ролей после handoff;
5. binding authorization samples и epoch/tick filtering;
6. sleep/wake через reliable keyframe и остановку/возобновление sample-потока;
7. отсутствие Godot API в авторском Luau.

Сам адаптер также откатывает optimistic handoff при отказе и после истечения reconnect grace
позволяет authority забрать симуляцию через стандартную транзакцию. Отдельные многоклиентские
regression-сценарии для этих двух веток ещё стоит добавить.

При refresh/hot replacement старый adapter закрывается до демонтажа сцены. Все отложенные
claim/recovery callbacks проверяют, что и adapter, и связанный `RigidBody3D` всё ещё находятся
в живом scene tree; существующий, но уже отсоединённый Node не считается допустимым источником
handoff-снимка.

Расширенная матрица loss/jitter, позднего входа во время активного полёта и конкурентных grabs
остаётся следующим уровнем interoperability-тестов, а не условием доступности API.

## Порядок реализации

### Этап 1: переносимый сетевой профиль `RigidBody3D` — реализован

- Сохранить VRWML-модель один-к-одному: физический узел — `<RigidBody3D>` с его обычными
  Godot-свойствами; отдельный физический тег не вводится.
- Определить opt-in через capability API, связывающий сетевой subject с handle существующего
  `RigidBody3D`; если позже понадобится декларативная форма без скрипта, рассматривать её
  отдельно, не подменяя сам тег тела.
- Зафиксировать wire-поля, единицы, систему координат, quaternion, пространства скоростей,
  sleep и обязательный `bindings.simulator`.
- Определить state machine `proxy → simulator → handoff → proxy`, стандартные команды и
  коды отказа.
- Зафиксировать обязательную атомарность смены simulator, epoch и handoff keyframe.
- Определить стандартное поведение без скрипта и границы доверия client-sim/authority-sim.

Результат этапа — движок-независимый контракт и набор test vectors для pose/velocity/handoff.

### Этап 2: binding-aware `SAMPLE` — реализован

Generic `SAMPLE` использует schema-level `sample_write_rule`, для dynamic body —
`{assigned="simulator"}`. Отправитель берётся из
transport identity; principal из payload никогда не используется для авторизации.

- Разрешить sample не-authority пиру только при выполнении правила текущего record.
- На каждом получателе повторно сопоставлять sender peer с каноническим binding.
- Добавить diagnostics stale/drop и позволить конкретным клиентам применять собственную
  фильтрацию; стандарт не задаёт rate/byte caps и не отклоняет authored-поток как «слишком частый».
- Включить в sample `revision`, `simulation_epoch` и `tick`; старые потоки отбрасывать.
- Оставить delivery `unreliable_ordered` и не включать samples в snapshot.
- Проверить ordering относительно reliable handoff delta: новый поток можно временно
  отвергать до прихода binding, но нельзя принять поток старой epoch после handoff.

Этот этап остаётся общим сетевым примитивом и не знает pose или физику.

### Этап 3: physics-схема с расширяемыми reducers — реализована

Обычный custom `document.state` record не подходит: движок не знает его семантику, а отдельный
record для bindings разрушает атомарность. Нужен профильный API, например:

```lua
document.physics.bind("#ball", {
  commands = {
    claim_simulation = { write_rule = "anyone", reducer = claim_ball },
  },
})
```

Платформа дополняет definition обязательными fields, sample rule и стандартными командами,
затем оборачивает custom reducers доменной валидацией. Скрипт может решать, кому передать
`simulator`, но не удалить обязательные поля и не обойти инварианты handoff.

- Один deterministic record `dynamic-body:<element-id>` содержит state и bindings.
- После opt-in стандартные reducers работают без custom-логики автора.
- Custom reducers исполняются authority так же, как текущие Luau reducers.
- Platform validator отклоняет смену simulator без epoch/keyframe и структурно невалидные
  физические значения. Производительность, частота и размер authored
  потока не являются предметом нормативной валидации VRWeb.
- Page/script compatibility hash включает physics profile и custom command definitions.

### Этап 4: доменный клиентский адаптер — реализован

Клиентский адаптер связывает уже материализованный `<RigidBody3D>` с record:

- у simulator тело dynamic и samples берутся после physics tick;
- у остальных тело работает как kinematic/frozen proxy и не создаёт конкурирующую динамику;
- snapshot buffer интерполирует pose и ограниченно экстраполирует по скоростям;
- sleep фиксируется reliable keyframe и прекращает поток;
- локальный impulse разрешён только simulator; дополнительные gameplay-команды автор может
  объявить reducers того же record;
- смена `bindings.simulator` переключает роль ровно один раз на новую epoch.

Алгоритм сглаживания может различаться между движками, но нормативные test vectors задают
ordering, предел экстраполяции и допустимую сходимость.

### Этап 5: интеграция `RigidBody3D` с grabbable — реализована для одного прямого физического корня

Текущий grabbable хранит только `rest`, а свободный rigidbody-ребёнок симулируется локально.
Для сетевого мяча корень интеракции и корень физической позы должны совпадать; простого добавления
скрипта к существующему вложенному `RigidBody3D` недостаточно.

- Сохранить существующую композицию `<VRWebGrabbable>` и вложенного/связанного
  `<RigidBody3D>`; grabbable должен адресовать тот же физический корень, который передан в
  `document.physics.bind`, без нового тега тела и без дублирования hold API.
- После принятого grab свободная физика и sample-поток приостанавливаются, а тело следует руке;
  optimistic grab до authority-ответа остаётся возможным дальнейшим улучшением презентации.
- Принятый grab одной транзакцией назначает `holder`, `controller`, `simulator` и новую epoch.
- Release снимает holder, оставляет simulator бросившему и стартует из позы/скоростей руки.
- Отказ конкурентного grab откатывает локальную презентацию к proxy.
- Theft, auto-release и disconnect используют текущие Subject Bindings и authority recovery.

### Этап 6: recovery реализован; negotiation совместимости остаётся развитием

- Authority следит за presence назначенного simulator и выполняет стандартный recovery.
- Recovery после disconnect стартует из последнего валидного reliable keyframe.
- Не разрешать назначение пира, который не объявил поддержку physics profile.
- Для competitive worlds поддержать `authority-sim`, запрещающий client handoff.
- Определить поведение при version/hash mismatch: тело засыпает как безопасный proxy, а не
  запускает несовместимую локальную физику.
- Knossos может фильтровать samples, защищать собственные ресурсы и показывать diagnostics,
  но эти решения остаются policy конкретной реализации и не становятся ограничениями VRWeb.

### Этап 7: тестовая матрица — базовый unit/scene/WebRTC слой реализован

1. Unit: codec, schema, custom reducer wrapper, binding authorization, epoch/tick filtering.
2. Scene: simulator запускает dynamic body, follower остаётся proxy, sleep останавливает samples.
3. Два клиента: throw → free flight → grab другим игроком → новый throw.
4. Гонки: два одновременных grab; принят один, второй откатывает optimistic state.
5. Сеть: loss, jitter, reordering и reliable handoff, пришедший позже/раньше samples.
6. Lifecycle: late join, simulator disconnect, authority change, reconnect и stale old stream.
7. Implementation profiling: Knossos наблюдает bandwidth/CPU на нескольких десятках тел без
   превращения результатов в нормативные пределы стандарта.
8. Compatibility: клиент без profile и клиент с другим script hash получают безопасный outcome.

### Этап 8: публичная демка и руководство — реализованы

Демо должно быть обычной внешней страницей, а не внутренней Godot-сценой:

- небольшая площадка с несколькими сетевыми мячами;
- grab, бросок, отскок и перехват вторым пользователем;
- видимые `holder`, `simulator`, epoch, sleeping и sample rate для диагностики;
- пример default behavior и второй мяч с custom reducer/cooldown;
- late-join и simulator-disconnect сценарии;
- исходный VRWML + Luau без обращений к Godot API.

Рядом публикуются руководство автора, справочник полей/команд/событий, рекомендации по частоте,
модель доверия, ограничения cross-engine solver и автоматический двух-/трёхклиентский E2E той
же страницы. Рекомендации не являются запретами или transport caps.
