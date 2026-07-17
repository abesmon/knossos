#!/usr/bin/env bash
#
# build.sh — собирает релизные билды Knossos и связанный VRWeb Maker Kit.
#
#   ./build.sh all       собрать все платформы (по умолчанию)
#   ./build.sh mac       только macOS
#   ./build.sh win       только Windows
#   ./build.sh linux     только Linux x86_64
#   ./build.sh kit       только Maker Kit (локальная быстрая проверка)
#   ./build.sh --clean   удалить каталог build/ (кэш шаблонов сохраняется)
#   ./build.sh --help
#
# Скрипт сам доустанавливает export templates нужной версии, если их нет,
# подписывает macOS .app ad-hoc подписью и пакует клиент и Maker Kit в отдельные .zip.
#
# Переопределяемые переменные окружения:
#   GODOT   — путь к бинарю Godot (по умолчанию ищется автоматически)
#   VERSION — semver; по умолчанию берётся config/version из project.godot
#   VRWEB_SKIP_MAKER_KIT=1 — проверить только platform client packaging (используется matrix CI)
#
set -euo pipefail

# --- пути -------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
CACHE="$BUILD/.cache"
NAME="knossos"
MAKER_NAME="vrweb-maker-kit"
PRESETS="$ROOT/export_presets.cfg"
MACOS_PACKAGE_FILES="$ROOT/packaging/macos"
WASM_RUNTIME_ADDON="$ROOT/addons/vrweb_wasm_runtime"
WASM_RUNTIME_LICENSE="$ROOT/native/vrweb_wasm_runtime/LICENSES.md"
BUILD_NUMBER_FILE="$BUILD/.build_number"   # локальный счётчик, не в гите (весь build/ в .gitignore)

cd "$ROOT"

# --- утилиты вывода ---------------------------------------------------------
c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yel=$'\033[1;33m'; c_rst=$'\033[0m'
step() { printf '%s==>%s %s\n' "$c_blue" "$c_rst" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_green" "$c_rst" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_yel" "$c_rst" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

# --- поиск Godot ------------------------------------------------------------
find_godot() {
  if [[ -n "${GODOT:-}" ]]; then echo "$GODOT"; return; fi
  if command -v godot >/dev/null 2>&1; then command -v godot; return; fi
  local app
  app="$(ls -d "/Applications/Godot"*.app 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$app" ]] && { echo "$app/Contents/MacOS/Godot"; return; }
  die "Не найден бинарь Godot. Установите его или задайте переменную GODOT=/path/to/godot"
}

godot_templates_dir() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Application Support/Godot/export_templates/$TPL_DIR_NAME" ;;
    Linux)  echo "${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$TPL_DIR_NAME" ;;
    MINGW*|MSYS*|CYGWIN*) echo "${APPDATA:?APPDATA is required}/Godot/export_templates/$TPL_DIR_NAME" ;;
    *)      echo "$HOME/.local/share/godot/export_templates/$TPL_DIR_NAME" ;;
  esac
}

GODOT="$(find_godot)"
VERSION_FULL="$("$GODOT" --version 2>/dev/null | tail -1)"   # напр. 4.6.3.stable.official.7d41c59c4
# каталог шаблонов = major.minor[.patch].status, как ждёт Godot
TPL_DIR_NAME="$(echo "$VERSION_FULL" | awk -F. '{
  if ($3 ~ /^[0-9]+$/) printf "%s.%s.%s.%s", $1,$2,$3,$4;
  else printf "%s.%s.%s", $1,$2,$3 }')"
TPL_DEST="$(godot_templates_dir)"
TPZ_URL="https://github.com/godotengine/godot/releases/download/${TPL_DIR_NAME%.*}-${TPL_DIR_NAME##*.}/Godot_v${TPL_DIR_NAME%.*}-${TPL_DIR_NAME##*.}_export_templates.tpz"
TPZ_CACHE="$CACHE/templates-${TPL_DIR_NAME%.stable}.tpz"

