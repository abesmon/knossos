class_name VrwebStateSwitch
extends WorldUiSurface

## Второй, намеренно простой потребитель Replicated State: persistent bool без SAMPLE.

const SIZE := Vector2(2.4, 0.9)
const RED := Color(0.95, 0.08, 0.05)
const GREEN := Color(0.08, 0.95, 0.18)

var id := ""
var _enabled := false
var _pending_requests := {}

@onready var _button: MeshInstance3D = $Button
@onready var _label: Label3D = $Button/Label
@onready var _status: Label3D = $Status
@onready var _lamp: MeshInstance3D = $Lamp
@onready var _light: OmniLight3D = $Lamp/Light


func setup(p_id: String) -> void:
	id = p_id


func _ready() -> void:
	super()
	NetworkManager.register_replicated_schema(StateSwitchSchema.ID,
			StateSwitchSchema.definition(NetworkManager.DEFAULT_RANK))
	NetworkManager.replicated_state_received.connect(_on_replicated_state)
	NetworkManager.replicated_command_result.connect(_on_command_result)
	NetworkManager.authority_changed.connect(_on_authority_changed)
	_register_object()
	_apply_visual()


func _exit_tree() -> void:
	NetworkManager.unregister_replicated_object(id, StateSwitchSchema.ID)


func _register_object() -> void:
	if id != "":
		NetworkManager.register_replicated_object(id, StateSwitchSchema.ID, {"enabled": false})


func _on_authority_changed(_authority: int, _is_me: bool) -> void:
	_register_object()


func ui_size() -> Vector2:
	return SIZE


func ui_center_local() -> Vector3:
	return _button.position


func _ui_is_active(_uv: Vector2) -> bool:
	return true


func _ui_hint(_uv: Vector2) -> String:
	return "Переключить общий свет"


func _on_ui_accept(_uv: Vector2) -> void:
	_enabled = not _enabled # optimistic; ACK отказ вернёт canonical state
	_apply_visual()
	var request_id := NetworkManager.request_replicated_command(id, StateSwitchSchema.ID,
			StateSwitchSchema.VERSION, "toggle", {})
	if NetworkManager.in_room(): _pending_requests[request_id] = true


func _on_replicated_state(object_id: String, schema_id: String, state: Dictionary,
		_changed: Dictionary, _revision: int) -> void:
	if object_id != id or schema_id != StateSwitchSchema.ID:
		return
	_enabled = bool(state.get("enabled", false))
	_apply_visual()


func _on_command_result(request_id: int, accepted: bool, _code: String, _revision: int) -> void:
	if not _pending_requests.has(request_id):
		return
	_pending_requests.erase(request_id)
	if not accepted:
		var state := NetworkManager.replicated_state(id, StateSwitchSchema.ID)
		_enabled = bool(state.get("enabled", false))
		_apply_visual()


func _apply_visual() -> void:
	if not is_node_ready():
		return
	var color := GREEN if _enabled else RED
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = color
	lamp_mat.emission_enabled = true
	lamp_mat.emission = color
	lamp_mat.emission_energy_multiplier = 3.0
	_lamp.material_override = lamp_mat
	_light.light_color = color
	_status.text = "СВЕТ: ЗЕЛЁНЫЙ" if _enabled else "СВЕТ: КРАСНЫЙ"
	_status.modulate = color
	_label.text = "ПЕРЕКЛЮЧИТЬ"
