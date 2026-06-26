extends SceneTree

## Проверка нормализации URL из HTML-атрибутов.
## Запуск: godot --headless --path . --script res://tests/test_url_resolve.gd

var _failed := false


func _initialize() -> void:
	_check(
		PageFetcher.resolve_url("https://blackmagegaming.com/games/Space Invaders.gif"),
		"https://blackmagegaming.com/games/Space%20Invaders.gif")
	_check(
		PageFetcher.resolve_url("/games/Space Invaders.gif", "https://blackmagegaming.com/index.html"),
		"https://blackmagegaming.com/games/Space%20Invaders.gif")
	_check(
		PageFetcher.resolve_url("games/Space Invaders.gif", "https://blackmagegaming.com/catalog/page.html"),
		"https://blackmagegaming.com/catalog/games/Space%20Invaders.gif")
	_check(
		PageFetcher.resolve_url("//blackmagegaming.com/games/Space Invaders.gif", "https://example.com"),
		"https://blackmagegaming.com/games/Space%20Invaders.gif")
	quit(1 if _failed else 0)


func _check(actual: String, expected: String) -> void:
	if actual != expected:
		_failed = true
		push_error("resolve_url mismatch: got '%s', expected '%s'" % [actual, expected])
