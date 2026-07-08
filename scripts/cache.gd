class_name Cache
extends Object

## Дисковый кэш приложения в user://: байты внешних аватаров (avatar_cache) и скачанных
## видео (video_cache). Экран настроек («Прочее») показывает суммарный размер и даёт
## очистить. Все пути идут через Sandbox.resolve() — как и везде, где трогаем user://
## (см. scripts/sandbox.gd).

## Каталоги кэша (как объявлены в AvatarResolver.CACHE_DIR и VrwebVideoPlayer.CACHE_DIR).
const DIRS := ["user://avatar_cache/", "user://video_cache/"]


## Суммарный размер всех каталогов кэша в байтах.
static func total_size() -> int:
	var total := 0
	for dir in DIRS:
		total += _dir_size(Sandbox.resolve(dir))
	return total


## Удаляет содержимое всех каталогов кэша. Возвращает, сколько байт было освобождено.
static func clear() -> int:
	var freed := 0
	for dir in DIRS:
		var resolved := Sandbox.resolve(dir)
		freed += _dir_size(resolved)
		_remove_dir(resolved)
	return freed


## Открывает корневой каталог кэша в системном файловом менеджере (Finder/Проводник).
## Оба каталога кэша лежат под одним корнем user:// — открываем его (создаём, если ещё нет,
## иначе менеджеру нечего показать). Путь глобализуем: shell работает с реальным путём ФС.
static func open_dir() -> void:
	var root := Sandbox.resolve("user://")
	DirAccess.make_dir_recursive_absolute(root)
	OS.shell_show_in_file_manager(ProjectSettings.globalize_path(root))


## Человекочитаемый размер ("0 Б", "12 КБ", "3.4 МБ", "1.2 ГБ").
static func format_size(bytes: int) -> String:
	var units := ["Б", "КБ", "МБ", "ГБ"]
	var size := float(bytes)
	var i := 0
	while size >= 1024.0 and i < units.size() - 1:
		size /= 1024.0
		i += 1
	if i == 0:
		return "%d %s" % [bytes, units[0]]
	return "%.1f %s" % [size, units[i]]


## Рекурсивно суммирует размеры файлов в каталоге (вместе с .part и т.п.).
static func _dir_size(path: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var total := 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			total += _dir_size(full)
		else:
			total += _file_size(full)
		name = dir.get_next()
	dir.list_dir_end()
	return total


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return int(size)


## Рекурсивно удаляет каталог со всем содержимым.
static func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			_remove_dir(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
