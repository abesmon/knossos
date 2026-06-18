class_name Portal
extends StaticBody3D

## Эктор-портал: физическое представление ссылки (<a href>) в 3D.
## Функция перехода (navigate/teleport/back) приходит из топологии. Игрок наводит
## луч и активирует — Portal сообщает наружу через сигнал, навигацию выполняет main.

## Сообщает наружу функцию перехода (унифицировано с inline-ссылками RichPanel).
signal activated(transition: Dictionary)

const GROUP := "portal"

## Transition из топологии: {kind:"navigate", href} | {kind:"teleport", target} | {kind:"back"}
var transition: Dictionary = {}
var label_text: String = ""

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _label: Label3D = $Label


func _ready() -> void:
	add_to_group(GROUP)
	if _label != null:
		_label.text = _short_label()
	_apply_color()


func setup(p_transition: Dictionary, p_label: String) -> void:
	transition = p_transition
	label_text = p_label


func activate() -> void:
	activated.emit(transition)


## Единый интерфейс взаимодействия по лучу игрока (точка прицела не важна).
func interact_at(_point: Vector3) -> void:
	activate()


## Портал кликабелен целиком — прицел над ним всегда «активен» (см. Player._aim_active_at).
func is_active_at(_point: Vector3) -> bool:
	return true


## Куда ведёт портал — для строки статуса (превью ссылки в углу, см. main._on_aim_target_changed).
func aim_hint_at(_point: Vector3) -> String:
	return TransitionText.describe(transition)


func get_kind() -> String:
	return transition.get("kind", "")


func _short_label() -> String:
	var prefix := ""
	match get_kind():
		"navigate": prefix = "→ "
		"teleport": prefix = "↪ "
		"back": prefix = "↩ "
	var t := label_text.strip_edges()
	if t.length() > 40:
		t = t.substr(0, 40) + "…"
	if t == "":
		t = transition.get("href", transition.get("target", "ссылка"))
	return prefix + t


func _apply_color() -> void:
	if _mesh == null:
		return
	var mat := StandardMaterial3D.new()
	# Внешние переходы — тёплый портал, внутренние якоря — холодный.
	match get_kind():
		"teleport":
			mat.albedo_color = Color(0.3, 0.8, 1.0)
			mat.emission = Color(0.1, 0.4, 0.6)
		"back":
			mat.albedo_color = Color(0.8, 0.8, 0.3)
			mat.emission = Color(0.4, 0.4, 0.1)
		_:
			mat.albedo_color = Color(1.0, 0.55, 0.2)
			mat.emission = Color(0.6, 0.25, 0.05)
	mat.emission_enabled = true
	_mesh.material_override = mat
