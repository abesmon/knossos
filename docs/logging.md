# Логирование

Логи пишутся в файлы в пользовательской папке (`user://`, рядом с сэндбоксом и кэшем).
Есть два уровня, они работают вместе.

## Общий движковый лог (встроенный)

Включён в `project.godot`:

```ini
[debug]
file_logging/enable_file_logging=true
file_logging/log_path="user://logs/godot.log"
file_logging/max_log_files=10
```

- Захватывает **всё**, что уходит в консоль: `print`/`printerr`, `push_error`/`push_warning`,
  ошибки движка и стектрейсы GDScript.
- Каждый запуск — свой файл (`godot<таймстамп>.log`), плюс актуальный `godot.log`; старые
  ротируются по `max_log_files`.
- Путь фиксированный и **не проходит через `Sandbox`** — значит он один на все инстансы
  (в т.ч. запущенные с `--sandbox=<id>`). Это «общий» лог.

## Сессионный лог доменного кода — синглтон `Log`

Автолоад `scripts/log.gd` (зарегистрирован первым, чтобы был доступен остальным
автолоадам). Каждое сообщение уходит сразу в два места:

1. в консоль (`print`/`printerr`) — а оттуда и в общий движковый лог выше;
2. в отдельный txt текущей сессии внутри песочницы: `Sandbox.resolve("user://logs")` →
   `<дата>_<время>_pid<NNN>.txt`. Поэтому каждый запуск/инстанс пишет в свой файл, а
   `--sandbox=<id>` уводит лог в свою папку (см. `scripts/sandbox.gd`).

Флаш после каждой строки — лог до момента падения не теряется. Старые сессионные файлы
режутся по `MAX_FILES` (20).

### Использование

```gdscript
Log.info("net", "connected to %s" % addr)
Log.warn("voice", "нет входного устройства")
Log.err("home", "сертификат не прошёл проверку")
```

Первый аргумент — тег подсистемы, второй — сообщение.
Формат строки: `ЧЧ:ММ:СС [УРОВЕНЬ] тег: сообщение`.

Теги, уже используемые в коде (держим согласованными, не плодим синонимы):

| тег | где |
| --- | --- |
| `net` | `scripts/network_manager.gd` |
| `home` | `scripts/home_server.gd` |
| `voice` | `scripts/voice/voice_manager.gd` |
| `video` | `scripts/vrweb_video_player.gd`, `scripts/vrweb_video_manager.gd` |
| `builder` | `scripts/vrweb_builder.gd` |
| `resload` | `scripts/vrweb_resource_loader.gd` |
| `extres` | `scripts/vrweb_ext_injector.gd` |
| `avatar` | `actors/avatar/*` |
| `build` | `config/build_config.gd` |
| `main`, `topology`, `layout` | отладочные сцены (`scenes/*`) |
| `log` | сам синглтон |

> Редакторный код (`addons/vrweb_tools/*`, `@tool`-скрипты) НЕ должен звать `Log` — автолоад
> не существует в контексте редактора. Там оставляем `print`/`push_warning`.

`Log.session_path()` — абсолютный путь к txt текущей сессии (например, чтобы показать
пользователю «где логи» или открыть папку).

## Куда смотреть на диске

`OS.get_user_data_dir()` + `/logs`. На macOS:
`~/Library/Application Support/Godot/app_userdata/knossos/logs/`.
