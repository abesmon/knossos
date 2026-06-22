# Сборка билдов (Windows / macOS)

Автоматизация экспорта проекта в релизные билды под Windows и macOS.

## TL;DR

```bash
./build.sh all      # собрать обе платформы -> build/*.zip
./build.sh mac      # только macOS
./build.sh win      # только Windows
./build.sh --clean  # удалить билды (кэш шаблонов остаётся)
```

В VSCode: **Cmd+Shift+B** → выбрать задачу (`Build: All / macOS / Windows / Clean`).
Задачи описаны в [.vscode/tasks.json](../.vscode/tasks.json).

> **Перед первой сборкой** заведите приватный конфиг с адресами сигналинга/ICE:
> `cp config/build.example.cfg config/build.private.cfg` и впишите значения. Без него билд
> соберётся, но онлайн/голос работать не будут. Подробно — [build-config.md](build-config.md).

Результат:

```
build/
  knossos-0.0.0-b7-macos.zip      # внутри knossos.app (universal, ad-hoc подпись)
  knossos-0.0.0-b7-windows.zip    # knossos.exe + knossos.pck + ffmpeg/webrtc dll
  .build_number                   # локальный счётчик билдов (не в гите)
```

`build/` целиком в `.gitignore`.

## Версия и номер билда

Имя архива и метаданные билда содержат версию вида `<semver>-b<номер>`:

- **Номер билда** — автоинкрементный счётчик в `build/.build_number`. Растёт на 1 за
  каждый запуск `build.sh` (mac и win в одной сборке делят номер), **в гит не коммитится**
  (весь `build/` в `.gitignore`). Если удалить `build/`, счёт начнётся заново.
- **Semver** — источник правды — `application/config/version` в **Настройках проекта**
  (`project.godot`). `build.sh` читает его сам. Можно разово переопределить переменной
  `VERSION` (`VERSION=1.4.0 ./build.sh all`); фолбэк `0.0.0`, если нигде не задано.

  > Godot **не** подставляет `config/version` в Info.plist/ресурс `.exe` автоматически —
  > за это отвечают per-preset поля версии, которые `build.sh` и заполняет (см. ниже).

Куда попадает номер:

| Платформа | Поле | Что это |
|-----------|------|---------|
| macOS  | `application/version` → CFBundleVersion | номер билда в `Info.plist` |
| macOS  | `application/short_version` → CFBundleShortVersionString | semver |
| Windows| `application/file_version` / `application/product_version` | `<semver>.<номер>` в ресурсе версии `.exe` |
| обе    | имя `.zip` | `knossos-<semver>-b<номер>-<платформа>.zip` |

`export_presets.cfg` закоммичен с **пустыми** полями версии. `build.sh` штампует их
временно перед экспортом и восстанавливает файл байт-в-байт после (через `trap`), так что
рабочая копия и гит остаются чистыми.

## Что делает build.sh

1. **Находит Godot** — `GODOT=...`, либо `godot` из PATH, либо свежайший
   `/Applications/Godot*.app`. Версия движка определяется автоматически.
2. **Доустанавливает export templates** нужной версии, если их нет: качает
   официальный `.tpz` (кэшируется в `build/.cache/`) и раскладывает в
   `~/Library/Application Support/Godot/export_templates/<версия>/`.
3. **Импортирует ресурсы** (`--headless --import`) — чтобы первый экспорт не
   промахнулся мимо ещё не импортированных ассетов.
4. **Экспортирует** каждый пресет через `--headless --export-release`.
5. **macOS**: подписывает `.app` ad-hoc подписью (`codesign -s -`), снимает
   карантин, проверяет подпись.
6. **Пакует** в `.zip` (macOS — через `ditto`, чтобы сохранить структуру
   бандла и фреймворки) и валидирует результат (наличие бинаря, ffmpeg-библиотек).

## Пресеты экспорта

Описаны в [export_presets.cfg](../export_presets.cfg):

| Пресет            | Платформа | Архитектура        | Особенности                          |
|-------------------|-----------|--------------------|--------------------------------------|
| `macOS`           | macOS     | universal (x86_64+arm64) | distribution_type=Testing, codesign=Disabled (подпись делает build.sh) |
| `Windows Desktop` | Windows   | x86_64             | embed_pck=false (exe + pck рядом)    |

## Нативные зависимости (GDExtension)

В билд должны попасть две GDExtension с бинарями под каждую платформу —
экспортёр Godot тащит их автоматически рядом с исполняемым файлом:

- **FFmpeg** ([addons/ffmpeg/ffmpeg.gdextension](../addons/ffmpeg/ffmpeg.gdextension)) —
  видеоплеер. Есть `win64/*.dll` и `macos/*.framework + *.dylib`.
- **WebRTC** — мультиплеер/голос. `windows ...x86_64.dll` и `macos ...universal.framework`.

`build.sh` проверяет, что `libgdffmpeg` и ffmpeg-dll/dylib реально попали в билд,
и предупреждает, если нет (иначе видео молча не заведётся).

## Требования / known issues

- **macOS подпись**: сейчас ad-hoc (`-s -`). Билд запускается локально, но при
  скачивании «из интернета» его заблокирует Gatekeeper. Для настоящей раздачи
  нужно завести Apple Developer identity + нотаризацию: в пресете `macOS`
  выставить `codesign/codesign`, `codesign/identity`, `notarization/notarization`
  и убрать ad-hoc шаг из `build.sh`.
- **Bundle identifier**: `com.abesmon.knossos` (обязателен для macOS-экспорта).
- **Кросс-сборка Windows** идёт прямо с macOS — отдельный тулчейн не нужен,
  Godot экспортирует через свои шаблоны.
- **Размер шаблонов**: `.tpz` ~1.2 ГБ, качается один раз и кэшируется.

## Куда смотреть при ошибке экспорта

`build.sh` при падении печатает хвост лога Godot. Частые причины:

- *No export template found* — не установлены шаблоны под текущую версию
  движка (скрипт ставит сам; если упал — проверь сеть/версию).
- *Invalid bundle identifier* — пустой `application/bundle_identifier` в пресете macOS.
- *...gdextension... not found for platform* — у нативной зависимости нет бинаря
  под платформу; добавить его в соответствующий `addons/.../<platform>/`.
