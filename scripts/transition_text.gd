class_name TransitionText

## Человекочитаемое «куда ведёт» для строки статуса — как превью ссылки в углу браузера.
## Формат Transition см. topology_builder.gd: {kind:"navigate", href} |
## {kind:"teleport", target} | {kind:"back"}. Пустая строка — вести некуда (не показываем).
static func describe(t) -> String:
	if t == null or typeof(t) != TYPE_DICTIONARY:
		return ""
	match t.get("kind", ""):
		"navigate":
			return "→ " + str(t.get("href", "")).strip_edges()
		"external":
			return "⮺ " + str(t.get("uri", "")).strip_edges()
		"teleport":
			return "↪ #" + str(t.get("target", "")).strip_edges()
		"back":
			return "↩ назад"
	return ""