# --- проверка / установка export templates ----------------------------------
ensure_templates() {
  if [[ -f "$TPL_DEST/macos.zip" && -f "$TPL_DEST/windows_release_x86_64.exe" && -f "$TPL_DEST/linux_release.x86_64" ]]; then
    ok "Export templates $TPL_DIR_NAME на месте"
    return
  fi
  step "Export templates $TPL_DIR_NAME не найдены — устанавливаю"
  mkdir -p "$CACHE"
  if [[ ! -s "$TPZ_CACHE" ]]; then
    step "Скачиваю $TPZ_URL"
    curl -fL "$TPZ_URL" -o "$TPZ_CACHE" || die "Не удалось скачать шаблоны"
  else
    ok "Использую кэш $TPZ_CACHE"
  fi
  local tmp; tmp="$(mktemp -d)"
  unzip -q "$TPZ_CACHE" -d "$tmp" || die "Архив шаблонов повреждён"
  mkdir -p "$TPL_DEST"
  cp -f "$tmp/templates/"* "$TPL_DEST/" || die "Не удалось разложить шаблоны"
  rm -rf "$tmp"
  [[ -f "$TPL_DEST/macos.zip" && -f "$TPL_DEST/windows_release_x86_64.exe" && -f "$TPL_DEST/linux_release.x86_64" ]] || die "После установки шаблоны не на месте"
  ok "Шаблоны установлены в $TPL_DEST"
}

# --- приватный конфиг сборки ------------------------------------------------
# config/build.private.cfg хранит адреса сигналинга/ICE и учётку TURN (в .gitignore).
# Запекается в билд через include_filter; без него онлайн-функции в билде не заведутся.
check_private_config() {
  if [[ -f "$ROOT/config/build.private.cfg" ]]; then
    ok "Приватный конфиг config/build.private.cfg на месте"
  else
    warn "Нет config/build.private.cfg — билд соберётся, но онлайн/голос работать не будут."
    warn "Скопируйте config/build.example.cfg в config/build.private.cfg и впишите адреса."
  fi
}

# --- semver -----------------------------------------------------------------
# Источник правды — application/config/version из project.godot (Настройки проекта).
# Можно переопределить переменной VERSION. Фолбэк 0.0.0, если нигде не задано.
project_version() {
  sed -nE 's/^config\/version="([^"]*)".*/\1/p' "$ROOT/project.godot" | head -1
}

# --- номер билда ------------------------------------------------------------
# Локальный автоинкрементный счётчик в build/.build_number (build/ в .gitignore).
# Инкрементируется один раз за запуск — mac, win и linux в одной сборке делят номер.
next_build_number() {
  local n=0
  [[ -f "$BUILD_NUMBER_FILE" ]] && n="$(tr -dc '0-9' < "$BUILD_NUMBER_FILE")"
  [[ -z "$n" ]] && n=0
  n=$((n + 1))
  mkdir -p "$BUILD"
  printf '%s\n' "$n" > "$BUILD_NUMBER_FILE"
  printf '%s' "$n"
}

# --- штамповка версий в export_presets.cfg ----------------------------------
# export_presets.cfg в гите, поэтому правим временно: бэкап + восстановление в trap.
# macOS:   short_version -> CFBundleShortVersionString, version -> CFBundleVersion (Info.plist)
# Windows: file_version / product_version (ресурс версии .exe)
PRESETS_BACKUP=""
restore_presets() {
  if [[ -n "$PRESETS_BACKUP" && -f "$PRESETS_BACKUP" ]]; then
    cp -f "$PRESETS_BACKUP" "$PRESETS"
    rm -f "$PRESETS_BACKUP"
    PRESETS_BACKUP=""
  fi
}
set_preset_key() {  # $1 = ключ (как в cfg), $2 = значение
  local esc_key="${1//\//\\/}"
  local tmp
  tmp="$(mktemp)"
  sed -E "s/^${esc_key}=.*/${esc_key}=\"$2\"/" "$PRESETS" > "$tmp"
  mv "$tmp" "$PRESETS"
}
stamp_versions() {  # $1 = semver, $2 = build number
  PRESETS_BACKUP="$(mktemp)"
  cp "$PRESETS" "$PRESETS_BACKUP"
  trap restore_presets EXIT
  set_preset_key 'application/short_version'  "$1"        # macOS semver
  set_preset_key 'application/version'         "$2"        # macOS build number (CFBundleVersion)
  set_preset_key 'application/file_version'    "$1.$2"     # Windows
  set_preset_key 'application/product_version' "$1.$2"     # Windows
}

