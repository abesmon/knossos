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

**Текущий продуктовый этап: Milestone 4 — hardening переносимого WASM sandbox.**

Уже работают singleplayer 3D browser, multiplayer с текстом и голосом, идентичность домашних
серверов, аватары, декларативные VRWeb-сцены, видео, replicated state, persistence, editor
exporter и WebAssembly Component runtime. Активная работа сосредоточена на четырёх
связанных направлениях:

1. безопасный opt-in профиль декларативного контента;
2. multiplayer-совместимость WASM modules;
3. navigation/redirect hardening и hostile regressions;
4. E2E, fuzz/soak и platform matrix для WASM release gate.

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
- `.vrmod` delivery, integrity/cache и lifecycle;
- versioned WASM Scene API и Maker Kit workflow.

До завершения milestone остаются P0/P1-блоки ниже и server-to-server federation.

### Milestone 4 — Sandboxed extensibility и расширение экосистемы — в работе

- WebAssembly Component sandbox с versioned WIT ABI без raw Godot Object;
- безопасный запуск модулей неизвестного происхождения;
- Godot-совместимый Scene API, Rust/JavaScript SDK и production workflow Maker Kit;
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

### P0 — Scripting preflight и transport boundaries

- [ ] Показывать runtime и permissions каждого пакета в preflight; сохранить default deny и
  добавить UI integration test.
- [ ] Завершить redirect policy: повторно проверять origin/integrity на каждом переходе и
  запрещать downgrade.
- [ ] Не принимать executable bytes от пира как авторитетный источник: каждый клиент получает
  URL/hash из документа, скачивает сам и применяет собственную policy.
- [ ] Добавить hostile fixtures: raw script, неверный manifest JSON, ZIP traversal/collision,
  zip bomb, oversized asset и отмену навигации во время fetch/compile.

### P1 — Module identity и multiplayer compatibility

- [ ] Включить ordered `(module id, runtime, hash)` в room/page identity.
- [ ] При mismatch показывать явный compatibility outcome.
- [ ] Не регистрировать несовместимую replicated schema молча.
- [ ] Проверить двумя чистыми клиентами package-переключатель, late join, смену authority,
  refresh, reconnect и уход со страницы.

Критерий готовности: одинаковые hashes синхронизируют модульный переключатель; другой hash
получает видимый отказ/несовместимость до сетевой регистрации схемы.

### P1 — Navigation pipeline

- [ ] Проверять navigation generation token на стадиях fetch → validate → compile →
  mount/materialize.
- [ ] Добавить loading/cancel UI с текущей стадией и модулем.
- [ ] Локализовать compile/mount failure: статическая часть страницы продолжает работать.
- [ ] Покрыть refresh/navigation во время fetch и поздние callbacks после unmount.

### P1 — Exporter и внешние ресурсы

- [ ] Добавить структурный semantic diff реализованной части сцены после re-export.
- [ ] Доделать asset graph: same-origin URL и автоматические зависимости, а не только literal
  `load()`/`preload()`.
- [ ] Проверить bundled images/audio/glTF/GLB и сложные import options в editor/export builds
  на macOS, Windows и Linux.
- [ ] Подтвердить byte-identical `.vrmod` ZIP на поддерживаемых платформах.
- [ ] Добавить в export report явные skipped files с причинами и полный dependency graph.
- [ ] Добавить явную диагностику autoload/native libs и выхода package dependencies за полный
  разрешённый graph.
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
- [ ] Покрыть local/HTTP/redirect, package/direct Component, замену artifact и два модуля с
  одинаковыми внутренними именами.
- [ ] Добавить debug UI активных модулей, безопасные логи `origin/module/hash` и метрики
  download/compile/mount.
- [ ] После MVP определить origin rules и подписанные каталоги компонентов, не расширяющие
  локальные capability policy без явного решения пользователя.
- [ ] Подтвердить runtime compilation и структурированные ошибки в CI-артефактах трёх платформ.
- [ ] Проверить каталог только из `index.html` и `wasm_scene_demo.vrmod` в чистой сборке и полную очистку
  nodes/signals/timers при навигации.

`fetch` и namespaced storage с quota добавляются после появления первого реального потребителя;
они не блокируют текущий WASM Scene API.

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
- [ ] Выдать rank scripting modules через версионированную capability после определения модели
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

## P3 — Стандартный WASM sandbox

Целевая архитектура выбрана: переносимый runtime VRWeb строится на WebAssembly Component Model.
Стандарт фиксирует WIT ABI и Godot-совместимую семантику Scene API, но не
конкретную VM, язык исходника или движок клиента. Knossos является reference implementation на
Godot и использует один из совместимых native WASM runtimes; выбор конкретной библиотеки остаётся
деталью Knossos. WASI и другие ambient system capabilities по умолчанию не предоставляются.

