# Subject Bindings: практическое руководство для авторов миров и предметов

Это руководство предназначено для сторонних разработчиков VRWeb-контента. Оно показывает,
как через `document.state` описывать назначаемые роли — ведущего, редактора, водителя,
оператора, капитана, участника места — без собственных полей `*_user_id` и отдельных систем
ownership.

Нормативная модель и ограничения wire-формата находятся в
[network/subject-bindings.md](../network/subject-bindings.md). Полный API — в
[scripting-api.md](scripting-api.md).

## Модель за минуту

У каждого объекта Replicated State есть две согласованные части:

```text
state     — что происходит: playing, slide, speed, locked, round…
bindings  — кто назначен: presenter, editor, driver, captain…
```

Команда исполняется у authority. Её reducer получает:

```lua
event.state
event.args
event.context.actor_user_id -- фактический отправитель команды
event.context.bindings      -- bindings до команды
event.context.rank
event.context.verified
event.context.is_authority
event.context.authority_msec
```

Reducer возвращает одну атомарную транзакцию:

```lua
return {
  state = { playing = true },
  bindings = { presenter = event.context.actor_user_id },
}
```

Обе части применятся с одной revision или не применится ничего. Пустая строка в binding patch
снимает назначение:

```lua
return { bindings = { presenter = "" } }
```

Код размещается в обычном page script. `id` script tag становится частью namespace схем и
объектов, поэтому он должен быть стабильным:

```html
<script type="application/vrweb+luau" id="acme.world-controls">
-- document.state.define / ensure / command / subscriptions
</script>
```

Все клиенты исполняют одну декларацию. Поэтому schema, object id и начальный state должны
получаться детерминированно, а назначение локального пользователя всегда делается командой.

## Когда скрипт вообще не нужен

Subject Bindings не заставляют автора писать policy для каждого объекта:

- `<VRWebGrabbable>` уже использует встроенный `holder`, `grab`, `release` и takeover policy;
- объект `document.scene.add` автоматически получает `bindings.creator`;
- статическая сцена и публичные элементы без эксклюзивного controller не нуждаются в bindings;
- scripted state без назначенной роли может использовать `write_rule="anyone"`, rank или
  `authority` напрямую.

Custom bindings нужны, когда мир вводит собственный ответ на вопрос «кто сейчас назначен на
эту роль?».

## Первый полный пример: оператор общего света

```lua
local schema = "light"
local object = "main"
local version = 1

assert(document.state.define(schema, {
  version = version,
  fields = {
    enabled = { type = "bool", default = false },
  },
  default_write_rule = "authority",
  commands = {
    -- Свободный свет может занять любой идентифицированный участник.
    claim = {
      write_rule = {
        all_of = { "anyone", { vacant = "operator" } },
      },
      reducer = function(event)
        return {
          bindings = { operator = event.context.actor_user_id },
        }
      end,
    },

    toggle = {
      write_rule = {
        any_of = { "authority", { assigned = "operator" } },
      },
      reducer = function(event)
        return {
          state = { enabled = not event.state.enabled },
        }
      end,
    },

    release = {
      write_rule = {
        any_of = { "authority", { assigned = "operator" } },
      },
      reducer = function(_event)
        return { bindings = { operator = "" } }
      end,
    },
  },
}))

assert(document.state.ensure(object, schema, { enabled = false }, {}))

document.state.on(object, schema, function(event)
  print("light:", event.state.enabled, "revision:", event.revision)
end)

document.state.on_bindings(object, schema, function(event)
  print("operator:", event.bindings.operator or "vacant")
end)

document.state.command(object, schema, version, "claim", {})
```

Начальные bindings почти всегда `{}`. Не назначайте локального пользователя через
`ensure(..., {operator = local_user_id})`: каждый клиент исполнил бы регистрацию со своим
значением. Назначение пользователя должно происходить командой, где actor предоставлен
транспортом.

## API чтения и наблюдения

```lua
local all = document.state.bindings("main", "light")
local operator = document.state.binding("main", "light", "operator")
local revision = document.state.revision("main", "light")

document.state.on_bindings("main", "light", function(event)
  -- Полный актуальный snapshot bindings.
  local current = event.bindings

  -- Patch этой revision. При снятии slot здесь будет "".
  local changed = event.changed
end)
```

`bindings()` и callback возвращают snapshots. Не храните старую table как «живой» объект —
после события берите новую.

State и binding callbacks могут прийти отдельно, но несут одну revision. Если UI зависит от
обеих частей, перечитайте обе через `read()` и `bindings()` после любого из событий.

