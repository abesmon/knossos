class_name VrwebVideoManager
extends Node

## Связывает плееры и экраны страницы. Сетевой транспорт реализован через общий
## Replicated State: COMMAND/DELTA/SNAPSHOT для канонического транспорта и SAMPLE для drift.

const SCHEMA_ID := VideoStateSchema.ID
const SCHEMA_VERSION := VideoStateSchema.VERSION
const HB_INTERVAL := 0.66

var _players: Dictionary = {} # id -> VrwebVideoPlayer
var _revisions: Dictionary = {} # id -> canonical revision
var _hb_accum := 0.0


func _ready() -> void:
	NetworkManager.register_replicated_schema(SCHEMA_ID,
			VideoStateSchema.definition(NetworkManager.DEFAULT_RANK))
	NetworkManager.replicated_state_received.connect(_on_replicated_state)
	NetworkManager.replicated_sample_received.connect(_on_replicated_sample)
	NetworkManager.authority_changed.connect(_on_authority_changed)


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
		player.id = "player:%d" % _players.size()
	if _players.has(player.id):
		return
	_players[player.id] = player
	player.transport_changed.connect(_on_local_transport.bind(player.id))
	_register_state_object(player.id, player)


func _register_state_object(id: String, player: VrwebVideoPlayer) -> void:
	NetworkManager.register_replicated_object(id, SCHEMA_ID, {
		"playing": player.wants_playing(),
		"anchor_position": player.position(),
		"anchor_authority_msec": Time.get_ticks_msec(),
		"media_revision": 0,
	})


func _bind_screens(node: Node) -> void:
	if node is VrwebVideoScreen:
		_bind_screen(node as VrwebVideoScreen)
	for c in node.get_children():
		_bind_screens(c)


func _bind_screen(screen: VrwebVideoScreen) -> void:
	if screen.player_id != "" and _players.has(screen.player_id):
		screen.bind(_players[screen.player_id])
		return
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


func _on_local_transport(action: String, position: float, id: String) -> void:
	match action:
		"play", "pause":
			NetworkManager.request_replicated_command(id, SCHEMA_ID, SCHEMA_VERSION,
					"set_playing", {"playing": action == "play", "position": position})
		"seek":
			NetworkManager.request_replicated_command(id, SCHEMA_ID, SCHEMA_VERSION,
					"seek", {"position": position})


func _on_replicated_state(object_id: String, schema_id: String, state: Dictionary,
		_changed: Dictionary, revision: int) -> void:
	if schema_id != SCHEMA_ID:
		return
	_revisions[object_id] = revision
	var player: VrwebVideoPlayer = _players.get(object_id)
	if player != null:
		player.apply_remote("play" if bool(state.get("playing", false)) else "pause",
				float(state.get("anchor_position", 0.0)))


func _on_replicated_sample(_sender: int, object_id: String, schema_id: String, sample: Dictionary) -> void:
	if schema_id != SCHEMA_ID or int(sample.get("revision", -1)) != int(_revisions.get(object_id, 0)):
		return
	var player: VrwebVideoPlayer = _players.get(object_id)
	if player != null:
		player.apply_remote("sync_play" if bool(sample.get("playing", false)) else "sync_pause",
				float(sample.get("position", 0.0)))


func _on_authority_changed(_authority: int, _is_me: bool) -> void:
	# reset_session при смене mesh удаляет объекты, но схемы живут; восстанавливаем декларации.
	for id in _players:
		_register_state_object(id, _players[id])


func _process(delta: float) -> void:
	_hb_accum += delta
	if _hb_accum < HB_INTERVAL:
		return
	_hb_accum = 0.0
	if not NetworkManager.has_authority():
		return
	for id in _players:
		var player: VrwebVideoPlayer = _players[id]
		if player.has_started():
			NetworkManager.send_replicated_sample(id, SCHEMA_ID, SCHEMA_VERSION, {
				"position": player.position(),
				"playing": player.is_playing(),
				"revision": int(_revisions.get(id, 0)),
			})
