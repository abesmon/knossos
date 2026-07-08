extends Node

## Синглтон логирования доменного кода (autoload «Log»). Каждое сообщение уходит СРАЗУ
## в два места:
##   • в консоль через print/printerr — а значит и в ОБЩИЙ движковый лог (см.
##     project.godot → [debug] file_logging, файл user://logs/godot.log, один на все
##     инстансы, ловит ещё и ошибки/стектрейсы движка);
##   • в отдельный txt-файл ТЕКУЩЕЙ СЕССИИ внутри песочницы (Sandbox.resolve), поэтому
##     каждый запуск — свой файл, а `--sandbox=<id>` уводит лог в свою папку.
## Подробнее — docs/logging.md.
##
## Использование:  Log.info("net", "connected to %s" % addr)
##                 Log.warn("voice", "нет входного устройства")
##                 Log.err("home", "сертификат не прошёл проверку")

const DIR := "user://logs"
## Сколько txt-файлов сессий держать в песочной папке; лишние (самые старые) режем на старте.
const MAX_FILES := 20

enum Level { INFO, WARN, ERROR }
const _LABEL := {Level.INFO: "INFO", Level.WARN: "WARN", Level.ERROR: "ERR "}

var _file: FileAccess
var _path := ""


func _ready() -> void:
	var dir := Sandbox.resolve(DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	_rotate(dir)
	_path = "%s/%s.txt" % [dir, _session_stamp()]
	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		push_error("[Log] не удалось открыть %s: %s" % [_path,
				error_string(FileAccess.get_open_error())])
	info("log", "сессия начата → %s (pid=%d)" % [_path, OS.get_process_id()])


## Абсолютный путь к файлу лога текущей сессии ("" — файл не открылся). Пригодится, чтобы
## показать пользователю «где лежат логи».
func session_path() -> String:
	return _path


func info(tag: String, msg: String) -> void:
	_write(Level.INFO, tag, msg)


func warn(tag: String, msg: String) -> void:
	_write(Level.WARN, tag, msg)


func err(tag: String, msg: String) -> void:
	_write(Level.ERROR, tag, msg)


func _write(level: int, tag: String, msg: String) -> void:
	var line := "%s [%s] %s: %s" % [_now(), _LABEL[level], tag, msg]
	# В консоль (и оттуда — в общий движковый лог). Ошибки — в stderr, чтобы были заметны.
	if level == Level.ERROR:
		printerr(line)
	else:
		print(line)
	if _file != null:
		_file.store_line(line)
		# Флашим сразу: если приложение упадёт, лог до момента падения не потеряется.
		_file.flush()


## Имена файлов начинаются с даты-времени → лексикографическая сортировка = хронологическая.
## Держим не больше MAX_FILES, удаляя самые старые (текущий ещё не создан на этом шаге).
func _rotate(dir: String) -> void:
	var logs: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".txt"):
			logs.append(f)
	logs.sort()
	while logs.size() >= MAX_FILES:
		DirAccess.remove_absolute("%s/%s" % [dir, logs.pop_front()])


func _session_stamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d_%02d-%02d-%02d_pid%d" % [
			t.year, t.month, t.day, t.hour, t.minute, t.second, OS.get_process_id()]


func _now() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%02d:%02d:%02d" % [t.hour, t.minute, t.second]
