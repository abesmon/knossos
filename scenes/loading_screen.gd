extends Node

## Стартовый экран загрузки (main scene проекта). Даёт асинхронной инициализации завершиться
## ДО входа в main — сейчас это discovery домашнего сервера (HomeServer.refresh): он может
## анонсировать адрес сигналинга, и подключаться надо сразу к нему, а не к дефолту сборки
## с последующим переподключением. Место для будущих шагов загрузки (прогрев кэшей и т.п.).
##
## Ожидание ограничено MAX_WAIT_SEC: сервер недоступен/медленный — уходим в main как есть,
## это не блокер (main слушает HomeServer.refresh_finished и переподключится честно, когда
## discovery всё-таки завершится). Тесты (tests/*.gd) грузят свои сцены напрямую — экран
## их не касается.

const MAIN_SCENE := "res://scenes/main.tscn"
## Максимум ожидания discovery. Меньше HTTP_TIMEOUT домашнего сервера (10с) сознательно:
## висящий сервер не должен держать пользователя на заставке — дождётся main.
const MAX_WAIT_SEC := 6.0

@onready var _hub: LoadingHub = $LoadingHub


func _ready() -> void:
	_hub.open("Подключаемся к домашнему серверу")
	if HomeServer.server_url() == "":
		_hub.set_status("Загрузка")
	_wait_and_go()


func _wait_and_go() -> void:
	var deadline := Time.get_ticks_msec() + int(MAX_WAIT_SEC * 1000.0)
	while not HomeServer.refresh_done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	get_tree().change_scene_to_file(MAIN_SCENE)
