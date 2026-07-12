class_name MainUI
extends Control

signal image_file_chosen(ok: bool, path: String)

## Публичная граница экранного UI. Владельцы сцены работают с этим контрактом и не знают
## внутренние NodePath; благодаря этому представление можно инстансить в обычный Viewport,
## SubViewport или на поверхность без зависимости от scenes/main.tscn.

@onready var address: LineEdit = get_node("PanelContainer/MarginContainer/HBoxContainer/PanelContainer/HBoxContainer/address bar")
@onready var cancel: Button = $PanelContainer/MarginContainer/HBoxContainer/PanelContainer/HBoxContainer/cancel
@onready var refresh: Button = $PanelContainer/MarginContainer/HBoxContainer/PanelContainer/HBoxContainer/refresh
@onready var back_button: Button = $PanelContainer/MarginContainer/HBoxContainer/back_btn
@onready var forward_button: Button = $PanelContainer/MarginContainer/HBoxContainer/fwd_btn
@onready var settings_button: Button = $PanelContainer/MarginContainer/HBoxContainer/settings
@onready var status: Label = $StatusBar/Status
@onready var connection_dot: Panel = $StatusBar/ConnectionDot
@onready var passive_cursor: TextureRect = $PassiveCursor
@onready var active_cursor: TextureRect = $ActiveCursor
@onready var indicators: Control = $Indicators
@onready var mic_on_stack: Control = $Indicators/miconstack
@onready var mic_off_stack: Control = $Indicators/micoffstack
@onready var mic_on_ptt: CanvasItem = $Indicators/miconstack/ptt
@onready var mic_off_ptt: CanvasItem = $Indicators/micoffstack/ptt
@onready var console: SpaceConsole = $SpaceConsole
@onready var debug_panel: PanelContainer = $DebugPanel
@onready var debug_label: Label = $DebugPanel/Margin/Label
@onready var chat_root: VBoxContainer = $Chat
@onready var chat_log: RichTextLabel = $Chat/Log
@onready var chat_input: LineEdit = $Chat/Input
@onready var chat_idle_timer: Timer = $Chat/IdleTimer
@onready var settings_overlay: Control = $Settings
@onready var image_dialog: FileDialog = $ImageDialog


func _ready() -> void:
	image_dialog.file_selected.connect(func(path: String): image_file_chosen.emit(true, path))
	image_dialog.canceled.connect(func(): image_file_chosen.emit(false, ""))


func open_image_dialog(filters: PackedStringArray) -> void:
	image_dialog.filters = filters
	image_dialog.popup_centered_ratio(0.6)


func set_address(value: String) -> void:
	address.text = value


func get_address() -> String:
	return address.text.strip_edges()


func focus_address() -> void:
	address.grab_focus()


func set_navigation_available(can_back: bool, can_forward: bool) -> void:
	back_button.disabled = not can_back
	forward_button.disabled = not can_forward


func set_loading(loading: bool) -> void:
	cancel.visible = loading
	refresh.visible = not loading


func set_status(text: String) -> void:
	status.text = text


func set_cursor_active(active: bool) -> void:
	passive_cursor.visible = not active
	active_cursor.visible = active


func set_debug_visible(shown: bool) -> void:
	debug_panel.visible = shown


func set_debug_text(text: String) -> void:
	debug_label.text = text
