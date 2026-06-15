class_name Sandbox
extends Object

## Dev-песочница для изоляции user://. Если задан sandbox_id (флаг `--sandbox=<id>` в cmdline
## ИЛИ переменная окружения VRWEB_SANDBOX), ВСЕ user://-файлы уходят под `user://<id>/…` —
## так несколько инстансов на одной машине перестают делить настройки/лицо/кэш (см.
## docs/multiplayer.md → Проверка). Без id (обычный запуск) — полный no-op.
##
## Использовать ВЕЗДЕ, где трогаем user://:  Sandbox.resolve("user://settings.cfg").
## id читается один раз и кэшируется; разрешён только безопасный токен [A-Za-z0-9_-] (без
## слешей — чтобы нельзя было вылезти из user://).

const ARG_PREFIX := "--sandbox="
const ENV_VAR := "VRWEB_SANDBOX"
const SCHEME := "user://"

static var _id := ""
static var _resolved := false
static var _root_ready := false


## Идентификатор песочницы ("" — не задан). Источник: сначала cmdline (`--sandbox=<id>`,
## в т.ч. после `--`), затем env VRWEB_SANDBOX. Кэшируется.
static func id() -> String:
	if not _resolved:
		_resolved = true
		_id = _sanitize(_read_id())
	return _id


## Переводит user://-путь под песочницу. Не-user:// и пустой id — возвращает как есть.
static func resolve(path: String) -> String:
	var sid := id()
	if sid == "" or not path.begins_with(SCHEME):
		return path
	_ensure_root(sid)
	return SCHEME + sid + "/" + path.substr(SCHEME.length())


static func _read_id() -> String:
	# Сначала пользовательские аргументы (после `--`), потом все аргументы движка.
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(ARG_PREFIX):
			return arg.substr(ARG_PREFIX.length())
	return OS.get_environment(ENV_VAR)


## Оставляет только [A-Za-z0-9_-] — режет слеши/точки/пробелы, чтобы id был безопасным
## именем папки и не выводил путь за пределы user://.
static func _sanitize(raw: String) -> String:
	var out := ""
	for c in raw.strip_edges():
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
				or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
	return out


static func _ensure_root(sid: String) -> void:
	if _root_ready:
		return
	_root_ready = true
	DirAccess.make_dir_recursive_absolute(SCHEME + sid)
	print("[VRWeb] Sandbox user:// → %s%s/" % [SCHEME, sid])