# --- импорт ресурсов (без него первый headless-экспорт может промахнуться) ---
import_assets() {
  step "Импорт ресурсов проекта"
  "$GODOT" --headless --import "$ROOT" >/dev/null 2>&1 || true
}

# --- экспорт одной платформы ------------------------------------------------
# $1 = имя пресета, $2 = путь вывода
export_preset() {
  local preset="$1" out="$2" log
  log="$(mktemp)"
  step "Экспорт пресета \"$preset\" -> $out"
  if ! "$GODOT" --headless --export-release "$preset" "$out" >"$log" 2>&1; then
    warn "Лог экспорта (хвост):"; tail -25 "$log" >&2
    rm -f "$log"; die "Экспорт пресета \"$preset\" завершился ошибкой"
  fi
  # Godot может вернуть 0, но вписать ошибки конфигурации в вывод
  if grep -q "Project export for preset" "$log" && grep -qi "failed" "$log"; then
    tail -25 "$log" >&2; rm -f "$log"; die "Экспорт \"$preset\" сообщил об ошибке"
  fi
  rm -f "$log"
}

require_wasm_runtime_artifact() {
  local binary="$1" platform="$2"
  [[ -f "$WASM_RUNTIME_ADDON/vrweb_wasm_runtime.gdextension" ]] || \
    die "Нет optional WASM GDExtension descriptor; соберите native runtime для $platform"
  [[ -s "$WASM_RUNTIME_ADDON/bin/$binary" ]] || \
    die "Нет WASM runtime binary $binary для $platform"
  [[ -f "$WASM_RUNTIME_ADDON/LICENSES.md" && -f "$WASM_RUNTIME_LICENSE" ]] || \
    die "Нет license metadata WASM runtime"
}

copy_wasm_runtime_license() {
  local destination="$1"
  cp "$WASM_RUNTIME_LICENSE" "$destination/VRWEB_WASM_RUNTIME_LICENSES.md"
}

# --- сборка macOS -----------------------------------------------------------
build_mac() {
  ensure_templates
  require_wasm_runtime_artifact "libvrweb_wasm_runtime.dylib" "macOS universal"
  local dir="$BUILD/macos" app
  rm -rf "$dir"; mkdir -p "$dir"
  app="$dir/$NAME.app"
  export_preset "macOS" "$app"

  [[ -x "$app/Contents/MacOS/$NAME" ]] || die "В .app нет исполняемого файла"
  find "$app/Contents" -name 'libvrweb_wasm_runtime.dylib' | grep -q . || \
    die "WASM runtime не попал в macOS app"
  copy_wasm_runtime_license "$dir"

  step "Ad-hoc подпись .app"
  # --entitlements: микрофон для голосового чата (com.apple.security.device.audio-input).
  # Без него + без NSMicrophoneUsageDescription в Info.plist macOS молча отдаёт тишину.
  codesign --force --deep --sign - --entitlements "$ROOT/macos.entitlements" "$app" >/dev/null 2>&1 || warn "codesign не отработал (apple security tools?)"
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  codesign --verify --deep "$app" 2>/dev/null && ok "Подпись валидна" || warn "Подпись не прошла verify"

  # проверка наличия ffmpeg-фреймворка в бандле
  if find "$app/Contents" -name 'libgdffmpeg*' | grep -q .; then
    ok "FFmpeg GDExtension в бандле"
  else
    warn "Не нашёл libgdffmpeg в .app — видеоплеер может не работать"
  fi

  step "Добавляю helper и инструкцию для первого запуска"
  cp "$MACOS_PACKAGE_FILES/Open Knossos.command" "$dir/"
  cp "$MACOS_PACKAGE_FILES/README - macOS.txt" "$dir/"
  chmod +x "$dir/Open Knossos.command"

  step "Упаковка в zip (ditto, чтобы сохранить структуру бандла)"
  local zip="$BUILD/$NAME-$ARCHIVE_TAG-macos.zip"
  rm -f "$zip"
  ditto -c -k --sequesterRsrc "$dir/" "$zip"
  ok "macOS готов: build/$(basename "$zip") ($(du -h "$zip" | cut -f1))"
}

