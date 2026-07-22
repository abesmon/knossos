extends Node

## Регрессия двухуровневой плеерной системы (docs/client/video-player.md, «Архитектура»):
## плеер без sync-атрибута синхронизируется стандартной надстройкой (регистрация в
## Replicated State), sync="none" остаётся чисто базовым (только привязка экранов), а
## set_source меняет источник на лету.
## Запуск: HOME=/tmp/knossos-godot godot --headless --path . res://tests/test_video_sync.tscn

const BASE := "vrwebresource://examples/video.html"


func _fail(msg: String) -> void:
	push_error("FAIL: " + msg)
	get_tree().quit(1)


func _ready() -> void:
	# 1. Разбор атрибута sync у тегов (локальные src — без сетевых запросов в тесте).
	var default_player = VrwebBuilder.build_element("VRWebVideoPlayer",
		{"id": "a", "src": "clip_a.mp4"}, {}, BASE)
	var manual_player = VrwebBuilder.build_element("VRWebVideoPlayer",
		{"id": "b", "src": "clip_b.mp4", "sync": "none"}, {}, BASE)
	if not (default_player is VrwebVideoPlayer) or not default_player.synced:
		_fail("плеер без sync-атрибута должен быть synced по умолчанию")
		return
	if manual_player.synced:
		_fail("sync=\"none\" должен отключать стандартную синхронизацию")
		return
	var manual_screen = VrwebBuilder.build_element("VRWebVideoScreen",
		{"src": "clip_c.mp4", "sync": "none"}, {}, BASE)
	if manual_screen.synced:
		_fail("sync=\"none\" на экране должен передаваться неявному плееру")
		return

	# 2. Менеджер: synced-плеер регистрируется в Replicated State, sync="none" — нет,
	#    но оба остаются в реестре привязки (иначе экраны не найдут плеер по id).
	var root := Node.new()
	add_child(root)
	var manager := VrwebVideoManager.new()
	root.add_child(manager)
	root.add_child(default_player)
	root.add_child(manual_player)
	root.add_child(manual_screen)
	manager.scan(root)
	if NetworkManager.replicated_state("a", VideoStateSchema.ID).is_empty():
		_fail("synced-плеер не зарегистрирован в Replicated State")
		return
	if not NetworkManager.replicated_state("b", VideoStateSchema.ID).is_empty():
		_fail("sync=\"none\" плеер не должен попадать в Replicated State")
		return
	# src экрана резолвится билдером относительно страницы — id неявного плеера тоже.
	if not NetworkManager.replicated_state("src:" + manual_screen.src, VideoStateSchema.ID).is_empty():
		_fail("неявный плеер sync=\"none\" экрана не должен попадать в Replicated State")
		return
	if not manager._players.has("b"):
		_fail("sync=\"none\" плеер должен оставаться в реестре привязки менеджера")
		return

	# 3. set_source: источник меняется на лету. Возвращаемое значение зависит от наличия
	#    FFmpeg-аддона, поэтому проверяем сам source() и что повторная смена тоже работает.
	manual_player.set_source("vrwebresource://no_such_clip.mp4")
	if manual_player.source() != "vrwebresource://no_such_clip.mp4":
		_fail("set_source должен обновлять source()")
		return
	manual_player.set_source("vrwebresource://another_clip.mp4")
	if manual_player.source() != "vrwebresource://another_clip.mp4":
		_fail("повторный set_source должен обновлять source()")
		return
	if manual_player.set_source("   "):
		_fail("set_source с пустым URL должен возвращать false")
		return

	# 4. Терминальные ошибки: целый файл на диске, но не видео → decode_failed (сигнал
	#    playback_error + last_error()). Без FFmpeg-аддона путь другой (decoder_unavailable),
	#    поэтому секция выполняется только при доступном декодере.
	if VrwebVideoPlayer.is_available():
		var bad := VrwebVideoPlayer.new()
		bad.setup("bad", "", false, false, 1.0)
		bad.synced = false
		add_child(bad)
		var got_error := [""]
		bad.playback_error.connect(func(code: String): got_error[0] = code)
		bad.set_source("vrwebresource://index.html")
		var deadline := Time.get_ticks_msec() + 8000
		while bad.last_error() == "" and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if bad.last_error() != "decode_failed" or got_error[0] != "decode_failed":
			_fail("ожидался decode_failed, получено last_error=«%s», сигнал=«%s»"
					% [bad.last_error(), got_error[0]])
			return
		bad.queue_free()

	NetworkManager.unregister_replicated_object("a", VideoStateSchema.ID)
	root.queue_free()
	get_tree().quit(0)
