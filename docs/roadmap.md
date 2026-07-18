# Roadmap и планы Knossos

Это **единственный источник истины** для планов разработки Knossos. Тематические документы
описывают архитектуру, контракты, текущую реализацию и известные ограничения; незавершённые
задачи, приоритеты, продуктовые этапы и открытые решения ведутся здесь.

## Как читать roadmap

- **P0** — критическая граница безопасности или совместимости; ближайшая работа.
- **P1** — необходимое для полноценного текущего milestone.
- **P2** — стабилизация, качество, расширение поддерживаемых сценариев.
- **P3** — отдельный долгосрочный milestone после текущего MVP.
- **Готово** означает, что результат реализован и имеет достаточную проверку для текущей стадии.
- **В работе** означает текущий продуктовый фронт, а не обещание конкретного релиза или даты.

Приоритет задаёт порядок важности, но не запрещает брать зависимую P1-задачу раньше P0, если
она разблокирует критический путь.

## Где проект находится сейчас

**Текущий продуктовый этап: поздний Milestone 3 — Custom Worlds hardening и переносимый
Luau scripting MVP.**

Уже работают singleplayer 3D browser, multiplayer с текстом и голосом, идентичность домашних
серверов, аватары, декларативные VRWeb-сцены, видео, replicated state, persistence, editor
exporter и sandboxed page scripting vertical slice. Активная работа сосредоточена на четырёх
связанных направлениях:

1. безопасный opt-in профиль декларативного контента;
2. доставка realtime script revisions и multiplayer-совместимость hashes;
3. navigation/redirect hardening и hostile regressions;
4. E2E и platform matrix для Luau runtime.

## Продуктовые milestones

### Milestone 1 — Singleplayer 3D Browser — готово

- HTTP-загрузка и tolerant HTML parser;
- HTML → топология → геометрия;
- навигация от первого лица;
- CSS-оформление базового окружения;
- ссылки-порталы и история переходов.

Критерий выполнен: URL можно открыть и исследовать как одиночное 3D-пространство.

### Milestone 2 — Multiplayer — готово

- WebSocket signaling и WebRTC mesh;
- удалённые игроки и синхронизация позиций;
- текстовый и пространственный голосовой чат;
- authority, ephemeral changes и generic replicated state.

Критерий выполнен: несколько пользователей на одной странице видят и слышат друг друга.

### Milestone 3 — Identity + Custom Worlds — в работе

Готово:

- VRWML и внешние GLTF/GLB-сцены;
- синхронизированный видеоплеер;
- editor exporter и preview;
- home server, подтверждённая идентичность и анонимный режим;
- persistence и personal spaces;
- inline/linked Luau, общий browser-like page realm, opt-in integrity и staged lifecycle;
- portable `document` API v1, client quotas и атомарная hot replacement.

До завершения milestone остаются P0/P1-блоки ниже и server-to-server federation. Скриптинг
страницы больше не зависит от Godot; user permissions и instance ACL остаются следующими слоями.

### Milestone 4 — Расширение sandboxed extensibility и экосистемы — будущее

- WASM как отдельный эффективный runtime profile при появлении сценария;
- user permissions и instance ACL поверх capability pool клиента;
- расширенные представления клиента: VR/full-body и облегчённый voice-only клиент;
- дальнейшие федеративные и social-возможности поверх открытых контрактов.

## Ближайший критический путь

### P0 — Content Policy safe profile

Текущая база: document и live-peer declarations проходят через единый `VrwebContentPolicy`,
но режим `ENFORCE` пока не содержит запрещающих правил.

- [ ] Вывести audit snapshot в debug UI и показывать редкие/неизвестные комбинации.
- [ ] Вынести class/property/resource rules в data-driven registry.
- [ ] Добавить opt-in safe profile с hard deny для `script`, `source_code`, callback-свойств,
  путей к ФС и произвольных сетевых классов.