# --- сборка Windows ---------------------------------------------------------
build_win() {
  ensure_templates
  require_wasm_runtime_artifact "vrweb_wasm_runtime.dll" "Windows x86_64"
  local dir="$BUILD/windows" exe
  rm -rf "$dir"; mkdir -p "$dir"
  exe="$dir/$NAME.exe"
  export_preset "Windows Desktop" "$exe"

  [[ -f "$exe" ]] || die "Не создан $NAME.exe"
  [[ -f "$dir/vrweb_wasm_runtime.dll" ]] || die "WASM runtime не попал в Windows export"
  copy_wasm_runtime_license "$dir"

  # проверка, что рядом легли ffmpeg dll
  if ls "$dir"/libgdffmpeg.windows*.dll >/dev/null 2>&1 && ls "$dir"/avcodec-*.dll >/dev/null 2>&1; then
    ok "FFmpeg dll рядом с exe"
  else
    warn "Не нашёл ffmpeg dll рядом с exe — видеоплеер может не работать"
  fi

  step "Упаковка в zip"
  local zip="$BUILD/$NAME-$ARCHIVE_TAG-windows.zip"
  rm -f "$zip"
  ( cd "$dir" && zip -qr "$zip" . )
  ok "Windows готов: build/$(basename "$zip") ($(du -h "$zip" | cut -f1))"
}

# --- сборка Linux -----------------------------------------------------------
build_linux() {
  ensure_templates
  require_wasm_runtime_artifact "libvrweb_wasm_runtime.so" "Linux x86_64"
  local dir="$BUILD/linux" bin
  rm -rf "$dir"; mkdir -p "$dir"
  bin="$dir/$NAME"
  export_preset "Linux" "$bin"

  [[ -f "$bin" ]] || die "Не создан $NAME"
  [[ -f "$dir/libvrweb_wasm_runtime.so" ]] || die "WASM runtime не попал в Linux export"
  copy_wasm_runtime_license "$dir"
  chmod +x "$bin" || true

  # проверка, что рядом легли ffmpeg .so и GDExtension-библиотеки
  if ls "$dir"/libgdffmpeg.linux*.so >/dev/null 2>&1 && ls "$dir"/libavcodec.so.* >/dev/null 2>&1; then
    ok "FFmpeg so рядом с бинарём"
  else
    warn "Не нашёл ffmpeg so рядом с бинарём — видеоплеер может не работать"
  fi
  if ls "$dir"/libwebrtc_native.linux*.so >/dev/null 2>&1 && ls "$dir"/libtwovoip.linux*.so >/dev/null 2>&1; then
    ok "WebRTC/TwoVoIP so рядом с бинарём"
  else
    warn "Не нашёл WebRTC/TwoVoIP so рядом с бинарём — мультиплеер/голос могут не работать"
  fi

  step "Упаковка в zip"
  local zip="$BUILD/$NAME-$ARCHIVE_TAG-linux-x86_64.zip"
  rm -f "$zip"
  ( cd "$dir" && zip -qr "$zip" . )
  ok "Linux готов: build/$(basename "$zip") ($(du -h "$zip" | cut -f1))"
}