Конечная отсечка этого плана означает одновременно:

- страница поставляет `wasm-component` с content hash и versioned manifest;
- неизвестный origin может исполнять его без прав процесса клиента;
- Rust и JavaScript являются проверенными authoring-путями, но runtime не зависит от языка;
- Maker Kit собирает статическую `.tscn`-сцену, WASM-модули и assets в воспроизводимый `dist/`,
  а **Build & Run** проверяет именно production runtime;
- Scene API наблюдаемо повторяет зафиксированный Godot compatibility profile, но передаёт guest-коду
  только opaque handles и проверенные значения;
- альтернативный клиент может реализовать тот же WIT/Scene contract без Godot;
- `wasm-component` является единственным executable runtime; исходный язык и editor scripts не
  входят в формат страницы или runtime API.

Каждый этап ниже является отдельной mergeable-отсечкой. Этап нельзя отмечать выполненным только
по наличию кода: должны пройти перечисленные автоматические проверки и ручной smoke-test, если он
указан. После каждого этапа Knossos и Maker Kit должны собираться и открывать статические страницы.
До первого релиза рабочий черновик может меняться несовместимо.

### Этап 0 — Зафиксировать нормативную границу

- [x] Добавить версионированные документы контракта `VRWeb WASM Runtime`, `VRWeb Module Format`
  и `VRWeb Scene API`, не упоминая Wasmtime/Javy как требования стандарта. Зафиксировать
  `runtime="wasm-component"`, отсутствие WASI по умолчанию, opaque handles, lifecycle,
  capability negotiation, локальную policy и деградацию при отсутствии обязательного import.
  Нормативные документы описывают только WASM-модель и не резервируют другие runtime id.

Проверка:

```bash
python3 -B tests/check_docs.py --strict
python3 -B -m unittest tests/test_check_docs_validator.py
```

Ручная приёмка: из документов однозначно следует, что исходный язык и конкретная VM не входят
в runtime contract, а альтернативный клиент обязан реализовать только заявленные WIT worlds и
наблюдаемую Scene-семантику. Отсечка не меняет runtime-поведение приложения.

### Этап 1 — Добавить `wasm-component` в document и manifest IR без исполнения

- [x] Зафиксировать runtime-константу и manifest contract `wasm-component`; реализовать
  collector, manifest parser, normalized module IR и HTML schema под поля `world`, `component`,
  `exports`, `requires` и `optional`. Executable inline source не является формой стандарта.
  Delivery может проверить и кэшировать
  artifact, но backend возвращает структурированное `runtime unavailable`, не инстанцирует код и
  сохраняет статическую часть страницы.

Проверка: parser/manifest fixtures покрывают валидный WASM module, неизвестный runtime,
несовместимый world, неизвестные поля/inline source и graceful degradation; запустить:

```bash
HOME=/tmp/knossos-wasm-plan-home godot --headless --path . \
  --log-file /tmp/knossos-wasm-plan-modules.log \
  --script res://tests/test_scripting_modules.gd
HOME=/tmp/knossos-wasm-plan-home godot --headless --path . \
  --log-file /tmp/knossos-wasm-plan-manifest.log \
  --script res://tests/test_scripting_module_manifest.gd
HOME=/tmp/knossos-wasm-plan-home godot --headless --path . \
  --log-file /tmp/knossos-wasm-plan-package.log \
  res://tests/test_scripting_module_fetcher.tscn
```

Ручная приёмка: страница с WASM-декларацией открывается без падения, показывает понятную
диагностику недоступного runtime и оставляет статическую сцену видимой.

### Этап 2 — Отделить delivery от WASM backend

- [x] Ввести внутренний интерфейс WASM backend с операциями `prepare`, `instantiate_export`,
  `deliver_event`, `unmount` и `close`. Collector принимает только Component declarations;
  authoring source не входит в delivery pipeline. Сохранить общими fetch, integrity,
  content-addressed cache и navigation cancellation. До появления native backend использовать
  `UnavailableWasmBackend`, который локально деградирует компонент.

Проверка: package demo использует WASM declaration с unavailable fallback, а negative fixtures
доказывают отказ неизвестному runtime/manifest. Unit test
с fake backend проверяет dispatch и обязательный `close` при навигации; cache и integrity tests
остаются зелёными уже на новом IR:

```bash
HOME=/tmp/knossos-wasm-plan-home godot --headless --path . \
  --log-file /tmp/knossos-wasm-plan-runtime.log \
  --script res://tests/test_scripting_module_runtime.gd
HOME=/tmp/knossos-wasm-plan-home godot --headless --path . \
  --log-file /tmp/knossos-wasm-plan-cache.log \
  --script res://tests/test_scripting_module_cache.gd
HOME=/tmp/knossos-wasm-plan-home godot --headless --path . \
  --log-file /tmp/knossos-wasm-plan-integrity.log \
  --script res://tests/test_scripting_module_integrity.gd
```

