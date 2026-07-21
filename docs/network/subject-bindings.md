# Subject Bindings и политики доступа

> **Статус:** нормативный контракт. Реализован в текущем realtime-протоколе, Replicated State,
> SceneChanges и grabbable. Обратная совместимость с полями `author`, `owner_user_id` и
> `holder_user_id` намеренно не поддерживается.

Связанные документы: [replicated-state.md](replicated-state.md),
[ephemeral-changes.md](ephemeral-changes.md), [authority.md](authority.md),
[ranks.md](ranks.md), [grabbable.md](../space/grabbable.md).

Практическое применение в сторонних мирах и предметах: сценарии, готовые policies и Luau-код —
в [руководстве для авторов контента](../space/subject-bindings-guide.md).

## Решение

VRWeb не вводит отдельную универсальную сущность `Ownership` и не размножает роли `author`,
`owner`, `holder`, `created_by`, `presenter`, `editor`. Вместо этого у subject есть маленький
словарь именованных привязок:

```text
bindings = {
  creator:  "user-a",
  holder:   "user-b",
  presenter:"user-c"
}
```

Имя slot задаёт смысл в конкретном домене, значение — principal (`user_id` в текущем контракте).
Пустого значения в каноническом словаре нет: patch `{"holder": ""}` снимает привязку.

`ControlSlot` — полезная ментальная модель этого механизма, но не отдельный wire-тип. И
`holder`, и `creator` действительно являются частными случаями привязки субъекта. Отличается
не инфраструктура, а policy:

- `creator` обычно назначается при создании и больше не меняется;
- `holder` назначается и снимается командами `grab`/`release`;
- `presenter`, `driver`, `editor`, `operator` определяются автором мира.

Так `created_by` не нужен как самостоятельное системное поле. Если миру необходима неизменяемая
provenance, policy просто запрещает менять slot `creator`. Если юридическая или серверная
атрибуция должна переживать комнату и быть криптографически доказуемой, это уже metadata
постоянного ресурса, а не session binding.

## Зачем это нужно

Механизм оправдан не ради терминологии, а потому что одинаковая задача уже возникла в трёх
независимых системах:

| Было | Стало |
|---|---|
| `SceneChanges.author` одновременно как происхождение и ACL | `bindings.creator` + единый predicate `assigned` |
| `ReplicatedState.owner_user_id` и `object_owner` | произвольные bindings + `assigned(slot)` |
| `Grabbable.holder_user_id` и отдельные проверки | `bindings.holder`, обновляемый атомарно с `hand/grip/rest` |

Без общего слоя каждый новый мир снова изобретает `presenter_user_id`, `driver_id`, правила
пустого значения, snapshot, события, валидацию и восстановление. С bindings новый домен задаёт
только имя slot и reducer перехода.

Механизм **не нужен** объектам, у которых нет назначенного участника. Публичная дверь может
иметь policy `anyone` и пустые bindings. Статическая геометрия вообще не регистрирует subject.
Это не обязательная обёртка каждого Node и не второй глобальный object graph.

## Что взято у VRChat

VRChat Object Ownership даёт одному игроку право сериализовать сетевые переменные объекта,
поддерживает transfer и переназначение после ухода. Это удобно для pickup, физики, видео и
player-scoped объектов: один термин закрывает много сценариев.

VRWeb берёт полезные свойства:

- один канонический назначенный субъект для конкретной роли;
- явные, наблюдаемые переходы;
- late join получает назначение вместе с состоянием;
- уход/перехват обрабатывается policy, а не случайным клиентским соглашением;
- одна абстракция работает для предмета, пульта, редактора и ведущего.

Но VRWeb не копирует distributed writer ownership. Authority комнаты уже проверяет и
упорядочивает команды. Клиент никогда не публикует «теперь slot мой»; он отправляет намерение,
authority запускает policy/reducer и рассылает каноническую delta. Поэтому binding — данные для
решения, а не право обходить authority.

## Минимальная модель

Нужны только четыре широких понятия:

1. **Actor** — фактический инициатор из transport context.
2. **Subject** — адресуемый объект состояния или сцены.
3. **Bindings** — именованные связи subject → principal.
4. **Policy** — правило, разрешающее action при данном context.

`authority`, `rank`, `verified` — факты контекста, а не виды ownership. `hand`, `grip`, `rest`,
`seat`, `tool_mode` — доменное состояние, а не bindings. Практический тест границы:

- «кто назначен?» → binding;
- «что сейчас происходит с объектом?» → state;
- «можно ли выполнить действие?» → policy;
- «кто сериализует решение?» → authority.

## PolicyEvaluator

Authority формирует доверенный context:

```text
{
  actor_user_id,
  is_authority,
  rank,
  verified,
  bindings
}
```

Аргументы команды не могут подменить эти поля. Декларативные predicates:

```text
"anyone"
"authority"
"verified_identity"
{assigned: "creator"}
{vacant: "holder"}
{rank: {op: "lte", value: 10}}
{any_of: [...]}
{all_of: [...]}
{not: ...}
```