- [ ] Ввести бюджеты числа и глубины узлов, ресурсов, размеров и времени.
- [ ] Ограничить URL-схемы, redirects и типы внешнего контента.
- [ ] Проверять одинаковые решения и локальную деградацию для document и live-peer путей.
- [ ] Повторить существенные правила на серверной границе persistence flush, не полагаясь
  только на повторную client-side проверку документа.
- [ ] После сбора audit-данных выбрать default для неизвестного: allow, warn, ask или deny.

Критерий готовности: opt-in профиль блокирует известные опасные декларации до materialization,
не позволяет обойти правила через пира и не ломает остальную сцену при локальном отказе.

Связанные контракты: [content-policy.md](space/content-policy.md),
[security.md](security.md), [vrwml-tags.md](space/vrwml-tags.md).

### P0 — Scripting transport boundaries

- [ ] Завершить redirect policy для linked scripts и запрещать downgrade.
- [ ] Не принимать source bytes от пира как авторитетный источник: каждый клиент получает
  URL/hash из документа, скачивает сам и применяет собственные limits.
- [ ] Добавить hostile fixtures: oversized source, malformed integrity, cancellation во время
  fetch/compile, callback timeout и memory pressure.
- [ ] Оценить hard allocator ceiling в Luau GDExtension; это client hardening без изменения
  стандарта.

### P1 — Script identity и multiplayer compatibility

- [ ] Включить ordered `(script id, runtime profile, hash)` в room/page identity.
- [ ] При mismatch показывать явный compatibility outcome.
- [ ] Не регистрировать несовместимую replicated schema молча.
- [ ] Проверить двумя чистыми клиентами state-driven script behavior, late join, смену authority,
  refresh, reconnect и уход со страницы.

Критерий готовности: одинаковые hashes синхронизируют поведение; другой hash
получает видимый отказ/несовместимость до сетевой регистрации схемы.

### P1 — Navigation pipeline

- [ ] Проверять navigation generation token на стадиях fetch → integrity → compile →
  mount/materialize.
- [ ] Добавить loading/cancel UI с текущей стадией и script id.
- [ ] Локализовать compile/mount failure: статическая часть страницы продолжает работать.
- [ ] Покрыть refresh/navigation во время fetch и поздние callbacks после unmount.

### P1 — Exporter и внешние ресурсы

- [ ] Добавить структурный semantic diff реализованной части сцены после re-export.
- [ ] Доделать asset graph: same-origin URL и автоматические зависимости, а не только literal
  `load()`/`preload()`.
- [ ] Проверить bundled images/audio/glTF/GLB и сложные import options в editor/export builds
  на macOS, Windows и Linux.
- [ ] Добавить в export report явные skipped files с причинами и полный dependency graph.
- [ ] Запускать preview через обычный runtime и content policy клиента.
- [ ] Добавить save-hook, автоматически снимающий preview-свойства перед сохранением.
- [ ] Добавить экспорт declarative events/действий после фиксации их контракта.

### P1 — VRWeb Maker Kit: будущая release-проверка

- [ ] Получить зелёный запуск `maker-kit.yml` на macOS, Windows и Linux для exact-case/missing
  asset paths, glTF dependencies, schema freshness и byte-identical rebuild.
- [ ] Перед публичным релизом открыть output release archive чистым exported Knossos на macOS,
  Windows и Linux и сохранить результаты как release evidence.

### P2 — Release confidence

- [ ] E2E: exporter → HTTP fixture → чистая exported build → два multiplayer-клиента.
- [ ] Покрыть local/HTTP/redirect, inline/linked и две ревизии с одинаковыми script ids.
- [ ] Добавить debug UI активных scripts, безопасные логи `origin/script/hash` и метрики
  download/compile/mount.
- [ ] Спроектировать user permissions и instance ACL как пересечение с capability pool клиента.
- [ ] Подтвердить runtime compilation и структурированные ошибки в CI-артефактах трёх платформ.
- [ ] Проверить каталог из HTML и linked `.luau` в чистой сборке и полную очистку
  nodes/signals/timers при навигации.

