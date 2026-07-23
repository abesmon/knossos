# Паттерны синхронизации для авторов миров

> Практические рецепты поверх [scripting-api.md](scripting-api.md): как автор мира строит
> собственные системы синхронизации из `document.state`, `document.remote` и
> `document.clock`. Ключевой принцип архитектуры: **authority — это машина консенсуса, а не
> владелец политики.** Authority упорядочивает команды, держит канон и snapshot; кто и чем
> имеет право управлять — решает код автора в reducer'ах и write-rules.

## Выбор канала: state или remote

| | `document.state` | `document.remote` |
|---|---|---|
| Природа | канонический факт с revision | мимолётное адресное событие |
| Валидация | у authority: write-rule + reducer | у получателя: `event.caller` |
| Late join | snapshot автоматически | не доставляется — по построению |
| Доставка | reliable DELTA всем | reliable вызов одному peer |
| Подходит для | «что сейчас истинно»: источник, транспорт, плейлист, счёт | «сделай сейчас»: пересинхронизация, действия ведущего над одним клиентом |

Правило большого пальца: если поздно вошедший должен об этом узнать — это state; если
наоборот **не должен** — это remote.

## Якорная модель транспорта

Для непрерывных процессов (видео, аудио, анимация) не реплицируйте поток тиков —
реплицируйте **якорь**, меняющийся только при действиях:

```lua
fields = {
  src = { type = "string", default = "" },
  playing = { type = "bool", default = false },
  anchor_position = { type = "float", default = 0 },  -- позиция процесса в момент якоря
  anchor_time = { type = "float", default = 0 },      -- authority_time в тот же момент
}
```

Reducer ставит `anchor_time = event.context.authority_msec / 1000` — это та же шкала, что
`document.clock.authority_time()` у каждого клиента. Текущую позицию каждый клиент выводит
локально: `target = anchor_position + (authority_time() - anchor_time)`, а правила
дрифт-коррекции (порог, кулдаун, караоке-сдвиг на задержку голоса, плавный догон вместо
seek) — обычный авторский код в `document.on_update`. Периодического трафика нет; snapshot
бесплатно решает late join.

Две обязательные детали:

- **Разрыв цикла.** Программное применение канона к плееру эмитит те же локальные сигналы,
  что действия игрока; флаг «применяю канон» вокруг таких вызовов не даёт превратить
  применение обратно в команду.
- **Смена authority.** Шкала `authority_time` нового таймкипера имеет другую эпоху — старый
  якорь к ней непереводим. По `document.players.on_changed` тот, кому это положено по вашим
  правилам (новый authority, владелец ролика…), переякоривает канон своей текущей позицией.

Полный работающий референс: [scripted video demo](../../addons/vrweb_tools/examples/scripted_video.html)
(`vrwebresource://examples/scripted_video.html`), разбор — в
[video-player.md](../client/video-player.md#архитектура-базовый-уровень-и-надстройки).

## Рецепт: плейлист заявок с назначенным presenter

Сценарий: любой участник добавляет заявку на видео; правила допуска задаёт автор; за каждым
роликом закрепляется **presenter** (кто добавил), и транспортом текущего ролика управляет
именно он — не authority и не ранг. Это полностью выражается текущим API: «поток
синхронизации по владельцу» — просто авторизационное правило в reducer'е.

```lua
fields = {
  queue_urls   = { type = "array", items = { type = "string" }, default = {} },
  queue_presenters = { type = "array", items = { type = "string" }, default = {} },
	current      = { type = "int", default = -1 },
	src = { type = "string", default = "" },
  playing = { type = "bool", default = false },
  anchor_position = { type = "float", default = 0 },
  anchor_time = { type = "float", default = 0 },
},
commands = {
  -- Кто может добавлять — политика автора: ранг, verified, лимит заявок на участника.
	add_entry = {
		write_rule = "anyone",
		reducer = function(e)
			if #e.state.queue_urls >= 50 then return {} end
			local urls = e.state.queue_urls
			local presenters = e.state.queue_presenters
			table.insert(urls, tostring(e.args.url))
			-- Actor выдан transport context, НЕ взят из args.
			table.insert(presenters, e.context.actor_user_id)
			local patch = { queue_urls = urls, queue_presenters = presenters }
			local binding_patch = {}
			if e.state.current < 0 then  -- плейлист был пуст — сразу запускаем первую заявку
				patch.current = #urls
				patch.src = tostring(e.args.url)
				patch.playing = true
				patch.anchor_position = 0
				patch.anchor_time = e.context.authority_msec / 1000.0
				binding_patch.presenter = e.context.actor_user_id
			end
			return { state = patch, bindings = binding_patch }
		end,
	},
	-- Транспорт принимает только назначенный presenter (authority — recovery/moderation).
	set_playing = {
		write_rule = { any_of = { "authority", { assigned = "presenter" } } },
		reducer = function(e)
			return { state = { playing = e.args.playing == true,
				anchor_position = tonumber(e.args.position) or 0,
				anchor_time = e.context.authority_msec / 1000.0 } }
		end,
	},
	-- Переход к следующей заявке меняет state и presenter одним commit.
	next_entry = {
		write_rule = { any_of = { "authority", { assigned = "presenter" } } },
		reducer = function(e)
			local index = e.state.current + 1
			if index > #e.state.queue_urls then
				return { state = { current = -1, src = "", playing = false },
					bindings = { presenter = "" } }
			end
			return { state = { current = index, src = e.state.queue_urls[index],
				playing = true, anchor_position = 0,
				anchor_time = e.context.authority_msec / 1000.0 },
				bindings = { presenter = e.state.queue_presenters[index] } }
		end,
	},
}
```

Клиентская часть — та же якорная модель: подписка применяет `src`/транспорт к базовому
плееру (`sync="none"`), дрифт-коррекция локальна. Конец ролика ловится сигналом
`finished` плеера (см. [vrweb/video/1](scripting-api.md#видео-плееры-vrwebvideo1)); команду
`next_entry` шлёт presenter — у остальных PolicyEvaluator отклонит команду до reducer.
Если presenter нужен режим «все ждут мою буферизацию», он редкими командами переякоривает
канон позицией **своего** плеера из собственного `on_update`.

Замечания к границам доверия:

- `context.actor_user_id` пока соответствует self-declared identity, пока участник не
  верифицирован через Home Server;
  для владельческих прав в недоверенной комнате требуйте `e.context.verified` или стройте
  правила на рангах. `peer_id` транспортно-аутентичен, но меняется при reconnect.
- Reducer исполняется на клиенте authority: модифицированный клиент authority может
  игнорировать правила. Это общая модель доверия p2p-инстанса (как host-клиент в VRChat),
  а не специфика конкретной схемы.
- Элементы `array`-полей — скаляры; составные записи храните параллельными массивами
  (как выше) либо строками-кортежами.

## Адресные действия поверх канона

Канон отвечает на вопрос «что истинно», но не «сделай именно ты». Для второго —
`document.remote.expose`/`call`: ведущий караоке даёт солисту команду «выйди на сцену»,
модератор просит конкретного клиента пересинхронизироваться немедленно, минуя кулдаун его
дрифт-коррекции. Обработчик проверяет `event.caller` (`is_authority`, `rank`, `user_id`,
`verified` — собраны транспортом, не присланы отправителем) и сам решает, подчиняться ли.
Remote-вызовы не попадают в snapshot и не доигрываются поздно вошедшим — не переносите
через них канонические факты.