Отсечка: Knossos и Maker Kit собираются, статические страницы работают, executable components
явно деградируют как `WASM runtime unavailable`.

### Этап 3 — Добавить минимальный optional native WASM backend

- [x] Создать GDExtension-обёртку над зафиксированной версией Component Model runtime. Первый
  backend умеет только проверить компонент, инстанцировать модуль без imports, вызвать тестовый
  export и полностью освободить store. Расширение является optional: при отсутствии бинаря
  Knossos собирается и выдаёт `runtime unavailable`; ни один путь не падает при старте.

Проверка: native unit test исполняет fixture `answer() -> 42`, отвергает битый binary и повторяет
instantiate/drop не менее 100 раз без роста числа живых stores. Godot integration test проверяет
feature detection с расширением и без него. Обычный headless smoke приложения проходит в обоих
режимах.

Ручная приёмка: debug-сборка открывает статическую страницу при физически удалённом optional
runtime binary, а после возврата binary тестовый компонент исполняется.

Этот этап дал conformance prototype, но не является решением о долгосрочном владении runtime.
Аудит готовых GDExtension зафиксирован в `docs/client/godot-wasm-evaluation.md`.

### Этап 3a — Зафиксировать границу владения native adapter

- [x] Сравнить поддержку прямого adapter над Wasmtime с переходом на готовые Godot WASM
  extensions. Зафиксировать размер handwritten adapter, фактически переиспользуемые возможности,
  стоимость fork synchronization и условия повторного рассмотрения. Не включать WASI, generic
  Godot reflection или другие возможности только ради унификации с general-purpose runtime.

Проверка: аудит `docs/client/godot-wasm-evaluation.md` содержит рассмотренные revisions,
maintenance comparison и явные triggers пересмотра. Docs validator проходит. Direct dependencies
Wasmtime и `godot-rust` зафиксированы точными версиями; runtime остаётся optional.

Отсечка: Knossos поддерживает только небольшой product-specific adapter, WIT/policy и tests, но не
собственную VM. Рост handwritten native adapter контролируется; достижение установленного порога
возвращает решение на архитектурный review.

### Этап 4 — Довести runtime dependency до platform matrix

- [ ] Добавить воспроизводимую сборку и packaging GDExtension для macOS universal, Windows x86_64
  и Linux x86_64; зафиксировать source revision, license и build flags. `build.sh` проверяет
  наличие правильной библиотеки в exported Knossos, но Maker Kit остаётся без native runtime.
  CI собирает либо скачивает только проверенный content-addressed artifact.

Проверка: отдельный workflow запускает `answer()` fixture в editor/headless и exported debug
build на трёх ОС; `build.sh mac`, `build.sh win`, `build.sh linux` проверяют layout и license.

Отсечка: один и тот же `.wasm` byte-for-byte исполняется на трёх поддерживаемых desktop-платформах.

Текущий прогресс: matrix собирает platform-specific GDExtension, устанавливает официальный debug
export template, экспортирует Knossos и запускает из полученного приложения lifecycle технического
`tests/fixtures/wasm_delivery/lifecycle.vrmod`. macOS exported smoke локально подтверждён: runtime dylib присутствует,
package распаковывается, Component компилируется, а `create → mount → event → unmount` исполняется.
Дополнительно `VRWEB_SKIP_MAKER_KIT=1 build.sh mac` собрал подписанный release archive с runtime
license, после чего бинарь из `.app` успешно выполнил `--vrweb-wasm-self-test`.
После smoke каждая ОС также запускает соответствующий `build.sh mac|win|linux`, проверяя release
layout и включение license. Platform binary публикуется под именем, связанным с SHA-256 evidence;
отдельный fail-closed job принимает результат только при наличии ровно Linux/macOS/Windows с одним
Git revision, pinned runtime metadata и полными security artifacts. Этап остаётся открытым до
первого успешного запуска этой exported matrix на Windows и Linux в CI.

### Этап 5 — Проверять Component Model imports до запуска

- [x] Backend принимает только component binary, заявленный world и разрешённые versioned VRWeb
  imports. Core WASM module, неизвестный required import, несовместимая major version, импорт WASI
  и скрытый дополнительный world отклоняются до lifecycle. Optional import разрешается только
  когда manifest объявил его optional и host его предоставляет. Результат проверки входит в
  preflight и structured diagnostics.

Проверка: fixtures покрывают корректный component, core module вместо component, неизвестный
world, WASI filesystem/socket, required/optional mismatch и version mismatch. Ни один rejected
fixture не вызывает guest export; это подтверждается host-call counter в тесте.