`document.fetch` и persistent namespaced storage с quota добавляются после появления первого
реального потребителя; они не блокируют текущий Scripting API v1.

## Multiplayer, identity и persistence

### P1 — Надёжность replicated state

- [ ] Fault-injection тест настоящего split-brain с последующим слиянием двух живых компонент
  mesh.
- [ ] Если дрейф видео окажется заметен, оценивать часы authority и позицию от временного якоря.
- [ ] Провести длительный двухклиентский soak: simultaneous seek, late join, authority change и
  reconnect.

### P1 — Federation и instance contract

- [ ] Реализовать server-to-server federation signaling, чтобы пользователи разных signaling
  servers попадали в один mesh.
- [ ] Стандартизировать приватный query-параметр, рабочий вариант `vrweb-instance=<code>`.
- [ ] Обкатать server-provided adaptive representations через request header с рабочим именем
  `VRWeb-Capability-Code`, не меняя URL/room key и не создавая registry конкретных codes заранее.
- [ ] Зафиксировать cache contract (`Vary`), redirect policy и HTTP test vectors negotiation.
- [ ] Определить минимальный проверяемый network ABI вариантов в Maker Kit.
- [ ] Добавить явный compatibility/discovery contract для сторонних клиентов и серверов.

### P2 — Personal spaces и persistence vNext

- [ ] Резолв чужого дома с учётом privacy policy.
- [ ] Временные invitation capability-links.
- [ ] Несколько пространств пользователя, сохранив `home` дефолтом.
- [ ] Федеративный auth приватного fetch.
- [ ] Протокольное выселение гостей при закрытии пространства.
- [ ] HTML-представление и flush мировых `stroke`/`bubble` объектов.
- [ ] Мягкое уведомление `page-revised` после flush.
- [ ] Доставка результата `deferred` через pending endpoint или webhook.
- [ ] Более тонкие серверные права и квоты по зонам/kind.
- [ ] Версионирование/rollback остаётся ответственностью сервера, но нужен ясный contract.
- [ ] При необходимости добавить параллельную загрузку blob-чанков от нескольких peers.
- [ ] Расширять realtime blob consumers с картинок на аудио/меши только под конкретные сценарии.

### P2 — Space Console и live editing

