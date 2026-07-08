class_name VrwebVideoManager
extends Node

## Связывает видео-плееры (VrwebVideoPlayer) и поверхности (VrwebVideoScreen) одной страницы
## и синхронизирует воспроизведение между клиентами поверх NetworkManager.
##
## Живёт в _world (создаётся в scenes/main.gd рядом с ImageLoader/RemotePlayersView): при
## навигации мир сносится вместе с менеджером — это и есть «выход из комнаты». Комната = URL
## страницы, поэтому player_id (из тега) совпадает у всех на одной странице.
##
## Sync-модель — shared (см. docs/video-player.md): любой может play/pause/seek; кто последним
## действовал, тот «контроллер» — он шлёт heartbeat-таймкод (~1.5 Гц), остальные дрейф-
## корректируются. Покадровый стрим невозможен — каждый клиент сам грузит тот же URL.

const HB_INTERVAL := 0.66   # период heartbeat от таймкипера, с

var _players: Dictionary = {}   # id -> VrwebVideoPlayer
var _hb_accum := 0.0


func _ready() -> void:
	NetworkManager.video_state_received.connect(_on_remote_video)


## Регистрирует плееры и привязывает к ним экраны во всём поддереве vrweb. Зовётся из
## main._rebuild_world ПОСЛЕ добавления корня vrweb в дерево. Два прохода снимают зависимость
## от порядка тегов: сначала собираем все <VRWebVideoPlayer>, потом привязываем экраны.
func scan(root: Node) -> void:
	if root == null:
		return
	_collect_players(root)
	_bind_screens(root)


func _collect_players(node: Node) -> void:
	if node is VrwebVideoPlayer:
		_register(node as VrwebVideoPlayer)
	for c in node.get_children():
		_collect_players(c)


func _register(player: VrwebVideoPlayer) -> void:
	if player.id == "":
		player.id = "player:%d" % _players.size()   # детерминированный fallback по порядку
	if _players.has(player.id):
		return
	_players[player.id] = player
	player.transport_changed.connect(_on_local_transport.bind(player.id))


func _bind_screens(node: Node) -> void:
	if node is VrwebVideoScreen:
		_bind_screen(node as VrwebVideoScreen)
	for c in node.get_children():
		_bind_screens(c)


func _bind_screen(screen: VrwebVideoScreen) -> void:
	# Явная ссылка на общий плеер.
	if screen.player_id != "" and _players.has(screen.player_id):
		screen.bind(_players[screen.player_id])
		return
	# Свой источник: создаём неявный плеер (ключ по url — одинаковый src = общий плеер).
	if screen.src != "":
		var pid := "src:" + screen.src
		if not _players.has(pid):
			var p := VrwebVideoPlayer.new()
			p.setup(pid, screen.src, screen.autoplay, screen.loop, screen.volume)
			add_child(p)
			_register(p)
		screen.bind(_players[pid])
		return
	Log.warn("video", "<VRWebVideoScreen> без player/src — не к чему привязать")


# --- Синхронизация ---

## Локальное транспортное действие (клик по экрану) — рассылаем событие всем (last-writer-wins).
func _on_local_transport(action: String, position: float, id: String) -> void:
	NetworkManager.send_video_event(id, action, position)


## Состояние от пира (явное событие play/pause/seek ИЛИ heartbeat sync_*): применяем к плееру
## с тем же id. Логику (grace-окно, дрейф-порог) держит сам плеер в apply_remote.
func _on_remote_video(_sender: int, player_id: String, action: String, position: float) -> void:
	var p: VrwebVideoPlayer = _players.get(player_id)
	if p != null:
		p.apply_remote(action, position)


## Heartbeat: таймкипер комнаты (пир с наименьшим id) непрерывно рассылает по каждому
## запущенному плееру позицию + состояние play/pause. Так зашедший позже синхронизируется
## автоматически в течение HB_INTERVAL (и при autoplay, где явного контроллера нет), а не
## только при следующем ручном play/pause. Остальные подтягиваются дрейф-коррекцией.
func _process(delta: float) -> void:
	_hb_accum += delta
	if _hb_accum < HB_INTERVAL:
		return
	_hb_accum = 0.0
	if not NetworkManager.is_timekeeper():
		return
	for id in _players:
		var p: VrwebVideoPlayer = _players[id]
		if p.has_started():
			NetworkManager.send_video_sync(id, p.position(), p.is_playing())