Ручная приёмка: preflight показывает фактические imports, runtime/world и причину несовместимости.

### Этап 6 — Ввести обязательные execution budgets

- [x] Для каждого module instance настроить максимальную linear memory, число tables/resources,
  fuel/instruction budget, wall-clock interruption и лимит host calls на event/frame. Trap,
  превышение памяти и deadline переводят только модуль в stopped state, освобождают его ресурсы
  и не ломают SceneTree или другие модули. Лимиты имеют безопасные defaults и bounded manifest
  hints, которые клиент может только уменьшить локальной policy.

Проверка: hostile fixtures `infinite-loop`, `memory-grow`, `table-grow`, `host-call-flood` и `trap` завершаются
ожидаемым кодом ошибки за ограниченное время; после каждого теста запускается исправный fixture,
доказывая жизнеспособность runtime. Добавить timeout в CI, чтобы зависание было красным тестом.

Отсечка: неизвестный WASM без host API уже можно безопасно валидировать и исполнять как чистое
вычисление с ограниченными ресурсами.

### Этап 7 — Реализовать `vrweb:core`, lifecycle и log

- [x] Зафиксировать WIT package и реализовать создание component instance, `mount`, доставку
  serial event envelope, `unmount` и drop. Добавить только безопасные imports identity/features
  и bounded structured log. Запретить реентерабельный вызов guest-кода: события ставятся в очередь
  и доставляются между host phases. После `unmount` никакой callback исполниться не может.

Проверка: lifecycle fixture записывает точный порядок `create → mount → event → unmount → drop`;
отдельные fixtures проверяют duplicate unmount, event после unmount, recursive host callback,
oversized log и исключение в каждом lifecycle export.

Ручная приёмка: module id/hash и guest log видны в существующем debug output, а переход на другую
страницу всегда заканчивается одним `unmount`.

### Этап 8 — Реализовать value codec и ownership handle table

- [x] Определить каноническое представление scalar, string, byte buffer, arrays/dictionaries и
  Godot-compatible math types (`Vector2/3/4`, quaternion, color, basis, transform). Реализовать
  opaque generational handles с owner module/page, type tag и invalidation. В этом этапе handles
  выдаются только тестовому host object и ещё не меняют сцену.

Проверка: round-trip golden vectors для каждого типа совпадают между native host и минимум двумя
guest SDK fixtures; fuzz/property tests отвергают malformed length/type/UTF-8, NaN policy violation,
oversized nesting, forged/stale/foreign handle. После drop таблица пуста.

Отсечка: ABI способен безопасно передавать значения и ссылки, но не имеет scene authority.

### Этап 9 — Ввести единый `SceneMutation` и read-only Scene API

- [x] Создать host-neutral `SceneMutation`/`SceneQuery` IR и `SceneAuthority`, через который в
  дальнейшем проходят WASM mutations. Сначала guest получает handle только на корень своего
  `<VRWebComponent>` и может читать class, name, parent/children и разрешённые properties.
  Абсолютные NodePath, `/root`, autoload и узлы вне component scope недоступны.

Проверка: fixture обходит собственное поддерево и читает `Node3D.position`; hostile fixtures
запрашивают sibling страницы, player, autoload, абсолютный path, чужой и stale handle. Все отказы
имеют стабильный error code. Существующие document/live-peer materialization tests не меняются.

Ручная приёмка: read-only inspector component печатает только своё поддерево.

### Этап 10 — Добавить транзакционную запись properties

- [x] Реализовать `scene.set` как накопление command buffer: проверить ownership, capability,
  class/property schema, value type, размер и `VrwebContentPolicy`, затем атомарно применить batch
  на границе кадра. Ошибка одной команды отклоняет весь batch. `script`, source code, callback,
  raw object, filesystem path и неописанные object-valued properties запрещены безопасным профилем.

Проверка: LightColor/transform/visibility fixture изменяет сцену; negative fixtures проверяют
неверный тип, read-only property, опасное property, foreign handle, overflow batch и ошибку в
середине транзакции. Snapshot до и после rejected batch должен быть идентичен.

Ручная приёмка: WASM LightSwitch меняет цвет/видимость уже существующего узла, но ещё не создаёт
новых объектов.

### Этап 11 — Добавить create, destroy и reparent

- [x] Реализовать создание allowlisted Node/Resource по class schema, initial property batch,
  добавление только внутрь owned subtree, удаление owned объектов и reparent без циклов/выхода
  из scope. Ввести quotas числа, глубины и стоимости объектов. Host-owned декларативный root нельзя
  удалить; guest-owned descendants удаляются при unmount.