## Декларативные policies

### Базовые predicates

| Rule | Когда разрешает |
|---|---|
| `"anyone"` | actor имеет непустой `user_id` |
| `"authority"` | команду отправил текущий authority |
| `"verified_identity"` | identity actor подтверждена |
| `{assigned="editor"}` | actor назначен в `editor` |
| `{vacant="driver"}` | slot `driver` отсутствует |
| `{rank={op="lte", value=10}}` | ранг actor не хуже 10 |
| `{any_of={...}}` | достаточно одного вложенного правила |
| `{all_of={...}}` | нужны все вложенные правила |
| `{["not"]=rule}` | вложенное валидное правило не выполняется |

Неизвестная или некорректная policy всегда даёт deny. Пустой slot не означает «разрешено
всем»: для публичного захвата пишите `all_of(anyone, vacant)` явно.

### Типовые композиции

Текущий исполнитель или модератор:

```lua
write_rule = {
  any_of = {
    { assigned = "operator" },
    { rank = { op = "lte", value = 10 } },
  },
}
```

Только назначенный участник с подтверждённой identity:

```lua
write_rule = {
  all_of = {
    { assigned = "treasurer" },
    "verified_identity",
  },
}
```

Свободная роль, которую могут занимать только участники определённого ранга:

```lua
write_rule = {
  all_of = {
    { vacant = "presenter" },
    { rank = { op = "lte", value = 100 } },
  },
}
```

Policy отвечает на общий вопрос «кто может вызвать команду». Проверки аргументов и текущего
доменного состояния остаются в reducer.

## Сценарий 1: ведущий презентации

Slots:

- `presenter` — управляет `next`, `previous`, `go_to`;
- state `slide` — текущий слайд;
- state `running` — идёт ли показ.

```lua
commands = {
  claim_presenter = {
    write_rule = { all_of = { "anyone", { vacant = "presenter" } } },
    reducer = function(event)
      return {
        bindings = { presenter = event.context.actor_user_id },
        state = { running = true },
      }
    end,
  },

  next = {
    write_rule = {
      any_of = { "authority", { assigned = "presenter" } },
    },
    reducer = function(event)
      local next_slide = event.state.slide + 1
      if next_slide > event.state.slide_count then return {} end
      return { state = { slide = next_slide } }
    end,
  },

  handoff = {
    write_rule = { assigned = "presenter" },
    reducer = function(event)
      local target = tostring(event.args.target_user_id or "")
      if target == "" or #target > 128 then return {} end
      return { bindings = { presenter = target } }
    end,
  },
}
```

`handoff` намеренно разрешает presenter назначить другого principal. Это не делает значение из
args «доказанной личностью»: sender имеет право делегировать, но UI должен выбирать target из
`document.players.all()`, а для чувствительных ролей reducer/policy может требовать verified.

## Сценарий 2: очередь видео и смена presenter

Храните URL, индекс и timeline в state, а только текущего управляющего — в binding. При переходе
к следующей заявке меняйте всё одной транзакцией:

```lua
next_entry = {
  write_rule = {
    any_of = { "authority", { assigned = "presenter" } },
  },
  reducer = function(event)
    local index = event.state.current + 1
    if index > #event.state.queue_urls then
      return {
        state = { current = -1, src = "", playing = false },
        bindings = { presenter = "" },
      }
    end

    return {
      state = {
        current = index,
        src = event.state.queue_urls[index],
        playing = true,
        anchor_position = 0,
        anchor_time = event.context.authority_msec / 1000.0,
      },
      bindings = {
        presenter = event.state.queue_presenters[index],
      },
    }
  end,
}
```

Так не возникает кадра, в котором уже играет заявка B, но полномочия ещё принадлежат автору A.
Полный вариант очереди есть в [scripting-patterns.md](scripting-patterns.md).

## Сценарий 3: совместное редактирование с creator и editor

Для state-объекта можно разделить неизменяемого создателя и временного редактора:

```lua
commands = {
  create = {
    write_rule = { all_of = { "anyone", { vacant = "creator" } } },
    reducer = function(event)
      return {
        bindings = {
          creator = event.context.actor_user_id,
          editor = event.context.actor_user_id,
        },
        state = { initialized = true },
      }
    end,
  },

  delegate_editor = {
    write_rule = { assigned = "creator" },
    reducer = function(event)
      local target = tostring(event.args.target_user_id or "")
      if target == "" or #target > 128 then return {} end
      return { bindings = { editor = target } }
    end,
  },

  edit = {
    write_rule = {
      any_of = {
        { assigned = "creator" },
        { assigned = "editor" },
        { rank = { op = "lte", value = 10 } },
      },
    },
    reducer = function(event)
      local title = tostring(event.args.title or "")
      if #title > 200 then return {} end
      return { state = { title = title } }
    end,
  },

  stop_editing = {
    write_rule = {
      any_of = { { assigned = "editor" }, { assigned = "creator" } },
    },
    reducer = function(_event)
      return { bindings = { editor = "" } }
    end,
  },
}
```

Slot `creator` остаётся неизменяемым не из-за специального типа: просто нет команды, которая
его переписывает после `create`.

## Сценарий 4: эксклюзивный editor lock с перехватом модератором

```lua
claim_edit = {
  write_rule = { all_of = { "anyone", { vacant = "editor" } } },
  reducer = function(event)
    return {
      bindings = { editor = event.context.actor_user_id },
      state = { editing = true },
    }
  end,
},

release_edit = {
  write_rule = {
    any_of = { "authority", { assigned = "editor" } },
  },
  reducer = function(_event)
    return {
      bindings = { editor = "" },
      state = { editing = false },
    }
  end,
},

moderator_takeover = {
  write_rule = { rank = { op = "lte", value = 10 } },
  reducer = function(event)
    return {
      bindings = { editor = event.context.actor_user_id },
      state = { editing = true },
    }
  end,
},
```

Не делайте отдельные флаги `locked_by_user`, `can_steal`, `is_owner`. `editor` отвечает «кто
назначен», `editing` — «в каком режиме объект», а три команды описывают допустимые переходы.

## Сценарий 5: транспорт с несколькими местами

Один subject может иметь несколько независимых slots:

```text
driver
gunner
seat_left
seat_right
```

Имя места приходит в args, поэтому статическая policy не может заранее написать
`assigned(args.seat)`. Проверка выполняется в reducer:

```lua
local seats = {
  driver = true,
  gunner = true,
  seat_left = true,
  seat_right = true,
}

enter_seat = {
  write_rule = "anyone",
  reducer = function(event)
    local seat = tostring(event.args.seat or "")
    if not seats[seat] then return {} end
    if event.context.bindings[seat] ~= nil then return {} end

    -- Один actor не занимает два места одного транспорта.
    for name, _ in pairs(seats) do
      if event.context.bindings[name] == event.context.actor_user_id then
        return {}
      end
    end

    local patch = {}
    patch[seat] = event.context.actor_user_id
    return { bindings = patch }
  end,
},

leave_seat = {
  write_rule = "anyone",
  reducer = function(event)
    local seat = tostring(event.args.seat or "")
    if not seats[seat] then return {} end
    if event.context.bindings[seat] ~= event.context.actor_user_id
        and not event.context.is_authority then
      return {}
    end

    local patch = {}
    patch[seat] = ""
    return { bindings = patch }
  end,
},
```

Команды движения используют `{assigned="driver"}`, оружия — `{assigned="gunner"}`. Скорость,
руль, заряд и transform остаются state, а не bindings.

## Сценарий 6: командная игра

Пример slots одного матча:

```text
round_host
red_captain
blue_captain
flag_carrier
referee
```

В state находятся `phase`, `score_red`, `score_blue`, `flag_position`. Полезные policies:

```lua
-- Начать раунд может host или referee.
write_rule = {
  any_of = {
    { assigned = "round_host" },
    { assigned = "referee" },
  },
}

-- Назначить капитана может подтверждённый referee.
write_rule = {
  all_of = {
    { assigned = "referee" },
    "verified_identity",
  },
}
```

Захват флага должен атомарно назначать `flag_carrier` и менять state флага. Reducer дополнительно
проверяет phase матча и отсутствие carrier. При смерти/выходе carrier команда `drop_flag`
снимает binding и записывает последнюю позицию.

## Сценарий 7: дверь с operator и аварийным override

Публичной двери binding вообще не нужен: `write_rule="anyone"` достаточно. Binding становится
полезным, если есть режим обслуживания:

```text
state:    open, maintenance
binding:  operator
```

- в обычном режиме `toggle` доступен всем;
- `begin_maintenance` назначает operator и ставит `maintenance=true`;
- пока идёт обслуживание, reducer `toggle` принимает только operator/authority;
- `end_maintenance` атомарно снимает operator и возвращает публичный режим;
- rank override позволяет освободить дверь, если operator ушёл.