Неизвестное или некорректное правило закрывается отказом. `assigned` сравнивает actor с
актуальным slot; `vacant` только проверяет отсутствие назначения и само по себе никому ничего
не разрешает.

### Кто описывает policies

Да: прикладные policies явно задают разработчики мира в схемах и reducer-ах. Платформа даёт
маленький словарь безопасных predicates, доверенный actor context, сериализацию, лимиты и
атомарный commit. Она не угадывает, должен ли `creator` иметь право удалить объект или может ли
новый игрок перехватить `presenter`.

Для мира без скриптов действуют встроенные базовые policies:

- scene artifact: creator или участник с административным rank;
- grabbable: любой идентифицированный actor может взять свободный предмет; takeover зависит от
  атрибута предмета; release/adjust — текущий holder либо authority recovery;
- общая конфигурация инстанса: rank policy;
- статическое содержимое страницы: без bindings и без runtime-мутаций.

Defaults являются обычными платформенными reducers, а не скрытым альтернативным механизмом.

## Атомарная транзакция

Reducer Replicated State возвращает:

```lua
return {
  state = { hand = event.args.hand, grip = event.args.grip },
  bindings = { holder = event.context.actor_user_id },
}
```

`state` и `bindings` валидируются до мутации, получают одну `revision` и одну ordered delta.
Если неверно хотя бы одно поле или имя slot, не меняется ничего. Binding-only транзакции также
разрешены. Это устраняет промежуточные состояния «назначен holder, но hand ещё пуст» и
«presenter сменился, а режим воспроизведения остался от старого».

Snapshot хранит bindings рядом с record. При hot replacement, reconnect и смене authority
актуальные state и bindings восстанавливаются вместе.

## Публичный scripting API

```lua
document.state.ensure("deck", "slides", {}, {})
document.state.bindings("deck", "slides")       -- snapshot table
document.state.binding("deck", "slides", "presenter")
document.state.on_bindings("deck", "slides", function(event)
  -- event = {bindings, changed, revision}
end)
```

Обычно начальные bindings пусты: назначение выполняет команда, чтобы actor пришёл из transport
context. Reducer читает `event.context.bindings` и возвращает `bindings` patch. Не следует
передавать заявленный `user_id` в args.

Объекты `document.scene.object(s)` содержат тот же словарь `bindings`; созданный объект получает
`creator` от authority. Отдельный `document.ownership` не вводится: он дублировал бы адресацию,
snapshot и события уже существующих state/scene API.

## Общие сценарии

### Артефакт и совместное редактирование

Штрих создаётся с `creator=A`. Базовая policy разрешает изменение A или модератору. Мир может
добавить `editor=B`, не меняя creator, и разрешить `any_of(assigned(editor), assigned(creator))`.

### Предмет в руке

`grab` одним commit назначает `holder` и меняет `hand/grip`. `release` снимает holder и пишет
`rest`. `takeover_allowed` остаётся доменным state/precondition: это свойство предмета, а не
новый вид ownership.

### Презентация или общее видео

Slot `presenter` определяет, кто может посылать `play/seek/next`. Команда `claim_presenter`
может требовать `vacant`, rank или текущего presenter. Уход обрабатывается отдельной командой
recovery у authority. Видео не нуждается в собственном `video_owner_id`.

### Транспорт и места

`driver`, `gunner`, `seat_1` — независимые slots одного subject. Машина не требует сущностей
DriverOwnership и SeatOwnership. Скорость и transform остаются state; вход/выход атомарно
меняет seat binding и состояние посадки.

### Командная игра

`team_red_captain`, `flag_carrier`, `round_host` используют ту же механику. Policy комбинирует
bindings, rank и игровое state. Новые роли не требуют изменения сетевого протокола.

### Player-scoped объекты

Slot `player` назначается при создании и policy запрещает его изменение. Это покрывает полезную
часть VRChat PlayerObject без специального класса ownership. Удаление subject удаляет и binding.

## Безопасность и ограничения

- Только authority коммитит переходы и формирует actor context.
- Slot names — валидные identifiers до 64 символов; не более 16 slots на record.
- Principal — непустая строка до 128 байт; пустая строка в patch означает remove.
- Unknown policy deny; пустой slot не означает `anyone`.
- Bindings дают session-полномочия только в рамках конкретной policy. Они не доказывают право на
  asset, серверную запись или identity без `verified_identity`.
- Смена authority не переназначает slots автоматически: преемник получает snapshot. Leave
  lifecycle обязан быть явной встроенной или мировой policy.

## Почему не более атомарная модель

Отдельные системные типы `Author`, `Owner`, `Holder`, `ControllerAuthority` выглядят точнее, но
закрепляют сегодняшние домены в фундаменте. Более broad модель bindings сохраняет различия там,
где они важны — в имени slot и policy — и объединяет только одинаковую инфраструктуру:
валидацию, репликацию, наблюдение, late join и атомарные переходы.

При этом не надо схлопывать вообще всё в binding. Положение руки не становится `ControlSlot`,
ранг не становится owner, а authority не становится holder. Broad abstraction полезна лишь до
тех пор, пока отвечает одному вопросу: «какой principal сейчас назначен на именованную роль у
этого subject?»
