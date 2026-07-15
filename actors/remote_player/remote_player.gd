class_name RemotePlayer
extends Node3D

## Другой игрок в комнате. Тело-визуал делегировано AvatarHost (сменяемый аватар), а
## неймплейт-бабл и речевой бабл — UI поверх любого аватара — остаются на корне. Позицию/поворот
## и параметры аватара задаёт RemotePlayersView из сетевых сообщений. Состояние приходит
## ~15 Гц, поэтому к цели интерполируем (тело), а аватар сам сглаживает свои параметры.

@onready var _host: AvatarHost = $AvatarHost
# View-bubble над головой: display_name крупно + (при наличии) подтверждённый nick@domain с
# иконкой статуса. См. actors/nameplate/, docs/home-server.md.
@onready var _nameplate: Nameplate = $Nameplate
# Иконка над неймплейтом: законность аватара не подтверждена (warning) или отклонена (err) —
# нет манифеста прав / личность пира пока невозможно верифицировать. См. docs/avatars.md.
@onready var _warn: Sprite3D = $AvatarWarning
# Иконка «нет связи» над неймплейтом (оранжевый no-connection): p2p-канал оборвался или пир
# в grace-периоде «призрака» — ждём переподключения. См. docs/multiplayer.md.
@onready var _conn: Sprite3D = $ConnectionLost
# Бабл — это UI-плашка (PanelContainer + Label со скруглённым фоном), отрендеренная через
# SubViewport на billboard-Sprite3D. Так получаем настоящий «пузырь», а не голый текст.
@onready var _bubble: Sprite3D = $Bubble
@onready var _bubble_viewport: SubViewport = $BubbleViewport
@onready var _bubble_text: Label = $BubbleViewport/Text
@onready var _bubble_timer: Timer = $BubbleTimer

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _has_target := false
var _nick := "Guest"
var _verified_address := ""
var _face_tex: Texture2D = null
# Связь с пиром потеряна (обрыв p2p / призрак) — иконка no-connection + серый ник.
var _conn_lost := false
# Пространственное воспроизведение голоса пира. Создаётся лениво на первом кадре, чтобы
# у молчащих капсул не висел лишний AudioStreamPlayer3D с открытым генератором.
var _voice: VoicePlayback = null

const LERP_RATE := 12.0
## Цвет неймплейта, пока пир говорит (подсветка активности).
const SPEAKING_COLOR := Color(0.5, 1.0, 0.6)
## Цвет неймплейта при потере связи с пиром (см. set_connection_lost).
const LOST_COLOR := Color(0.65, 0.65, 0.65)
## Сколько висит речевой бабл, если не пришло новое сообщение.
const BUBBLE_SECONDS := 30.0
## Максимальная ширина текста (px): короткий ужимается под себя, длинный переносится.
const BUBBLE_MAX_WIDTH := 460.0
## Отступы текста от краёв плашки (должны совпадать с offset'ами узла Text в сцене).
const BUBBLE_PAD := Vector2(18, 10)


func _ready() -> void:
	# Ник/адрес/лицо могли задать до входа в дерево (когда @onready ещё null) — применяем тут.
	_nameplate.set_display_name(_nick)
	_nameplate.set_verified_identity(_verified_address, StatusIcons.Status.VERIFIED)
	_host.apply_identity(_nick, _face_tex)
	_conn.visible = _conn_lost
	_bubble.texture = _bubble_viewport.get_texture()
	_bubble_timer.timeout.connect(_hide_bubble)
	_refresh_name_color()
	_position_overlays()


## Ставит неймплейт-бабл, иконку легитимности и речевой бабл над головой текущего аватара
## (у разных аватаров разный рост).
func _position_overlays() -> void:
	var h := _host.current_nameplate_height()
	_nameplate.position.y = h
	if _warn != null:
		_warn.position.y = h + 0.35   # над неймплейтом
	if _conn != null:
		_conn.position.y = h + 0.35   # там же; разводит offset в плоскости билборда
	_bubble.position.y = h + 0.5


## Сменить аватар капсулы (см. AvatarHost). После смены поправляем высоту оверлеев.
func set_avatar(scene: PackedScene) -> void:
	_host.set_avatar(scene)
	_position_overlays()


## Вердикт легитимности аватара (см. AvatarManifest). ALLOWED — иконки нет; UNCONFIRMED —
## «warning» (законность не подтверждена); DENIED — «err». DENIED (скрытие аватара) появится
## со слоем идентичности; пока сюда приходит только ALLOWED/UNCONFIRMED.
func set_avatar_legitimacy(verdict: AvatarManifest.Verdict) -> void:
	if _warn == null:
		return
	match verdict:
		AvatarManifest.Verdict.ALLOWED:
			_warn.visible = false
		AvatarManifest.Verdict.DENIED:
			_warn.texture = StatusIcons.texture(StatusIcons.Status.ERROR)
			_warn.modulate = StatusIcons.color(StatusIcons.Status.ERROR)
			_warn.visible = true
		_:
			_warn.texture = StatusIcons.texture(StatusIcons.Status.WARNING)
			_warn.modulate = StatusIcons.color(StatusIcons.Status.WARNING)
			_warn.visible = true


