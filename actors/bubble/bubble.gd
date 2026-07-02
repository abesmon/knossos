class_name Bubble
extends StaticBody3D

## Эктор-пузырь: временный портал «пользователь ушёл сюда». Первый объект эфемерного слоя
## (см. docs/ephemeral-changes.md). Полупрозрачная сфера-орб с подписью и обратным отсчётом;
## кликабелен лучом игрока как Portal (interact_at/is_active_at/aim_hint_at). По клику сообщает
## наружу переход navigate — навигацию выполняет main (тот же путь, что у порталов).
##
## Материализуется EphemeralView из записи журнала kind="bubble". Сам не хранит сетевого
## состояния: TTL ведёт авторитет (он канонично убирает запись), пузырь лишь визуально
## затухает к концу TTL по настенным часам (created_at — часы авторитета, рассинхрон NTP на
## фоне 30 c пренебрежим). См. docs/ephemeral-changes.md.

signal activated(transition: Dictionary)

const RADIUS := 0.5
## Последние секунды TTL пузырь затухает и сжимается — визуальная подсказка «вот-вот исчезнет».
const FADE_TAIL := 5.0

var url: String = ""
var label_text: String = ""
var _ttl: float = 0.0
var _created_at: float = 0.0

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _label: Label3D = $Label
var _mat: StandardMaterial3D


## Контракт EphemeralView: принять плоский объект сцены { kind, ttl, ts, props }. Позицию ставит
## вьюха (трансформ — её забота); здесь — визуал по props (url/label) и тайминг TTL.
## Зовётся и при создании, и при update. См. docs/ephemeral-changes.md.
func setup_object(object: Dictionary) -> void:
	var props: Dictionary = object.get("props", {})
	url = str(props.get("url", ""))
	label_text = str(props.get("label", ""))
	_ttl = float(object.get("ttl", 0.0))
	_created_at = float(object.get("ts", 0.0))
	if _label != null:
		_label.text = _short_label()


func _ready() -> void:
	# Слой 2 — только для клика-луча (маска луча игрока — слои 1+2); тело игрока (маска 1)
	# проходит сквозь пузырь, он не мешает передвижению. Тот же приём, что у ImagePanel/RichPanel.
	collision_layer = 2
	collision_mask = 0
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.4, 0.85, 1.0, 0.45)
	_mat.emission_enabled = true
	_mat.emission = Color(0.2, 0.6, 0.9)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh.material_override = _mat
	if _label != null:
		_label.text = _short_label()
	_refresh_visual()


func _process(_delta: float) -> void:
	_refresh_visual()


## Сколько секунд осталось жить (по часам авторитета через настенное время). 0, если TTL <= 0
## (постоянный объект — не отсчитываем) или уже истёк.
func _remaining() -> float:
	if _ttl <= 0.0:
		return 0.0
	return maxf(0.0, _ttl - (Time.get_unix_time_from_system() - _created_at))


## Затухание/сжатие в последние FADE_TAIL секунд + лёгкая пульсация и обновление отсчёта.
func _refresh_visual() -> void:
	var t := Time.get_ticks_msec() / 1000.0
	var pulse := 1.0 + 0.05 * sin(t * 3.0)
	var fade := 1.0
	if _ttl > 0.0:
		var rem := _remaining()
		fade = clampf(rem / FADE_TAIL, 0.0, 1.0)
		if _label != null:
			_label.text = "%s\n%d c" % [_short_label(), ceili(rem)]
	scale = Vector3.ONE * (0.6 + 0.4 * fade) * pulse
	if _mat != null:
		_mat.albedo_color.a = 0.45 * (0.3 + 0.7 * fade)


# --- Интерфейс взаимодействия лучом игрока (как у Portal) ---

func activate() -> void:
	activated.emit({"kind": "navigate", "href": url})


func interact_at(_point: Vector3) -> void:
	activate()


## Пузырь кликабелен целиком — прицел над ним всегда «активен».
func is_active_at(_point: Vector3) -> bool:
	return true


func aim_hint_at(_point: Vector3) -> String:
	return "↪ ушёл на %s" % url


func _short_label() -> String:
	var t := label_text.strip_edges()
	if t == "":
		t = url
	if t.length() > 40:
		t = t.substr(0, 40) + "…"
	return "→ " + t
