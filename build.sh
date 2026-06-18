#!/usr/bin/env bash
#
# build.sh — собирает релизные билды knossos для Windows и macOS.
#
#   ./build.sh all      собрать обе платформы (по умолчанию)
#   ./build.sh mac       только macOS
#   ./build.sh win       только Windows
#   ./build.sh --clean   удалить каталог build/ (кэш шаблонов сохраняется)
#   ./build.sh --help
#
# Скрипт сам доустанавливает export templates нужной версии, если их нет,
# подписывает macOS .app ad-hoc подписью и пакует результат в .zip.
#
# Переопределяемые переменные окружения:
#   GODOT   — путь к бинарю Godot (по умолчанию ищется автоматически)
#
set -euo pipefail

# --- пути -------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
CACHE="$BUILD/.cache"
NAME="knossos"

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

GODOT="$(find_godot)"
VERSION_FULL="$("$GODOT" --version 2>/dev/null | tail -1)"   # напр. 4.6.3.stable.official.7d41c59c4
# каталог шаблонов = major.minor[.patch].status, как ждёт Godot
TPL_DIR_NAME="$(echo "$VERSION_FULL" | awk -F. '{
  if ($3 ~ /^[0-9]+$/) printf "%s.%s.%s.%s", $1,$2,$3,$4;
  else printf "%s.%s.%s", $1,$2,$3 }')"
TPL_DEST="$HOME/Library/Application Support/Godot/export_templates/$TPL_DIR_NAME"
TPZ_URL="https://github.com/godotengine/godot/releases/download/${TPL_DIR_NAME%.*}-${TPL_DIR_NAME##*.}/Godot_v${TPL_DIR_NAME%.*}-${TPL_DIR_NAME##*.}_export_templates.tpz"
TPZ_CACHE="$CACHE/templates-${TPL_DIR_NAME%.stable}.tpz"

# --- проверка / установка export templates ----------------------------------
ensure_templates() {
  if [[ -f "$TPL_DEST/macos.zip" && -f "$TPL_DEST/windows_release_x86_64.exe" ]]; then
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
  [[ -f "$TPL_DEST/macos.zip" ]] || die "После установки шаблоны не на месте"
  ok "Шаблоны установлены в $TPL_DEST"
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

# --- сборка macOS -----------------------------------------------------------
build_mac() {
  ensure_templates
  local dir="$BUILD/macos" app
  rm -rf "$dir"; mkdir -p "$dir"
  app="$dir/$NAME.app"
  export_preset "macOS" "$app"

  [[ -x "$app/Contents/MacOS/$NAME" ]] || die "В .app нет исполняемого файла"

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

  step "Упаковка в zip (ditto, чтобы сохранить структуру бандла)"
  rm -f "$BUILD/$NAME-macos.zip"
  ( cd "$dir" && ditto -c -k --sequesterRsrc --keepParent "$NAME.app" "$BUILD/$NAME-macos.zip" )
  ok "macOS готов: build/$NAME-macos.zip ($(du -h "$BUILD/$NAME-macos.zip" | cut -f1))"
}

# --- сборка Windows ---------------------------------------------------------
build_win() {
  ensure_templates
  local dir="$BUILD/windows" exe
  rm -rf "$dir"; mkdir -p "$dir"
  exe="$dir/$NAME.exe"
  export_preset "Windows Desktop" "$exe"

  [[ -f "$exe" ]] || die "Не создан $NAME.exe"

  # проверка, что рядом легли ffmpeg dll
  if ls "$dir"/libgdffmpeg.windows*.dll >/dev/null 2>&1 && ls "$dir"/avcodec-*.dll >/dev/null 2>&1; then
    ok "FFmpeg dll рядом с exe"
  else
    warn "Не нашёл ffmpeg dll рядом с exe — видеоплеер может не работать"
  fi

  step "Упаковка в zip"
  rm -f "$BUILD/$NAME-windows.zip"
  ( cd "$dir" && zip -qr "$BUILD/$NAME-windows.zip" . )
  ok "Windows готов: build/$NAME-windows.zip ($(du -h "$BUILD/$NAME-windows.zip" | cut -f1))"
}

# --- main -------------------------------------------------------------------
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

target="${1:-all}"
case "$target" in
  -h|--help) usage; exit 0 ;;
  --clean)   rm -rf "$BUILD/macos" "$BUILD/windows" "$BUILD/$NAME-"*.zip; ok "build/ очищен (кэш шаблонов сохранён)"; exit 0 ;;
esac

step "Godot: $GODOT ($VERSION_FULL)"
import_assets

case "$target" in
  mac|macos)        build_mac ;;
  win|windows)      build_win ;;
  all)              build_mac; build_win ;;
  *)                die "Неизвестная цель: $target (см. --help)" ;;
esac

ok "Сборка завершена."