Здесь policy `toggle="anyone"` слишком широкая, потому что допуск зависит от state. Оставьте
общую policy открытой, а ветвление сделайте в reducer:

```lua
if event.state.maintenance
    and event.context.bindings.operator ~= event.context.actor_user_id
    and not event.context.is_authority then
  return {}
end
```

## Сценарий 8: player-scoped объект

Для персональной панели, статистики или inventory proxy используйте неизменяемый slot `player`:

```lua
claim_player_object = {
  write_rule = { all_of = { "anyone", { vacant = "player" } } },
  reducer = function(event)
    return { bindings = { player = event.context.actor_user_id } }
  end,
},

update_loadout = {
  write_rule = {
    all_of = { { assigned = "player" }, "verified_identity" },
  },
  reducer = function(event)
    -- validate allowlisted loadout fields, then return state patch
  end,
},
```

Не добавляйте transfer-команду — и slot становится непередаваемым. Однако session binding не
является постоянным инвентарём и не доказывает владение купленным предметом. Для этого нужен
серверный, подписанный persistent record.

## Сценарий 9: временная аренда роли

Bindings сами не содержат TTL. Если роль должна истекать, храните срок в state:

```text
binding: operator
state:   lease_until, lease_epoch
```

`claim` назначает operator и срок одной транзакцией, `renew` доступен operator, `expire` —
authority. После смены authority его монотонные часы имеют другую эпоху, поэтому новый authority
должен переякорить lease или немедленно освободить роль. Не сравнивайте старый
`authority_msec` с часами нового authority без такого перехода.

Для большинства session-ролей надёжнее освобождение по presence, а не таймер.

## Сценарий 10: освобождение роли после ухода участника

Bindings намеренно не угадывают leave policy. В одном мире presenter должен освободиться, в
другом — пережить reconnect, в третьем — перейти заместителю.

Скрипт может наблюдать roster через `document.players.on_changed`. Только локальный authority
отправляет recovery-команду:

```lua
document.players.on_changed(function(event)
  local me = event.local_player
  if not me or not me.is_authority then return end

  local present = {}
  for _, player in ipairs(event.players) do
    present[player.user_id] = true
  end

  local presenter = document.state.binding("deck", "slides", "presenter")
  if presenter ~= "" and not present[presenter] then
    document.state.command("deck", "slides", 1, "recover_presenter", {})
  end
end)
```

```lua
recover_presenter = {
  write_rule = "authority",
  reducer = function(_event)
    return {
      bindings = { presenter = "" },
      state = { playing = false },
    }
  end,
}
```

Для reconnect grace автор мира может хранить `disconnected_since` в state и освобождать позже.

## Сценарий 11: иерархия управления

Bindings не наследуются автоматически от родительского state-object. Это намеренно: не всегда
понятно, должен ли editor автомобиля управлять дверями, оружием и грузом.

Есть два устойчивых варианта:

1. Один агрегированный subject с несколькими полями state и slots. Все связанные изменения
   атомарны в одной revision.
2. Несколько subjects, где дочерняя команда проверяет скопированную/явно назначенную роль.
   Между разными records атомарности нет.

Если нужен строгий единый control scope, предпочитайте первый вариант. Не копируйте binding по
десяткам объектов без команды, которая обновляет их согласованно: Replicated State гарантирует
атомарность внутри одного record, но не распределённую транзакцию нескольких records.

## Сценарий 12: обмен и escrow

Обмен двух предметов кажется простой перестановкой bindings, но bindings разных records нельзя
атомарно поменять одной командой. Безопасная модель:

- отдельный subject `trade` хранит участников, asset descriptors, подтверждения и phase;
- slots `party_a`, `party_b`, `arbiter` назначают роли сделки;
- обе стороны подтверждают один агрегированный trade record;
- authority/сервер завершает постоянную передачу ассетов;
- session bindings предметов обновляются только как отображение подтверждённого результата.

Не используйте два последовательных `transfer` как финансово значимую сделку: между ними один
участник может уйти, команда может быть отклонена, а authority — смениться.

## Scene artifacts и `bindings.creator`

Объекты `document.scene` создаются встроенной системой, поэтому `creator` назначает authority:

```lua
local me = document.players.local_info()
for _, object in ipairs(document.scene.objects("vrweb-node")) do
  local bindings = object.bindings or {}
  if bindings.creator == me.user_id then
    -- UI может предложить edit/remove; authority всё равно проверит действие.
  end
end
```

