class_name RemotePlayer
extends Node3D

## Капсула другого игрока в комнате. Чисто визуальный актор: позицию/поворот ей задаёт
## RemotePlayersView из сетевых сообщений. Состояние приходит ~15 Гц, поэтому к цели
## интерполируем, чтобы не было рывков.

@onready var _label: Label3D = $Label
@onready var _face: MeshInstance3D = $Face
# Бабл — это UI-плашка (PanelContainer + Label со скруглённым фоном), отрендеренная через
# SubViewport на billboard-Sprite3D. Так получаем настоящий «пузырь», а не голый текст.
@onready var _bubble: Sprite3D = $Bubble
@onready var _bubble_viewport: SubViewport = $BubbleViewport
@onready var _bubble_text: Label = $BubbleViewport/Text
@onready var _bubble_timer: Timer = $BubbleTimer

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _target_pitch := 0.0
var _cur_pitch := 0.0
var _has_target := false
var _nick := "Guest"
var _face_tex: Texture2D = null
var _face_base_basis: Basis

const LERP_RATE := 12.0
## Лицо наклоняется к небу/земле слабее, чем реальная камера игрока — редуцирующий
## множитель к питчу взгляда.
const FACE_PITCH_FACTOR := 0.35
## Сколько висит речевой бабл, если не пришло новое сообщение.
const BUBBLE_SECONDS := 30.0
## Максимальная ширина текста (px): короткий ужимается под себя, длинный переносится.
const BUBBLE_MAX_WIDTH := 460.0
## Отступы текста от краёв плашки (должны совпадать с offset'ами узла Text в сцене).
const BUBBLE_PAD := Vector2(18, 10)


func _ready() -> void:
	# Ник/лицо могли задать до входа в дерево (когда @onready ещё null) — применяем тут.
	_label.text = _nick
	_face_base_basis = _face.transform.basis   # базовая ориентация квада (разворот к −Z)
	_bubble.texture = _bubble_viewport.get_texture()
	_bubble_timer.timeout.connect(_hide_bubble)
	if _face_tex != null:
		_apply_face(_face_tex)


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


## Ник можно задавать до add_child: значение запоминается и проставится в _ready.
func set_nick(nick: String) -> void:
	_nick = nick
	if _label != null:
		_label.text = nick


## Текстура лица (256×256 с альфой). Можно вызывать до add_child — запомнится до _ready.
func set_face(tex: Texture2D) -> void:
	_face_tex = tex
	if _face != null and tex != null:
		_apply_face(tex)


## Уникальный материал на экземпляр (общий из сцены нельзя править — у всех разное лицо).
func _apply_face(tex: Texture2D) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_face.set_surface_override_material(0, mat)


func set_state(pos: Vector3, yaw: float, pitch: float) -> void:
	_target_pos = pos
	_target_yaw = yaw
	_target_pitch = pitch
	if not _has_target:
		# Первый пакет — встаём сразу на место, без проезда из начала координат.
		global_position = pos
		rotation.y = yaw
		_has_target = true


func _physics_process(delta: float) -> void:
	if not _has_target:
		return
	var t := clampf(delta * LERP_RATE, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)
	# Лицо слегка наклоняется к небу/земле вслед за взглядом — поворот квада вокруг
	# локальной X поверх базовой ориентации, с редуцирующим множителем.
	_cur_pitch = lerp_angle(_cur_pitch, _target_pitch * FACE_PITCH_FACTOR, t)
	_face.transform.basis = Basis(Vector3(1, 0, 0), _cur_pitch) * _face_base_basis
