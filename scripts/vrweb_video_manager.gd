class_name VrwebVideoManager
extends Node

## Связывает плееры и экраны страницы. Сетевой транспорт реализован через общий
## Replicated State: COMMAND/DELTA/SNAPSHOT для канонического транспорта и SAMPLE для drift.

const SCHEMA_ID := VideoStateSchema.ID
const SCHEMA_VERSION := VideoStateSchema.VERSION
const HB_INTERVAL := 0.66

var _players: Dictionary = {} # id -> VrwebVideoPlayer
var _revisions: Dictionary = {} # id -> canonical revision
var _pending_commands: Dictionary = {} # request_id -> player id (для rollback по ACK)
var _hb_accum := 0.0


func _ready() -> void:
	NetworkManager.register_replicated_schema(SCHEMA_ID,
			VideoStateSchema.definition(NetworkManager.DEFAULT_RANK))
	NetworkManager.replicated_state_received.connect(_on_replicated_state)
	NetworkManager.replicated_sample_received.connect(_on_replicated_sample)
	NetworkManager.replicated_command_result.connect(_on_command_result)
	NetworkManager.authority_changed.connect(_on_authority_changed)


func scan(root: Node) -> void:
	if root == null:
		return
	_collect_players(root)
	_bind_screens(root)


## Повторное сканирование после замены процедурного HtmlLayer. Удалённые вместе со слоем
## declarative players снимаем из registry/Replicated State; синтетические src-плееры,
## живущие детьми самого manager, сохраняем и переиспользуем новыми экранами.
func rescan(root: Node) -> void:
	var referenced := {}
	_collect_screen_player_ids(root, referenced)
	for id in _players.keys():
		var player: VrwebVideoPlayer = _players[id]
		var synthetic_needed := is_instance_valid(player) and player.get_parent() == self \
			and referenced.has(id)
		if synthetic_needed or (is_instance_valid(player) and player.get_parent() != self \
			and player.is_inside_tree()):
			continue
		_players.erase(id)
		_revisions.erase(id)
		NetworkManager.unregister_replicated_object(id, SCHEMA_ID)
		if is_instance_valid(player) and player.get_parent() == self:
			remove_child(player) # scan(root) ниже не должен немедленно зарегистрировать его снова
			player.queue_free()
	scan(root)


func _collect_screen_player_ids(node: Node, out: Dictionary) -> void:
	if node is VrwebVideoScreen:
		var screen := node as VrwebVideoScreen
		if screen.player_id != "":
			out[screen.player_id] = true
		elif screen.src != "":
			out["src:" + screen.src] = true
	for child in node.get_children():
		_collect_screen_player_ids(child, out)


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
			var request_id := NetworkManager.request_replicated_command(id, SCHEMA_ID, SCHEMA_VERSION,
					"set_playing", {"playing": action == "play", "position": position})
			if NetworkManager.in_room(): _pending_commands[request_id] = id
		"seek":
			var request_id := NetworkManager.request_replicated_command(id, SCHEMA_ID, SCHEMA_VERSION,
					"seek", {"position": position})
			if NetworkManager.in_room(): _pending_commands[request_id] = id


func _on_command_result(request_id: int, accepted: bool, code: String, _revision: int) -> void:
	if not _pending_commands.has(request_id):
		return
	var id: String = _pending_commands[request_id]
	_pending_commands.erase(request_id)
	if accepted:
		return
	Log.warn("video", "команда транспорта %s отклонена: %s" % [id, code])
	# UI применяет действие optimistic. При отказе возвращаем плеер к canonical Store.
	var state := NetworkManager.replicated_state(id, SCHEMA_ID)
	var player: VrwebVideoPlayer = _players.get(id)
	if player != null and not state.is_empty():
		player.apply_remote("play" if bool(state.get("playing", false)) else "pause",
				float(state.get("anchor_position", 0.0)))


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