Проверка: fixture создаёт `Node3D + MeshInstance3D + BoxMesh`, переставляет и удаляет их; hostile
fixtures проверяют запрещённый class, parent outside scope, cycle, root deletion, quota overflow и
cleanup после trap/navigation. Scene snapshot после cleanup совпадает с исходным.

Отсечка: компонент умеет полностью строить ограниченное динамическое поддерево.

### Этап 12 — Добавить методы, сигналы и frame events

- [x] Сгенерировать method/signal catalog из зафиксированного Godot compatibility profile и
  наложить data-driven policy overlay. Реализовать `scene.call` только для catalog entries с
  явной classification, а signal subscriptions преобразовывать в bounded event queue. Добавить
  opt-in `update(delta)` с отдельным бюджетом; прямой вызов guest из Godot signal запрещён.

Проверка: fixture вызывает безопасный `AnimationPlayer.play`, получает interaction signal и
обрабатывает несколько frame events. Negative fixtures проверяют неизвестный/запрещённый метод,
опасный return object, signal flood, disconnect, callback после free/unmount и budget exhaustion.

Ручная приёмка: интерактивная дверь открывается по событию и проигрывает allowlisted animation.

### Этап 13 — Перенести portable services поверх WIT

- [x] Реализовать adapters `vrweb:state/1`, `assets/1`, `timers/1`, `input/1`, `features/1` и
  `log/1` по зафиксированной переносимой семантике API. Каждый adapter использует bounded values,
  module namespace и lifecycle cancellation. `fetch`, persistent storage, microphone и прочие
  системные возможности остаются отсутствующими до отдельного deny-first capability milestone.

Проверка: WASM LightSwitch выполняет asset lookup, timer, input и replicated state
command/read/subscription. Golden trace фиксирует ожидаемые state transitions независимо от
конкретного host engine. Navigation test доказывает отмену timers и subscriptions.

Отсечка: функциональный portable API v1 доступен через единственный WASM runtime contract.

### Этап 14 — Научить delivery/cache загружать готовый WASM artifact

- [x] `.vrmod` получает `module.wasm`; unpacker проверяет единственный component entry, manifest,
  размеры, hash и отсутствие native binaries. Разрешить прямой content-addressed `.wasm` только
  с manifest metadata, не меняя cross-origin integrity policy. Cache key включает bytes, runtime,
  world и ABI major; компилированный engine cache является локальной оптимизацией, а не частью
  формата.

Проверка: deterministic package fixture дважды создаёт byte-identical `.vrmod`; fetch/cache tests
покрывают same/cross origin, wrong hash, изменённый manifest, duplicate component, oversized binary,
ZIP traversal и два разных module id с одинаковыми bytes.

Ручная приёмка: опубликованный каталог только из HTML, `.vrmod` и asset открывается в чистой
exported сборке без исходников и build tools.

### Этап 15 — Добавить Maker Kit workflow для prebuilt WASM

- [x] Добавить authoring-only `VrwebWasmComponent` с выбором готового `.vrmod`. Сырой
  `.wasm`/manifest собирается внешним language-neutral canonical packager: Maker Kit не дублирует
  package validation и не содержит compiler toolchain.
  Exporter копирует artifact content-addressed, пишет `<VRWebModule>`, `<VRWebComponent>`, report
  и published manifest. Maker Kit не содержит native WASM runtime и не исполняет модуль в editor;
  production preview идёт через **Build & Run in Knossos**.

Проверка: clean-project portability fixture на трёх ОС собирает одинаковый `dist/`, проверяет
hash/report и содержит prebuilt WASM example:

```bash
bash tests/run_maker_clean_addon.sh
bash build.sh kit
```

Ручная приёмка: автор выбирает узел и готовый WASM, получает working production preview без ручной
правки HTML.

### Этап 16 — Опубликовать language-neutral SDK и conformance fixtures

- [x] Из WIT и Scene schema воспроизводимо генерировать guest bindings, typed Godot-compatible
  facade и fixture modules. Низкоуровневый Rust component оставить компактным conformance oracle:
  он проверяет WIT ABI без вложенной language VM, но не объявляется первым пользовательским
  authoring SDK. Generated files проверяются `--check`, SDK version входит в manifest, а
  несовместимый ABI major не компонуется либо отклоняется loader-ом.

Проверка: clean checkout одной командой собирает Rust LightSwitch, затем Knossos conformance test
проверяет точный scene/event/state trace. Повторная генерация не меняет git tree; fixture `.wasm`
совпадает по hash на поддерживаемых build hosts либо toolchain документирует и проверяет
нормализованный reproducible artifact.

Отсечка: WIT/schema/conformance package не зависит от языка и готов к подключению первого
creator-facing adapter.

