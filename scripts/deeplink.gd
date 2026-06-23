class_name Deeplink
extends Object

## Запуск приложения по собственной схеме-диплинку. Когда ОС открывает ссылку с
## зарегистрированной за приложением схемой (vrwebresource:// — бандл-ресурс,
## vrweblocal:// — файл ОС), она холодно стартует бинарь и передаёт целевой URL
## аргументом командной строки. Здесь мы вычленяем этот URL, чтобы main.gd открыл его
## вместо домашней страницы (см. _ready).
##
## Где регистрируются схемы за приложением:
##   - macOS: CFBundleURLTypes в Info.plist (поле application/additional_plist_content
##     пресета macOS в export_presets.cfg);
##   - Windows: ключи реестра HKCU\Software\Classes\<схема> (см. docs/deeplinks.md).
##
## Ограничение десктопа: Godot не отдаёт GDScript сигнал о deeplink в уже запущенный
## инстанс — поэтому обрабатывается только холодный старт (на каждую ссылку новый процесс).

## URL-диплинк из аргументов запуска или "" если его нет. Берём первый аргумент, который
## PageFetcher умеет открыть как страницу (собственная схема приложения либо http/https) —
## флаги движка, путь к проекту и --sandbox=… так отсекаются.
static func launch_url() -> String:
	for arg: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var url := arg.strip_edges()
		if _is_navigable(url):
			return url
	return ""


static func _is_navigable(url: String) -> bool:
	return PageFetcher.is_local(url) \
		or url.begins_with("http://") or url.begins_with("https://")