# --- связанный Maker Kit artifact ------------------------------------------
# Maker Kit устанавливается независимо, но выпускается тем же release train, с теми же
# semver/build number. Корень архива одновременно является готовым starter Godot project.
build_maker_kit() {
  local stage_parent="$BUILD/maker-kit-stage"
  local stage="$stage_parent/$MAKER_NAME-$SEMVER"
  local zip="$BUILD/$MAKER_NAME-$ARCHIVE_TAG.zip"
  local catalog godot_compat

  step "Сборка связанного VRWeb Maker Kit -> $(basename "$zip")"
  verify_maker_schema
  rm -rf "$stage_parent"
  mkdir -p "$stage/addons" "$stage/schemas" "$stage/.vscode"
  cp -R "$ROOT/templates/vrweb_maker_starter/." "$stage/"
  rm -rf "$stage/.godot" "$stage/dist"
  cp -R "$ROOT/addons/vrweb_tools" "$stage/addons/vrweb_tools"
  cp "$ROOT/packaging/maker-kit/README.md" "$stage/README.md"
  cp "$ROOT/packaging/maker-kit/vscode-settings.json" "$stage/.vscode/settings.json"
  cp "$ROOT/schemas/vrweb-html-data.json" "$stage/schemas/vrweb-html-data.json"
  stage_maker_changelog "$stage/CHANGELOG.md"

  # project.godot — единственный source of truth; plugin manifest в артефакте получает тот же
  # semver. Исходный manifest также держим синхронным для установки прямо из checkout.
  sed -E "s/^version=.*/version=\"$SEMVER\"/" \
    "$stage/addons/vrweb_tools/plugin.cfg" > "$stage/addons/vrweb_tools/plugin.cfg.tmp"
  mv "$stage/addons/vrweb_tools/plugin.cfg.tmp" "$stage/addons/vrweb_tools/plugin.cfg"

  policy="$(sed -nE 's/^const POLICY_VERSION := "([^"]+)".*/\1/p' \
    "$ROOT/addons/vrweb_tools/vrweb_compatibility.gd" | head -1)"
  godot_compat="$(printf '%s' "$VERSION_FULL" | awk -F. '{printf "%s.%s.x", $1, $2}')"
  printf '{\n  "maker_kit": "%s",\n  "knossos": "%s",\n  "build": %s,\n  "godot": "%s",\n  "vrwml_policy": "%s"\n}\n' \
    "$SEMVER" "$SEMVER" "$BUILD_NUMBER" "$godot_compat" "$policy" \
    > "$stage/compatibility.json"

  # Fail closed if the distributable addon regains a compile-time Knossos dependency.
  if rg -n 'res://(scripts|actors|integrations/knossos)' "$stage/addons/vrweb_tools" \
      -g '*.gd' | rg -v '^.*##' >/dev/null; then
    die "Maker Kit addon снова содержит compile-time путь к Knossos"
  fi

  rm -f "$zip"
  ( cd "$stage_parent" && zip -qr "$zip" "$(basename "$stage")" )
  [[ -s "$zip" ]] || die "Maker Kit archive не создан"
  unzip -tq "$zip" >/dev/null || die "Maker Kit archive повреждён"

  verify_maker_kit_archive "$zip"
  ok "Maker Kit готов: build/$(basename "$zip") ($(du -h "$zip" | cut -f1))"
}

verify_maker_schema() {
  local log="$BUILD/maker-schema-check.log"
  if ! "$GODOT" --headless --quiet --log-file "$log" --path "$ROOT" \
      --script res://addons/vrweb_tools/vrweb_schema_cli.gd -- \
      --output=res://schemas/vrweb-html-data.json --check >/dev/null 2>&1; then
    tail -30 "$log" >&2
    die "VRWML HTML completion schema отстала от strict policy Maker Kit"
  fi
  ok "HTML completion schema синхронна с strict policy Maker Kit"
}

stage_maker_changelog() {
  local destination="$1"
  if [[ -f "$ROOT/CHANGELOG.md" ]]; then
    cp "$ROOT/CHANGELOG.md" "$destination"
    return
  fi

  warn "Нет CHANGELOG.md — добавляю в Maker Kit служебную заметку вместо остановки сборки"
  printf '# Changelog\n\nRelease notes for VRWeb Maker Kit %s were not included in this source checkout.\n' \
    "$SEMVER" > "$destination"
}

verify_maker_kit_archive() {
  local zip="$1" work project log
  work="$(mktemp -d "${TMPDIR:-/tmp}/vrweb-maker-release.XXXXXX")"
  log="$work/verify.log"
  unzip -q "$zip" -d "$work/unpacked"
  project="$work/unpacked/$MAKER_NAME-$SEMVER"
  mkdir -p "$work/home"

  step "Smoke-test Maker Kit из распакованного архива"
  if ! HOME="$work/home" "$GODOT" --headless --quiet --path "$project" --import \
      >"$log" 2>&1; then
    tail -30 "$log" >&2
    rm -rf "$work"
    die "Maker Kit archive не импортируется как чистый Godot project"
  fi
  if ! HOME="$work/home" "$GODOT" --headless --quiet --path "$project" \
      --script res://addons/vrweb_tools/vrweb_cli.gd -- \
      --scene=res://world.tscn --output=res://dist/world.html --profile=strict \
      --mode=exclusive --report=res://dist/report.json >>"$log" 2>&1; then
    tail -30 "$log" >&2
    rm -rf "$work"
    die "Maker Kit archive не прошёл strict CLI smoke-test"
  fi
  [[ -s "$project/dist/world.html" && -s "$project/dist/report.json" \
      && -s "$project/compatibility.json" \
      && -s "$project/schemas/vrweb-html-data.json" ]] || {
    tail -30 "$log" >&2
    rm -rf "$work"
    die "Maker Kit archive не создал ожидаемые strict build outputs"
  }
  rm -rf "$work"
  ok "Maker Kit archive работает как чистый standalone project"
}

# --- main -------------------------------------------------------------------
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

target="${1:-all}"
case "$target" in
  -h|--help) usage; exit 0 ;;
  --clean)   rm -rf "$BUILD/macos" "$BUILD/windows" "$BUILD/linux" \
               "$BUILD/maker-kit-stage" "$BUILD/$NAME-"*.zip "$BUILD/$MAKER_NAME-"*.zip; \
             ok "build/ очищен (кэш шаблонов сохранён)"; exit 0 ;;
esac

step "Godot: $GODOT ($VERSION_FULL)"
check_private_config
import_assets

# Версия билда: semver (project.godot, либо VERSION) + автоинкрементный номер билда.
SEMVER="${VERSION:-$(project_version)}"
[[ -z "$SEMVER" ]] && SEMVER="0.0.0"
BUILD_NUMBER="$(next_build_number)"
ARCHIVE_TAG="$SEMVER-b$BUILD_NUMBER"
step "Версия: $SEMVER, билд #$BUILD_NUMBER (архивы: $NAME-$ARCHIVE_TAG-*.zip)"
stamp_versions "$SEMVER" "$BUILD_NUMBER"

case "$target" in
  mac|macos)        build_mac ;;
  win|windows)      build_win ;;
  linux|lin)        build_linux ;;
  all)              build_mac; build_win; build_linux ;;
  kit|maker-kit)    : ;;
  *)                die "Неизвестная цель: $target (см. --help)" ;;
esac

if [[ "${VRWEB_SKIP_MAKER_KIT:-0}" != "1" ]]; then
  build_maker_kit
else
  ok "Maker Kit пропущен: platform-only matrix verification"
fi

ok "Сборка завершена."