Текущий прогресс: `tools/generate_wasm_sdk.py --check` создаёт standalone WIT dependency tree,
versioned SDK metadata и typed JS Scene catalog; pinned Jco генерирует и сверяет guest TypeScript
bindings. Компактный Rust 1.94 + `wit-bindgen` 0.55 oracle воспроизводимо собирается дважды,
пакуется canonical packager-ом и даёт тот же lifecycle trace `71 → 72 → 73 → 74`, что TypeScript
fixture. Оба компонента выполняют одинаковый trace `scene.query → scene.mutate → scene.commit →
state.command → state.read`; Rust package подтверждает byte-reproducible artifact, а JS adapter
явно фиксирует semantic reproducibility вместо ложного обещания одинакового Wizer snapshot.

### Этап 17 — Сделать JavaScript/TypeScript первым creator-facing authoring path

- [x] Зафиксировать `jco componentize`/`componentize-js` как первый проверяемый JS-to-Component
  adapter. Он принимает ES module или TypeScript после transpilation, VRWeb JS SDK, WIT world и
  lock metadata, выдаёт совместимый reactor component и diagnostics. Сборка использует
  `--disable=all`; время, random, log и другие полномочия доступны только через `vrweb:*` imports.
  Начать со статически самодостаточного artifact. Javy оставить отдельным кандидатом для
  оптимизации размера/shared JS engine после измерений: его core-WASM/IO и dynamic-linking модель
  не должна усложнять первый portable path. Конкретный adapter остаётся деталью Maker toolchain,
  а не runtime-стандарта. Browser DOM, Node.js API и неразрешённый WASI отсутствуют.

Проверка: один JS и один Rust LightSwitch дают одинаковый conformance trace. JS hostile fixtures
проверяют `window`, `document`, `fetch`, filesystem/process API, infinite loop и memory growth.
Запустить benchmark размера, cold compile, cold instantiate и event latency; результаты записать
как release evidence, но не превращать конкретные числа в переносимый контракт.

Ручная приёмка: автор редактирует `.js` или `.ts`, запускает одну build-команду и получает `.wasm`,
который работает в той же странице без специального JS runtime API со стороны Knossos.

Текущий прогресс: pinned Jco 1.25.2 + ComponentizeJS 0.21.0 собирают ES module с `--disable=all`,
strict TypeScript 5.9.3 проверяется до транспиляции pinned esbuild, а facade реально получает
scoped Scene root через WIT. Проверяются отсутствие WASI, полный lifecycle и остановка бесконечного
JS-цикла и memory growth в Knossos; Node filesystem import отклоняется build-ом. TypeScript и Rust
дают одинаковые lifecycle и Scene/state LightSwitch traces. Self-contained artifact ≈12 МБ, Wizer
snapshot не byte-reproducible, а измерения componentize/cold prepare/instantiate/event записываются
как release evidence. Adapter остаётся experimental из-за critical audit advisory в неиспользуемой
non-AOT ветке `weval/decompress`. Это запрещает называть toolchain production-ready, но не меняет
исполненный sandbox contract; изолированный external-project/Maker workflow относится к этапу 18.

### Этап 18 — Интегрировать сборку исходников в Maker Kit

- [x] Добавить `Add VRWeb Script`, выбор установленного language adapter, создание template,
  хранение source/module metadata, incremental rebuild по content hash и понятную диагностику
  отсутствующего toolchain. Maker Kit вызывает внешний pinned toolchain безопасным argv без shell,
  но export готового prebuilt WASM остаётся fallback. Исходники не попадают в `dist/` без явной
  publish-source опции.

Проверка: clean Maker project создаёт JS component, собирает его, повторно собирает без изменений
без переписывания artifact, затем меняет source и получает новый hash. Тесты покрывают пробелы в
путях, compile error, missing toolchain, stale output, cancel и Windows/macOS/Linux path rules.

Ручная приёмка: полный авторский цикл выглядит как `создать сцену → привязать JS → Build & Run →
увидеть поведение`; ручной запуск Javy/cargo и редактирование HTML не требуются.

Реализовано: `Add VRWeb Script` создаёт TypeScript template/manifest и source component;
external adapter вызывается argv без shell, source не попадает в package, fingerprint пропускает
неизменившуюся сборку, а compile error/missing adapter сохраняют последний package. Clean Maker
fixture покрывает пути с пробелами и cancel и запускается в platform matrix. Build & Run ведёт
очередь adapters в отдельных processes и даёт **Cancel Script Build** без удаления последнего
artifact. Headless editor smoke на реальных кнопках dock создаёт template/component, выполняет
Build & Run, проверяет package/report, наблюдает compile error без изменения последнего package и
после исправления получает новый fingerprint/hash. Тот же clean-project сценарий входит в
Windows/macOS/Linux matrix. JS adapter формирует минимальный Component WIT из imports после
tree-shaking, поэтому template получает только объявленные manifest capabilities.

