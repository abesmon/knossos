# Сборка билдов (Windows / macOS / Linux)

Автоматизация экспорта проекта в релизные билды под Windows, macOS и Linux.

## TL;DR

```bash
./build.sh all      # собрать все платформы -> build/*.zip
./build.sh mac      # только macOS
./build.sh win      # только Windows
./build.sh linux    # только Linux x86_64
./build.sh kit      # быстрая локальная сборка/проверка Maker Kit
./build.sh --clean  # удалить билды (кэш шаблонов остаётся)
```

В VSCode: **Cmd+Shift+B** → выбрать задачу (`Build: All / macOS / Windows / Linux / Clean`).
Задачи описаны в [.vscode/tasks.json](../../.vscode/tasks.json).

> **Перед первой сборкой** заведите приватный конфиг с адресами сигналинга/ICE:
> `cp config/build.example.cfg config/build.private.cfg` и впишите значения. Без него билд
> соберётся, но онлайн/голос работать не будут. Подробно — [build-config.md](build-config.md).

Результат:

```
build/
  knossos-0.0.0-b7-macos.zip      # .app + helper/инструкция для Gatekeeper
  knossos-0.0.0-b7-windows.zip    # knossos.exe + knossos.pck + ffmpeg/webrtc dll
  knossos-0.0.0-b7-linux-x86_64.zip # knossos + knossos.pck + ffmpeg/webrtc/twovoip so
  vrweb-maker-kit-0.0.0-b7.zip    # standalone Godot project + addon + starter/docs
  .build_number                   # локальный счётчик билдов (не в гите)
```

`build/` целиком в `.gitignore`.

## Версия и номер билда

Имя архива и метаданные билда содержат версию вида `<semver>-b<номер>`:

- **Номер билда** — автоинкрементный счётчик в `build/.build_number`. Растёт на 1 за
  каждый запуск `build.sh` (mac, win и linux в одной сборке делят номер), **в гит не коммитится**
  (весь `build/` в `.gitignore`). Если удалить `build/`, счёт начнётся заново.
- **Semver** — источник правды — `application/config/version` в **Настройках проекта**
  (`project.godot`). `build.sh` читает его сам. Можно разово переопределить переменной
  `VERSION` (`VERSION=1.4.0 ./build.sh all`); фолбэк `0.0.0`, если нигде не задано.

  > Godot **не** подставляет `config/version` в Info.plist/ресурс `.exe` автоматически —
  > за это отвечают per-preset поля версии, которые `build.sh` и заполняет (см. ниже).

Knossos и Maker Kit идут одним release train: platform target `mac`, `win`, `linux`
или `all` всегда дополнительно собирает Maker Kit с теми же semver и build number.
Цель `kit` нужна только для быстрой локальной итерации и не образует отдельный
публичный release lifecycle.

Куда попадает номер:

| Платформа | Поле | Что это |
|-----------|------|---------|
| macOS  | `application/version` → CFBundleVersion | номер билда в `Info.plist` |
| macOS  | `application/short_version` → CFBundleShortVersionString | semver |
| Windows| `application/file_version` / `application/product_version` | `<semver>.<номер>` в ресурсе версии `.exe` |
| Linux  | имя `.zip` | `knossos-<semver>-b<номер>-linux-x86_64.zip` |
| Maker Kit | manifest и имя `.zip` | `<semver>`, build number и compatibility matrix |
| все    | имя `.zip` | `knossos-<semver>-b<номер>-<платформа>.zip` |

`export_presets.cfg` закоммичен с **пустыми** полями версии. `build.sh` штампует их
временно перед экспортом и восстанавливает файл байт-в-байт после (через `trap`), так что
рабочая копия и гит остаются чистыми.

## Что делает build.sh

1. **Находит Godot** — `GODOT=...`, либо `godot` из PATH, либо свежайший
   `/Applications/Godot*.app`. Версия движка определяется автоматически.
2. **Доустанавливает export templates** нужной версии, если их нет: качает
   официальный `.tpz` (кэшируется в `build/.cache/`) и раскладывает в системный
   каталог Godot (`~/Library/Application Support/Godot/...` на macOS,
   `~/.local/share/godot/...` на Linux).
3. **Импортирует ресурсы** (`--headless --import`) — чтобы первый экспорт не
   промахнулся мимо ещё не импортированных ассетов.
4. **Экспортирует** каждый пресет через `--headless --export-release`.
5. **macOS**: подписывает `.app` ad-hoc подписью (`codesign -s -`), снимает
   карантин, проверяет подпись.
6. **Linux**: экспортирует x86_64-бинарь без embedded `.pck`, проверяет наличие
   `libgdffmpeg`, FFmpeg `.so`, WebRTC и TwoVoIP рядом с бинарём.
7. **Пакует** в `.zip` (macOS — через `ditto`, чтобы сохранить структуру
   бандла и фреймворки) и валидирует результат (наличие бинаря, ffmpeg-библиотек).
   В macOS ZIP дополнительно кладёт helper и инструкцию для снятия карантина.
8. **Собирает Maker Kit** как отдельный standalone Godot project: addon, starter,
   examples, README, changelog, `compatibility.json` и генерируемую HTML completion schema. Затем
   распаковывает уже готовый
   ZIP в чистый временный project и выполняет strict CLI smoke-test.

