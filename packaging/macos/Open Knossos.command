#!/bin/sh

# Временный helper для ad-hoc сборок без Apple Developer ID/нотаризации.
# Не перемещает приложение и ничего не меняет без подтверждения пользователя.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_PATH=""

if [ "$#" -gt 0 ] && [ -d "$1" ]; then
	case "$1" in
		*.app) APP_PATH=$1 ;;
	esac
fi

for candidate in \
	"$SCRIPT_DIR/knossos.app" \
	"/Applications/knossos.app" \
	"$HOME/Applications/knossos.app"
do
	if [ -z "$APP_PATH" ] && [ -d "$candidate" ]; then
		APP_PATH=$candidate
	fi
done

if [ -z "$APP_PATH" ]; then
	APP_PATH=$(find "$SCRIPT_DIR" -maxdepth 1 -type d -iname '*knossos*.app' -print -quit 2>/dev/null)
fi

printf '\nKnossos: подготовка к первому запуску\n\n'

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
	printf 'Не удалось найти knossos.app.\n'
	printf 'Положите этот файл рядом с knossos.app и запустите снова.\n\n'
	printf 'Нажмите Enter, чтобы закрыть окно.'
	read -r _answer
	exit 1
fi

printf 'Найдено приложение:\n%s\n\n' "$APP_PATH"
printf 'Скрипт удалит только атрибут карантина macOS у этого .app.\n'
printf 'Делайте это только если архив получен из доверенного источника.\n\n'
printf 'Продолжить? [y/N]: '
read -r answer

case "$answer" in
	y|Y|д|Д|yes|YES|да|ДА) ;;
	*)
		printf '\nОтменено. Приложение не изменено.\n'
		exit 0
		;;
esac

if xattr -dr com.apple.quarantine "$APP_PATH"; then
	printf '\nГотово. Карантин снят. Запускаю Knossos…\n'
	open "$APP_PATH" || printf 'Откройте приложение вручную — карантин уже снят.\n'
	exit 0
fi

printf '\nНе удалось снять карантин. Попробуйте ручную команду из файла «README - macOS.txt».\n'
printf 'Нажмите Enter, чтобы закрыть окно.'
read -r _answer
exit 1
