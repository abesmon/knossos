# docs / client

Здесь собраны документы про конкретные фичи и особенности **клиента Knossos** — референсной
реализации VRWeb на Godot 4. Всё, что не про правила генерации пространства ([space/](../space/))
и не про сетевой слой ([network/](../network/)), а именно про то, как устроен и что умеет сам
клиент: медиа, ввод, инструменты, сборка.

Как именно Knossos реализует базовый пайплайн (URL → HTML → топология → геометрия → прогулка) —
в [implementation.md](implementation.md). Это описание Godot-клиента; независимые от движка
правила стандарта находятся в [space/](../space/README.md).

## Медиа и звук

- [audio.md](audio.md) — звуковые шины, громкости и выбор устройств вывода.
- [voice-chat.md](voice-chat.md) — голосовой чат: Opus поверх data-каналов mesh, VAD,
  джиттер-буфер, пространственный звук от капсулы.
- [video-player.md](video-player.md) — видео-плеер (как в VRChat): логический плеер → текстура
  → поверхности, синхронизация воспроизведения по сети.
- [state-switch-demo.md](state-switch-demo.md) — единое копируемое демо Luau scripting API:
  per-frame update, local/authority clocks, ресурсы, input и Distributed State.
- [remote-call-demo.md](remote-call-demo.md) — адресованные Remote Call, локальные правила
  authority/rank и реактивные панели участников инстанса.
- [gif-support.md](gif-support.md) — собственный декодер GIF на GDScript, анимация через
  `AnimatedTexture`.
- [godot-coreaudio-input-rate-bug.md](godot-coreaudio-input-rate-bug.md) — заметка о баге Godot
  на macOS: входной AudioUnit не переконфигурируется под новую частоту устройства.

## Внешний вид и ввод

- [ui.md](ui.md) — правило scene-first для UI и граница допустимого runtime-интерфейса.
- [scene-elements.md](scene-elements.md) — правила переиспользования сценовых элементов,
  наследования и конфигурации вместо параллельных однотипных акторов.
- [world-space-ui.md](world-space-ui.md) — общая база UI/медиа-поверхностей в 3D-пространстве,
  canvas-панели и выводы из VRChat/Unity.
- [controls.md](controls.md) — управление и именованные действия ввода (`InputMap`): WASD,
  взаимодействие, инструменты, голос и т.п. вместо явных клавиш/кнопок.
- [avatars.md](avatars.md) — система аватаров в стиле VRChat.
- [settings.md](settings.md) — глобальные настройки приложения (автолоад `Settings`, экран
  настроек).
- [tools.md](tools.md) — система инструментов: `PlayerTool`/`ToolManager`, слоты, запрос
  активации, системные инструменты, задел под «инструмент как эфемерный объект».
- [pencil-tool.md](pencil-tool.md) — инструменты рисования: карандаш и ластик.
- [space-console.md](space-console.md) — консоль пространства (`~`) и ручное редактирование
  VRWML-слоя.

## Ресурсы, производительность, платформа

- [local-resources.md](local-resources.md) — локальные ресурсы и офлайн/тестовый запуск HTML
  (схемы `vrweblocal://` / `vrwebresource://`).
- [performance-streaming.md](performance-streaming.md) — стриминг геометрии и ресурсов, работа
  без стопоров главного потока.
- [deeplinks.md](deeplinks.md) — диплинки (собственные схемы приложения).
- [build.md](build.md) — сборка билдов под Windows / macOS / Linux.
- [build-config.md](build-config.md) — приватный конфиг сборки.
