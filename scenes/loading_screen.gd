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
const MAKER_SELF_TEST_ARG := "--vrweb-maker-self-test"
const MAKER_SELF_TEST_SCENE := "res://tests/test_scripting_module_fetcher.tscn"
const WASM_SELF_TEST_ARG := "--vrweb-wasm-self-test"
const WASM_SELF_TEST_SCENE := "res://tests/test_exported_wasm_runtime.tscn"
const WASM_NET_TEST_ARG := "--vrweb-wasm-net-test"
const WASM_NET_TEST_SCENE := "res://tests/net_wasm_identity_test.tscn"
## Максимум ожидания discovery. Меньше HTTP_TIMEOUT домашнего сервера (10с) сознательно:
## висящий сервер не должен держать пользователя на заставке — дождётся main.
const MAX_WAIT_SEC := 6.0

@onready var _hub: LoadingHub = $LoadingHub


func _ready() -> void:
	if WASM_NET_TEST_ARG in OS.get_cmdline_user_args():
		print("VRWEB_EXPORTED_WASM_NET_E2E start")
		get_tree().call_deferred("change_scene_to_file", WASM_NET_TEST_SCENE)
		return
	if WASM_SELF_TEST_ARG in OS.get_cmdline_user_args():
		print("VRWEB_EXPORTED_WASM_SMOKE start")
		get_tree().call_deferred("change_scene_to_file", WASM_SELF_TEST_SCENE)
		return
	if MAKER_SELF_TEST_ARG in OS.get_cmdline_user_args():
		print("VRWEB_MAKER_EXPORTED_SELF_TEST start")
		get_tree().call_deferred("change_scene_to_file", MAKER_SELF_TEST_SCENE)
		return
	_hub.open("Подключаемся к домашнему серверу")
	if HomeServer.server_url() == "":
		_hub.set_status("Загрузка")
	_wait_and_go()


func _wait_and_go() -> void:
	var deadline := Time.get_ticks_msec() + int(MAX_WAIT_SEC * 1000.0)
	while not HomeServer.refresh_done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	get_tree().change_scene_to_file(MAIN_SCENE)
