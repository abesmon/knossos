extends Node

## Регрессия разметки preflight: не зависит от внутренних узлов ConfirmationDialog.

var _result: Dictionary = {}


func _ready() -> void:
	var dialog := ScriptingModulePermissionDialog.new()
	add_child(dialog)
	dialog.decisions_submitted.connect(func(decisions: Dictionary): _result = decisions)
	dialog.present([{
		"id": "demo.external",
		"resolved_url": "https://cdn.example/demo.gd",
		"hash": "ab".repeat(32),
	}], "https://world.example/page")
	var content := dialog.find_child("PermissionContent", true, false)
	var scroll := dialog.find_child("PermissionScroll", true, false)
	var has_fingerprint := false
	for label in dialog.find_children("*", "Label", true, false):
		if (label as Label).text.begins_with("SHA-256: abababababab…abababababab"):
			has_fingerprint = true
	if content == null or scroll == null or not has_fingerprint or not dialog.visible:
		push_error("FAIL: permission dialog content was not created")
		get_tree().quit(1)
		return
	dialog.call("_submit")
	if not _result.has("demo.external") or bool(_result["demo.external"].get("allow", true)):
		push_error("FAIL: default permission decision must deny")
		get_tree().quit(1)
		return
	get_tree().quit(0)
