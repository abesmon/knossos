extends Node

## Проверяет единый визуальный класс для HTML-картинки и `<VRWebImage>`.
## Запуск: godot --headless --path . res://tests/test_image_panel.tscn

const IMAGE_PANEL_SCENE := preload("res://actors/image_panel/image_panel.tscn")

var _failed := false


func _ready() -> void:
	var html_panel := IMAGE_PANEL_SCENE.instantiate() as ImagePanel
	html_panel.setup("html")
	add_child(html_panel)
	_check(html_panel._anchor == ImagePanel.Anchor.FLOOR,
			"HTML использует общий ImagePanel с напольным якорем")
	_check(html_panel.get_node("Front").position.y > 0.0,
			"напольный якорь поднимает квад над origin")

	var doc := HtmlParser.parse("""
	<vrwml><VRWebImage src="" alt="tool" width="2"
	 transform="Transform3D(1,0,0, 0,1,0, 0,0,1, 1,2,3)" /></vrwml>
	""")
	var built: Dictionary = VrwebBuilder.build(doc)
	var holder := built.get("root") as Node3D
	add_child(holder)
	var vrweb_panel := holder.get_child(0) as ImagePanel
	_check(vrweb_panel != null, "VRWebImage материализуется тем же ImagePanel")
	if vrweb_panel != null:
		_check(vrweb_panel._anchor == ImagePanel.Anchor.CENTER,
				"VRWebImage отличается конфигурацией центрального якоря")
		_check(vrweb_panel.get_node("Front").position == Vector3.ZERO,
				"центральный якорь совмещает квад с origin")
		_check(vrweb_panel.position == Vector3(1, 2, 3),
				"общий элемент сохраняет трансформ vrweb-тега")

	html_panel.free()
	holder.free()
	get_tree().quit(1 if _failed else 0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [ok]  ", label)
	else:
		_failed = true
		printerr("  [FAIL] ", label)
