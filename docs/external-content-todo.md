# TODO: внешние ресурсы, скрипты и демо

Актуально после коммитов `c7ff6e5` (внешние ресурсы), `3ee8c17` (базовая безопасность
скриптов) и `71a3c2f` (обновление работы со скриптами).

Уже работает базовый вертикальный срез: inline- и package-скрипты, `.vrmod`, integrity,
immutable cache, preflight до компиляции, trust по exact hash, lifecycle, replicated state,
таймеры, manifest-declared assets и первый exporter round-trip. Ниже — оставшаяся работа.

## P0 — внешний developer-facing сценарий

- [x] Зафиксировать минимальный VRWeb Scripting API v1 как единственную поддерживаемую границу для внешних
  разработчиков. Компоненты не должны обращаться к `main`, autoload-ам, `NetworkManager`,
  `BlobStore`, `Player` и внутренним абсолютным `NodePath`.
- [x] Доделать минимальный `context.scene`: root/find, владение веткой компонента и
  инвалидирование после `unmount()`.
- [x] Добавить минимальные `context.input`, `context.log` и `context.features.has()`.
- [ ] Добавить `context.fetch` (сначала same-origin) и namespaced `context.storage` с quota,
  когда появится первый реальный потребитель.
- [x] Опубликовать таблицу API: public/stable, runtime extension и internal/closed. Для закрытого API
  явно не гарантировать совместимость; в dev-сборке диагностировать его использование модулем.
- [x] Перевести эталонный `LightSwitch` только на public context API: без ссылок на внутренности
  клиента. Зафиксировать версии facade/capabilities и отказ при неизвестной версии.

## P0 — критичные границы безопасности

- [ ] Ввести allowlist классов и свойств для декларативных `<vrweb>`-узлов: запретить
  `script`, `source_code`, callback-и, пути к ФС и произвольные сетевые классы.
- [ ] Применять policy к документу, `vrweb-node` от пиров и persistent content. Иначе защита
  страницы обходится через peer.
- [ ] Добавить лимиты числа/глубины узлов, ресурсов, размеров и времени; ограничить URL-схемы,
  redirects и типы контента.
- [ ] Показывать runtime и permissions в preflight; сохранить default deny и добавить UI-тест.
- [ ] Доделать redirect policy: повторная проверка origin/integrity, запрет downgrade и тесты.
- [ ] Добавить hostile/fuzz fixtures: raw script, manifest JSON, ZIP directory, traversal,
  zip bomb, oversized asset и отмена навигации во время fetch/compile.

Trust dialog и SHA-256 разрешают запуск конкретных байтов, но не превращают GDScript в
песочницу. Trusted GDScript остаётся режимом с правами процесса.

## P1 — внешние ресурсы и exporter

- [ ] Поддержать материалы, `.gltf` с внешними buffers/textures и все нужные меши GLB.
- [ ] Доделать asset graph: same-origin URL dependencies и автоматические зависимости, а не
  только literal `load()`/`preload()`.
- [ ] Проверить bundled assets на macOS/Windows/Linux и в editor/export builds; покрыть картинки,
  аудио, glTF/GLB и сложные import options.
- [ ] Сделать `.vrmod` ZIP полностью deterministic на поддерживаемых платформах.
- [ ] Добавить module id в Inspector/metadata UI; расширить report: permissions, skipped files
  с причинами, dependency graph и hashes.
- [ ] Усилить inline validation: зависимости, `@tool`, autoload, native libs, C# и выходы за
  выбранный dependency graph должны отклоняться.
- [ ] Запускать preview через обычный runtime и policy клиента, без упрощённого пути.
- [ ] Добавить loading/cancel UI по стадиям fetch → validate → trust → compile → mount и везде
  проверять navigation generation token.

## P1 — multiplayer и совместимость

- [ ] Включить ordered `(module id, runtime, hash)` в identity комнаты/страницы.
- [ ] При mismatch показывать явный compatibility outcome и не регистрировать несовместимую
  replicated schema молча.
- [ ] Проверить двумя чистыми клиентами package-переключатель, late join, смену authority,
  refresh и уход со страницы.
- [ ] Не принимать executable bytes от пира: каждый клиент берёт URL/hash из документа,
  скачивает сам и применяет собственную policy.

## P1 — демо и документация

- [x] Добавить в `test_pages/index.html` self-contained package-demo переключателя.
- [x] Положить готовый `.vrmod` с GDScript, `.tscn`/`.tres` и ассетом, исходный fixture и
  воспроизводимую команду/действие exporter с проверкой integrity.
- [ ] Сделать парные примеры inline и package и объяснить выбор между ними.
- [ ] Добавить негативные демо: wrong integrity, новый hash, deny, compile error и mount error;
  статическая часть страницы должна продолжать работать.
- [ ] Написать guide внешнего разработчика: manifest, public API, permissions, integrity,
  lifecycle, ограничения и диагностика.

## P2 — trusted modules MVP

- [ ] E2E: exporter → HTTP fixture → чистая exported build → два multiplayer-клиента.
- [ ] Покрыть local/HTTP/redirect, inline/src/package, две версии и два модуля с одинаковыми
  внутренними именами.
- [ ] Добавить debug UI активных модулей, безопасные логи `origin/module/hash` и метрики
  download/compile/mount.
- [ ] Подтвердить runtime-компиляцию и ошибки в CI-артефактах macOS/Windows/Linux.
- [ ] MVP готов, когда каталог из `index.html` и `lights.vrmod` работает в чистой сборке и
  полностью очищается при навигации.

## P3 — настоящий sandbox

- [ ] Сравнить WASM без WASI, worker process и embeddable VM по portability, startup,
  interruption, memory limits, debug/source maps и размеру.
- [ ] Зафиксировать capability ABI v1 без raw Godot Object.
- [ ] Реализовать ownership handles, quotas, instruction/time budget, termination и отзыв
  capabilities после `unmount()`.
- [ ] Перенести `KnossosPageAPI` adapters поверх ABI; prompts для fetch/storage/mic — deny-first.
- [ ] Сделать sandboxed LightSwitch и hostile-набор: infinite loop, memory growth, чужой handle,
  path/network escape и callback после unmount.

## Ближайший инкремент

1. Минимальные `scene`, `input`, `log`, `features` facade и public API v1.
2. `LightSwitch` без закрытых API и package-demo с воспроизводимым экспортом.
3. Два клиента и явная module identity/mismatch semantics.
4. Allowlist декларативных узлов — наиболее опасный обход preflight scripting modules.

Подробности: [scripting-modules.md](space/scripting-modules.md), [security.md](security.md),
[vrweb-export.md](vrweb-export.md), [vrweb-tags.md](space/vrweb-tags.md).