Корневой `CHANGELOG.md` — необязательный release input. Если он отсутствует в checkout,
сборка выводит предупреждение и создаёт внутри Maker Kit короткий служебный `CHANGELOG.md`;
отсутствие release notes само по себе не блокирует сборку.

Workflow `.github/workflows/maker-kit.yml` дополнительно скачивает официальный Godot 4.6.3 на
macOS, Windows и Linux и запускает `tests/run_maker_portability.py`. Harness в чистом
проекте проверяет freshness HTML schema, missing/case-sensitive asset paths, glTF dependencies
и byte-identical повторную сборку `dist/`.

## Первый запуск macOS-сборки без нотаризации

В корне macOS ZIP рядом с `knossos.app` лежат:

- `Open Knossos.command` — ищет `knossos.app` рядом с собой, в `/Applications` и
  `~/Applications`, показывает найденный путь, спрашивает подтверждение, удаляет
  только `com.apple.quarantine` рекурсивно и запускает Knossos;
- `README - macOS.txt` — короткая пользовательская инструкция и ручная команда
  с готовым путём `/Applications/knossos.app`.

Это временный fallback для ad-hoc сборок. Он не заменяет Developer ID подпись и нотаризацию.

## Пресеты экспорта

Описаны в [export_presets.cfg](../../export_presets.cfg):

| Пресет            | Платформа | Архитектура        | Особенности                          |
|-------------------|-----------|--------------------|--------------------------------------|
| `macOS`           | macOS     | universal (x86_64+arm64) | distribution_type=Testing, codesign=Disabled (подпись делает build.sh) |
| `Windows Desktop` | Windows   | x86_64             | embed_pck=false (exe + pck рядом)    |
| `Linux`           | Linux     | x86_64             | embed_pck=false (бинарь + pck рядом) |

### Maker Kit self-test экспортированной сборки

Экспортированный Knossos намеренно не разрешает command-line scene path overrides. Для узкой
CI-проверки scripting package штатный loading screen принимает user argument
`--vrweb-maker-self-test` после `--` и переключается на embedded
`tests/test_package_demo.tscn`. Тест читает заранее собранный Maker Kit `.vrmod`, проверяет
integrity/unpack/assets, компилирует module и материализует компонент теми же runtime-классами,
что обычная страница. Клиент намеренно не пересобирает package из remapped `.gdc` своего PCK:
package build относится к addon, а exported Knossos — consumer готового артефакта.
Аргумент ничего не делает без явного запуска и не открывает произвольный путь из CLI.

## Нативные зависимости (GDExtension)

В билд должны попасть GDExtension с бинарями под каждую платформу —
экспортёр Godot тащит их автоматически рядом с исполняемым файлом:

- **FFmpeg** ([addons/ffmpeg/ffmpeg.gdextension](../../addons/ffmpeg/ffmpeg.gdextension)) —
  видеоплеер. Есть `win64/*.dll`, `macos/*.framework + *.dylib` и `linux64/*.so`.
- **WebRTC** — мультиплеер/голос. Есть `windows ...x86_64.dll`,
  `macos ...universal.framework` и `linux ...x86_64.so`.
- **TwoVoIP** — голосовой кодек/захват. Есть `windows ...x86_64.dll`,
  `macos ...universal.framework` и `linux ...x86_64.so`.

`build.sh` проверяет, что `libgdffmpeg`, FFmpeg-зависимости и голосовые `.dll`/`.so`/`.dylib`
реально попали в билд, и предупреждает, если нет (иначе видео или голос молча не заведутся).

## Требования / known issues

- **macOS подпись**: сейчас ad-hoc (`-s -`). Билд запускается локально, но при
  скачивании «из интернета» его заблокирует Gatekeeper. Для настоящей раздачи
  нужно завести Apple Developer identity + нотаризацию: в пресете `macOS`
  выставить `codesign/codesign`, `codesign/identity`, `notarization/notarization`
  и убрать ad-hoc шаг из `build.sh`.
- **Bundle identifier**: `com.abesmon.knossos` (обязателен для macOS-экспорта).
- **Кросс-сборка Windows** идёт прямо с macOS — отдельный тулчейн не нужен,
  Godot экспортирует через свои шаблоны.
- **Кросс-сборка Linux x86_64** тоже идёт через export templates Godot. Отдельный Linux
  тулчейн не нужен, но запускать результат нужно на Linux с рабочими драйверами Vulkan/OpenGL
  и системными библиотеками, которые нужны Godot.
- **Размер шаблонов**: `.tpz` ~1.2 ГБ, качается один раз и кэшируется.

## Куда смотреть при ошибке экспорта

`build.sh` при падении печатает хвост лога Godot. Частые причины:

- *No export template found* — не установлены шаблоны под текущую версию
  движка (скрипт ставит сам; если упал — проверь сеть/версию).
- *Invalid bundle identifier* — пустой `application/bundle_identifier` в пресете macOS.
- *...gdextension... not found for platform* — у нативной зависимости нет бинаря
  под платформу; добавить его в соответствующий `addons/.../<platform>/`.
