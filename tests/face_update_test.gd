extends Node

## Headless-тест обновления лица у ДРУГИХ клиентов (см. docs/multiplayer.md, docs/avatars.md).
## Регрессия: UserTextureApplier терял маркер после первой вставки, поэтому смена лица в
## настройках не доходила до чужих капсул (аватар дедупится — переприменение шло только
## повторным apply_identity). Здесь sender шлёт две РАЗНЫЕ карточки-лица подряд.
##
## Запуск: сигналинг на :8090, затем
##   VRWEB_SANDBOX=A godot --headless tests/face_update_test.tscn -- receiver
##   VRWEB_SANDBOX=B godot --headless tests/face_update_test.tscn -- sender

var _role := "receiver"
var _faces_seen: Array = []   # receiver: последовательность CRC пришедших лиц


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if args.size() > 0 else "receiver"
	Settings.signaling_url = "ws://localhost:8090"
	Settings.nick = _role
	Settings.online_enabled = true

	NetworkManager.identity_received.connect(_on_identity)
	NetworkManager.connect_to_server()
	NetworkManager.join_room("faceroom")

	if _role == "sender":
		await _run_sender()
	else:
		await _run_receiver()


func _on_identity(id: int, _nick: String, face: Texture2D, _uri: String) -> void:
	if _role != "receiver" or face == null:
		return
	var crc := _tex_crc(face)
	if _faces_seen.is_empty() or _faces_seen[-1] != crc:
		_faces_seen.append(crc)
		print("[receiver] FACE #%d crc=%d %dx%d" % [_faces_seen.size(), crc, face.get_width(), face.get_height()])


func _tex_crc(tex: Texture2D) -> int:
	var img := tex.get_image()
	return hash(img.get_data())


func _run_sender() -> void:
	# Ждём p2p, потом шлём лицо №1, затем меняем на №2 и рассылаем (как «Сохранить» настроек).
	var waited := 0.0
	while NetworkManager.peer_count() == 0 and waited < 8.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_write_face(Color(1, 0, 0))       # красное лицо
	NetworkManager.broadcast_identity()
	await get_tree().create_timer(1.5).timeout
	_write_face(Color(0, 0, 1))       # синее лицо — смена
	NetworkManager.broadcast_identity()
	await get_tree().create_timer(1.5).timeout
	get_tree().quit(0)


## Пишет сплошной цвет в user://face.png (256×256 RGBA) — как set_face_from_file на диск.
func _write_face(c: Color) -> void:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(c)
	img.save_png(Sandbox.resolve("user://face.png"))


func _run_receiver() -> void:
	await get_tree().create_timer(12.0).timeout
	var ok := _faces_seen.size() >= 2
	print("[receiver] RESULT distinct_faces=%d -> %s" % [_faces_seen.size(), "OK" if ok else "FAIL"])
	get_tree().quit(0 if ok else 1)