### Этап 19 — Добавить production diagnostics и reload

- [x] Передавать module/origin/hash, guest stack/source location и stable error code в build report,
  runtime UI и log. Build & Run пересобирает только изменившийся module и выполняет полную
  безопасную переинстанциацию; локальная WASM memory сбрасывается, а replicated state сохраняется
  через `vrweb:state`. Source maps/debug metadata являются optional sidecar и не дают runtime новых
  capabilities.

Проверка: E2E меняет одну строку JS, наблюдает новый artifact hash, один unmount старого instance,
  один mount нового и сохранённое replicated state. Compile error оставляет предыдущий dist
  целым; runtime trap показывает source location в debug build и не раскрывает локальные host paths
  в production build.

Ручная приёмка: автор исправляет ошибку по сообщению в Godot Output и повторным Build & Run получает
работающий модуль без очистки кэша вручную.

Текущий прогресс: native backend отдаёт stable structured diagnostics с phase/module/origin/hash/
instance и классифицирует policy, trap и budget failures; instance context несёт безопасный
provenance без host component path. Maker incremental build сохраняет последний package при
compile error и следующий Build & Run создаёт новый content hash. In-process reload компилирует,
проверяет signature и probe-монтирует candidate до переключения, оставляя старые instances при
ошибке; успешный reload даёт ровно один old unmount/new mount, новый hash и сохраняет module-scoped
`vrweb:state` при сбросе guest memory/handles/timers. Manifest/package/packager поддерживают
optional declared `.map` sidecar без новых capabilities и отклоняют любые undeclared entries.
JavaScript adapter автоматически сохраняет portable stack через bounded `core.report-error`,
удаляет внутренние ComponentizeJS/temp paths, а runtime применяет Source Map v3 и показывает
логический `vrweb-source:///file:line:column` в structured Godot Output. Реальный TypeScript trap
проверяет это через тот же `.vrmod`. Единый Maker/runtime E2E собирает TypeScript v1, выполняет
его через production loader/backend, вносит compile error и доказывает byte-for-byte сохранение
package и живого instance, затем собирает исправленный artifact. Новый artifact получает другой content
hash; candidate проходит compile/probe, старый JS instance имеет ровно один `unmount`, replacement
— ровно один `create/mount`, а module-scoped state сохраняется. Matrix исполняет этот сценарий на
всех трёх desktop OS.

### Этап 20 — Включить module identity и multiplayer compatibility

- [x] В page/room identity включить ordered `(module id, runtime, world major, hash)`; peers до
  регистрации replicated schema сравнивают наборы и получают явный compatible/degraded/rejected
  outcome. Executable bytes никогда не принимаются от пира: каждый клиент загружает declared
  URL/hash самостоятельно. Authority не может расширить локальные capabilities другого клиента.

Проверка: двухклиентский E2E покрывает одинаковый WASM, другой hash, отсутствующий runtime,
частичную optional capability, late join, reconnect, authority change и navigation. При mismatch
state schema не регистрируется молча и статическая сцена деградирует одинаково у всех peers.

Отсечка: sandboxed component пригоден для реальной multiplayer-страницы, а не только singleplayer.

Реализовано: canonical ordered tuples `(id, runtime, world major, hash)` входят в digest room
key, поэтому разные artifacts fail-closed попадают в разные replicated-state rooms; bytes по-прежнему
получаются только через page delivery. После P2P connect peers явно обмениваются bounded descriptor
с identity/runtime/capabilities; commands, deltas, snapshots и samples закрыты до `compatible`.
Gate выдаёт visible network diagnostic, очищается при disconnect и unit matrix покрывает mismatch,
missing runtime/capability, late descriptor и reconnect. Настоящий двухпроцессный Godot E2E через
standalone signaling и WebRTC загружает identity из собранного JavaScript `.vrmod`: одинаковый hash
получает `compatible`, ACK и converged replicated value, изменённый hash получает
`module_identity_mismatch`, а state остаётся неизменным. Navigation сбрасывает room state и старый
peer descriptor в `pending`, после чего только новый handshake снова открывает replication.
При выходе первоначального authority совместимый follower становится authority и продолжает
принимать команды. Тот же набор четырёх сценариев исполняется из реальных Windows/macOS/Linux
debug exports, содержащих runtime и собранный JS package, а не только через editor binary.

### Этап 21 — Выпустить независимый conformance suite

- [x] Вынести WIT, Scene schema, fixtures и ожидаемые traces в пакет, не зависящий от исходников
  Knossos. Добавить минимальный non-Godot model host, реализующий core lifecycle, handles и часть
  Scene API, достаточную для тех же fixtures. Compatibility report перечисляет class/property/
  method coverage и не позволяет клиенту объявить профиль `full` без всех обязательных tests.