## Показать речевой бабл с сообщением чата на BUBBLE_SECONDS секунд. Новое сообщение
## заменяет текст и перезапускает таймер.
func set_chat(text: String) -> void:
	if _bubble == null:
		return
	_bubble_text.text = text
	# Включаем рендер вьюпорта только пока бабл виден (молчащие капсулы не рендерим).
	_bubble_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_bubble.visible = true
	_bubble_timer.start(BUBBLE_SECONDS)
	_layout_bubble(text)


## Подгоняет вьюпорт под текст. Ширина — по тексту, но не шире максимума (дальше перенос);
## высоту блока меряем точно через get_multiline_string_size. Фон (Panel) и текст (Label)
## привязаны к краям вьюпорта (anchors full-rect), поэтому просто задаём размер вьюпорта —
## без контейнеров, которые завышают высоту автопереносного Label.
func _layout_bubble(text: String) -> void:
	var font := _bubble_text.get_theme_font("font")
	var fsize := _bubble_text.get_theme_font_size("font_size")
	var one_line := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var width_text := minf(one_line, BUBBLE_MAX_WIDTH)
	var block := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width_text, fsize)
	_bubble_viewport.size = Vector2i(
		ceili(width_text + 2.0 * BUBBLE_PAD.x),
		ceili(block.y + 2.0 * BUBBLE_PAD.y))


func _hide_bubble() -> void:
	_bubble.visible = false
	_bubble_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Отображаемое имя (display_name). Можно задавать до add_child: значение запоминается и
## проставится в _ready.
func set_nick(nick: String) -> void:
	_nick = nick
	if _nameplate != null:
		_nameplate.set_display_name(nick)
	if _host != null:
		_host.apply_identity(nick, _face_tex)


## Криптографически подтверждённый федеративный адрес (nick@domain) — вторая строка неймплейта
## с галочкой. "" — аноним/не проверен (строки нет). См. docs/home-server.md.
func set_verified_address(address: String) -> void:
	_verified_address = address
	if _nameplate != null:
		_nameplate.set_verified_identity(address, StatusIcons.Status.VERIFIED)


## Текстура лица (256×256 с альфой). Можно вызывать до add_child — запомнится до _ready.
func set_face(tex: Texture2D) -> void:
	_face_tex = tex
	if _host != null and tex != null:
		_host.apply_identity(_nick, tex)


## Принять голосовой кадр от пира — лениво поднимаем воспроизведение и шлём в него.
## Подсветку неймплейта вешаем на сигнал «говорит» из VoicePlayback.
func push_voice(payload: PackedByteArray) -> void:
	if _voice == null:
		_voice = VoicePlayback.new()
		_voice.position.y = 1.5   # «рот» примерно на высоте головы капсулы
		_voice.speaking_changed.connect(_on_speaking_changed)
		add_child(_voice)
	_voice.push(payload)


## Связь с пиром потеряна/восстановлена: иконка no-connection над неймплейтом (оранжевая) и
## серый ник. Ставится при обрыве p2p-канала и на время grace-периода «призрака»; снимается
## при переподключении (RemotePlayersView). См. docs/multiplayer.md.
func set_connection_lost(lost: bool) -> void:
	_conn_lost = lost
	if _conn != null:
		_conn.visible = lost
	_refresh_name_color()


func _on_speaking_changed(speaking: bool) -> void:
	_refresh_name_color(speaking)


## Цвет ника: серый при потере связи, зелёный пока говорит, иначе белый.
func _refresh_name_color(speaking: bool = false) -> void:
	if _nameplate == null:
		return
	if _conn_lost:
		_nameplate.set_name_color(LOST_COLOR)
	else:
		_nameplate.set_name_color(SPEAKING_COLOR if speaking else Color.WHITE)


## Состояние от пира: позиция, поворот корпуса (yaw) и словарь параметров аватара.
func set_state(pos: Vector3, yaw: float, params: Dictionary) -> void:
	_target_pos = pos
	_target_yaw = yaw
	if not _has_target:
		# Первый пакет — встаём сразу на место, без проезда из начала координат.
		global_position = pos
		rotation.y = yaw
		_has_target = true
	if _host != null:
		# Local-context параметры принадлежат этому клиенту: игнорируем их даже от старого или
		# недоверенного отправителя, который всё ещё положил их в snapshot.
		_host.apply_params(AvatarParams.network_snapshot(params))
		_host.set_param(AvatarParams.IS_LOCAL, false)


func _physics_process(delta: float) -> void:
	# Громкость голоса — параметр аватара: считаем её из реально пришедшего звука (как и
	# подсветку неймплейта), а не гоняем по сети. Молчащая капсула без _voice держит VOICE=0.
	if _voice != null:
		_host.set_param(AvatarParams.VOICE, _voice.current_level())
	if not _has_target:
		return
	var t := clampf(delta * LERP_RATE, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)