Текущий `document.scene` предоставляет bindings для чтения, но не произвольную смену creator.
Если артефакту нужен transferable editor, храните edit-session отдельным `document.state`
subject с тем же стабильным id. Само изменение scene-object всё равно проходит встроенную
creator/admin policy.

## Grabbable и `bindings.holder`

Для `<VRWebGrabbable>` slot `holder` ведёт платформа. Скрипту предмета не надо определять hold
schema или посылать binding patches:

```lua
local tool = document.query("#tool")
local holder = tool.call("holder")

tool.on("grab", function(event)
  print("holder:", event.user_id, "hand:", event.hand)
end)

tool.on("drop", function(event)
  print("released by:", event.user_id)
end)
```

`grab` атомарно назначает holder и меняет `hand/grip`; `release` снимает holder и пишет `rest`.
Атрибут `theft="allow|deny"` задаёт встроенный takeover precondition.

## Что не следует превращать в binding

| Данные | Где хранить | Почему |
|---|---|---|
| `hand`, `seat_index`, `team`, `mode` | state | это состояние/характеристика, а не principal |
| display name, avatar URL | players/identity | меняются независимо от назначения |
| rank | room ranks | внешний факт доступа, общий для многих subjects |
| authority | transport | вычисляемый сериализатор, а не назначение мира |
| право на купленный asset | persistent signed record | session binding не является доказательством собственности |
| список наблюдателей | обычно state/roster query | bindings предназначены для небольшого числа именованных ролей |

## Anti-patterns

### Actor в args

```lua
-- Небезопасно: caller сам заявил identity.
bindings = { presenter = event.args.user_id }

-- Правильно для self-claim.
bindings = { presenter = event.context.actor_user_id }
```

### Пустой slot как публичное разрешение

`vacant` сообщает только состояние slot. Команда claim должна также требовать `anyone`, rank
или verified identity.

### Отдельные поля для каждой роли

Не создавайте `driver_user_id`, `editor_user_id`, `presenter_user_id` в state. Иначе придётся
повторять репликацию, подписки, снятие, access checks и лимиты.

### Локальная мутация до canonical event

`document.state.command` отправляет намерение. Не считайте роль полученной сразу после вызова.
Обновляйте UI по `on_bindings`; конкурент мог занять slot раньше.

### Слишком широкая policy

Если `write_rule="anyone"`, reducer обязан проверять state-dependent условия. Не надейтесь, что
наличие binding само ограничит команду: binding влияет только на явно использованный predicate
или проверку reducer.

### Один slot для несвязанных полномочий

`controller` иногда удобен, но presenter видео и editor декора могут иметь разные lifecycle и
риски. Используйте один slot, только если роли действительно всегда передаются вместе.

## Проектирование нового сценария

Перед кодом ответьте на семь вопросов:

1. Какой стабильный subject id и schema описывают объект?
2. Какие данные отвечают «что происходит» и идут в state?
3. Какие данные отвечают «кто назначен» и становятся bindings?
4. Кто может занять свободный slot?
5. Кто может передать, снять или принудительно перехватить его?
6. Что происходит при disconnect, reconnect и смене authority?
7. Какие state и binding изменения обязаны быть одной транзакцией?

Если на вопрос 3 нет ответа, bindings этому объекту, вероятно, не нужны.

## Ограничения текущей реализации

- До 16 bindings на один Replicated State record.
- Имя slot — identifier до 64 символов: `presenter`, `seat_left`, но не `seat-left`.
- Principal — непустая строка до 128 байт.
- Пустая строка допустима только в patch и означает снятие slot.
- Атомарность ограничена одним state record.
- Bindings являются session state и приходят late joiner через snapshot.
- Автоматического наследования, TTL, выбора successor и cross-record transaction нет: эти
  semantics явно задаёт reducer/мировой скрипт.
- `document.scene` bindings сейчас read-only для стороннего скрипта; custom mutable roles живут
  в `document.state`.

## Рабочие примеры в репозитории

- [state_switch.html](../../test_pages/state_switch.html) — reducer одновременно меняет свет и
  назначает custom slot `operator`; `on_bindings` обновляет Label3D.
- [state-switch-demo.md](../client/state-switch-demo.md) — разбор полного пути UI → command →
  authority → atomic delta → Luau subscription.
- [scripting-patterns.md](scripting-patterns.md) — синхронизированный видеоплейлист с presenter.
- [grabbable.md](grabbable.md) — встроенный holder, takeover и release.
- [tool-authoring.md](tool-authoring.md) — creator bindings артефактов переносимых инструментов.