- [x] Реализовать rank-0 instance config override для `combine`/`exclusive`: общий
  allowlisted config-state корня, без page opt-in и без участия в flush; проект контракта —
  [client/space-console.md](client/space-console.md#смена-combine--exclusive-из-консоли).
- [ ] UI восстановления tombstoned node.
- [ ] Явная UX-обработка version skew и частичного отказа batch.
- [ ] Пересборка специальных VRWeb-узлов при live patch либо документированное ограничение
  поддерживаемого набора мутаций.
- [ ] GC persisted overlay objects после подтверждения, что база всех peers достигла нужной rev.
- [ ] Пользовательская policy доверия действиям неподтверждённых peers.
- [ ] Выдать право публикации script revisions через версионированную capability после определения модели
  доверия.

## Client и media

### P2 — Video и voice

- [ ] 3D-позиционное аудио видеоповерхности.
- [ ] HLS/DASH поверх существующей прогрессивной докачки.
- [ ] Передача роли контроллера и owner-presenter mode.
- [ ] Интерактивный seek по progress bar и регулятор громкости.
- [ ] Адаптивный voice bitrate/DTX по transport pressure.
- [ ] При росте комнат оценить SFU вместо квадратичного mesh uplink.

### P2 — Performance streaming и UI

- [ ] Distance-based materialization/unload комнат после профилирования текущего frame streaming.
- [ ] Пул/атлас world-space viewports или MSDF-путь для страниц с сотнями RichPanel.
- [ ] Реальный замер высоты RichPanel вместо эвристики текста.
- [ ] Согласованный reflow геометрии после загрузки медиа без HTML-размеров.
- [ ] Зарегистрировать deeplink-схему в packaged builds через installer/first-run integration.
- [ ] Определить inventory/ownership и материализацию сериализуемых `tool-*` объектов, прежде
  чем отправлять `PlayerTool.descriptor()` в ephemeral layer.
- [ ] Добавить визуальный avatar picker и валидировать расширяющийся набор avatar parameters.
- [ ] Зафиксировать правила spawn/teleport points для custom VRWeb scenes.

## HTML → 3D и геометрия

### P2 — Калибровка реального веба

- [ ] Настроить contraction/clustering/heading thresholds на корпусе реальных сайтов.
- [ ] Реализовать очистку уверенной обвязки без потери полезного контента.
- [ ] Исследовать fallback для div-soup и media-as-heading.
- [ ] Проверить конфликт явного и визуального ранга заголовков.
- [ ] Добавить layout boxes через будущий полноценный web-engine/GDExtension; mini CSS cascade
  намеренно их не моделирует.
- [ ] Поддержать `data:` images и `srcset`/`picture`; JS-rendered SPA требует отдельного
  proxy/headless-browser направления.
- [ ] Ввести `entry` для составного поддерева топологии.
- [ ] Протокол site-hosted transformation templates рассматривать отдельным layer 0.

### P2 — SpaceLayout и world visualization

- [ ] Рассчитывать запас на проход по метрическим размерам и плотности объектов.
- [ ] Обрабатывать `unrouted` связи перестройкой layout.
- [ ] Поддержать ширину коридора больше одной клетки.
- [ ] Материализовать внутренние routes в 3D.
- [ ] Минимизировать фактическую BFS-длину коридора, а не приближённую дистанцию.
- [ ] Добавить миро-ориентированные CSS-свойства сверх цвета после реальных use cases.
- [ ] Моноширинный рендер `<pre>/<code>` и дополнительные media/object representations.

## P3 — Настоящий sandbox

- [ ] Сравнить WASM без WASI, worker process и embeddable VM по portability, startup,
  interruption, memory limits, debug/source maps и размеру.
- [ ] Зафиксировать capability ABI v1 без raw Godot Object.
- [ ] Реализовать ownership handles, quotas, instruction/time budget, termination и отзыв
  capabilities после unmount.
- [ ] Перенести Scripting API adapters поверх ABI; prompts fetch/storage/mic сделать deny-first.
- [x] Перенести LightSwitch на sandboxed Luau: обычные VRWML-узлы, opaque handles,
  `document.state`, page-defined reducer и scene subscription; специальные state/action tags удалены.
- [x] Добавить типизированные адресованные `document.remote` calls и реактивный read-only
  `document.players` для локальных authority/rank правил и roster UI.
- [ ] Расширить hostile fixtures: sustained memory growth, чужой handle, дополнительные
  path/network escape и callback после unmount (infinite top-level/callback loops уже покрыты).

Критерий: модуль неизвестного origin запускается без прав процесса, а hostile fixtures
детерминированно ограничиваются host runtime.

## Открытые продуктовые решения

- Какие визуальные эвристики нужны как fallback для div-soup сайтов?
- Нужен ли открытый формат community/site-specific правил трансляции HTML → 3D?
- Какой default warning/skip profile выбрать для неизвестных декларативных классов после audit?
- Достаточен ли `vrweb-instance` как общеэкосистемный private-instance contract?
- Какие реальные потребители должны сформировать `fetch/storage` capabilities?
- Когда масштаб комнат оправдает SFU и облегчённый voice-only клиент?

## Правило сопровождения

При появлении новой идеи или незавершённой работы:

1. добавить или обновить её **в этом документе**;
2. в тематическом документе описать только уже действующий контракт/реализацию/ограничение;
3. из тематического документа дать ссылку на соответствующий раздел roadmap;
4. не создавать отдельные TODO, roadmap, «что дальше» или списки будущих работ.

Статическая проверка локальных ссылок, anchors, orphan-документов и этого правила запускается
командой:

```bash
python3 -B tests/check_docs.py --strict
```

Та же команда автоматически выполняется в GitHub Actions при изменении Markdown-файлов.