Проверка: один набор неизменённых `.wasm` fixtures проходит в Knossos и model host; результаты
сравниваются как canonical trace. Release CI публикует versioned WIT/schema/conformance archive и
проверяет его в чистом каталоге.

Отсечка: доказано на исполняемом тесте, что VRWeb WASM contract не является скрытым API Knossos.

Реализовано: deterministic archive `vrweb-wasm-conformance-1.0.0-draft.1.zip` содержит WIT,
Scene catalog, неизменённый Rust `.wasm` fixture, canonical expected trace, coverage report и
отдельный Wasmtime model host без Godot/Knossos-кода. Тот же fixture проходит delivery/lifecycle
Knossos и извлечённый в чистый каталог model host. Runner запрещает `full` claim при непустом
`missing_for_full`; текущий честный профиль — `core-scene-state`. Matrix CI собирает versioned
archive byte-for-byte детерминированно, исполняет его из чистого каталога и публикует artifact с
SHA-256 evidence.

### Этап 22 — Провести security release gate и сменить рекомендуемый runtime

- [ ] Объединить hostile corpus: invalid component, import smuggling, infinite loop, memory/table/
  resource growth, host-call flood, forged/foreign/stale handle, path/network/WASI escape, unsafe
  property/method, signal flood, callback after unmount и navigation race. Провести fuzzing binary
  validation/value codec/handle API и platform soak. После зелёного gate неизвестные sandboxed
  modules запускаются по capability policy без доверия правам процесса; prompts остаются только для
  реально запрошенных мощных capabilities. Maker Kit рекомендует WASM для новых компонентов.

Проверка: hostile suite детерминированно завершается в лимит времени на трёх ОС, после каждого
fixture приложение продолжает исполнять исправный модуль; exported E2E и двухклиентский soak зелёные.
Security checklist и точные версии runtime/toolchain сохраняются в release evidence.

Ручная приёмка: страница неизвестного origin с LightSwitch открывается без предупреждения о правах
процесса, а попытка filesystem/network access получает capability denial.

Текущий прогресс: matrix CI объединяет validator mutation corpus, import smuggling/WASI,
infinite loop, trap, memory/table/resource growth, host-call и signal flood, handle ownership,
unsafe Scene operations, callback after unmount и hostile JavaScript. После каждого runtime
failure запускается healthy component. Для каждой ОС публикуется machine-readable evidence с
точными Rust 1.94.0, Wasmtime 46.0.1 и godot-rust 0.5.2. До закрытия этапа ещё нужны navigation
race под нагрузкой и длительный platform soak/fuzz campaign. Короткий exported двухклиентский
gate уже входит в matrix и покрывает mismatch, navigation и authority change. Дополнительный
`navigation-race` выполняет пять последовательных room transitions с очисткой descriptor/state,
новым handshake и командой после каждого перехода. Еженедельный scheduled matrix повторяет весь
неэкспортированный и exported двухклиентский набор десять раз на каждой ОС. Детерминированная
property campaign на каждый CI seed уже покрывает 10 000 случайных binary, 10 000 мутированных
валидных components, 12 000 value inputs и 8 000 handle lifecycle cases; seed и объёмы входят в
machine-readable evidence. Еженедельный run умножает binary/value/handle campaign на 10 и
фиксирует multiplier в evidence. До закрытия этапа нужны накопленные успешные результаты этого
scheduled трёхплатформенного soak/release fuzz, а не новые implementation-механизмы.
Aggregate release gate не доверяет одному matrix leg: он проверяет seed == GitHub run id,
source revision, minimum soak rounds, multiplier и наличие exported/navigation E2E для каждой ОС.

### Этап 23 — Провести финальный product audit WASM runtime

- [x] Оставить `wasm-component` единственным executable runtime стандарта и продукта. Проверить,
  что parser, manifest, editor controls, starter examples, fixtures и документация содержат только
  Component Model contract и не предлагают inline source или выдачу коду прав процесса.

Проверка: repository audit подтверждает единый runtime id и отсутствие альтернативных executable
delivery paths. Standard conformance archive, документация, starter и все примеры используют WASM.
Полный release build, Maker Kit matrix, docs validator и published clean-build E2E зелёные.

Реализовано: исполняемый repository audit проверяет единственную runtime-константу parser,
все поставляемые `vrweb-module.json` и `<VRWebModule>`, отсутствие executable guest source
в starter. Негативные fixtures с неизвестным runtime остаются только как тест отказа parser.

Финальный критерий: модуль неизвестного origin исполняется с ограниченными полномочиями, один и тот
же component работает в reference и non-Godot host, JavaScript/Rust authoring воспроизводим через
Maker Kit, а все полномочия гостя видимы как versioned VRWeb capabilities.

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
