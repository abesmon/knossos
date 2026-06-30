extends SceneTree

## Юнит-тест чистого слоя штриха (StrokePath) — без сети и 3D-нод. Проверяет контракт:
## прореживание сэмплов, упрощение Douglas–Peucker, сериализацию props, хит-тест полилинии.
## Запуск:
##   godot --headless --path . --script res://tests/test_stroke_path.gd
## Выход 0 — все проверки прошли, иначе 1.

var _failed := false


func _initialize() -> void:
	_test_sample_decimation()
	_test_simplify_collinear()
	_test_simplify_keeps_corner()
	_test_build_props_serializable()
	_test_distance_to_polyline()
	quit(1 if _failed else 0)


# --- add_sample прореживает близкие точки ---
func _test_sample_decimation() -> void:
	var sp := StrokePath.new()
	_eq(sp.add_sample(Vector3.ZERO), true, "первая точка добавлена")
	# Сдвиг меньше MIN_SAMPLE_DIST — не добавляется.
	_eq(sp.add_sample(Vector3(0.001, 0, 0)), false, "дрожание на месте отброшено")
	_eq(sp.add_sample(Vector3(0.1, 0, 0)), true, "далёкая точка добавлена")
	_eq(sp.point_count(), 2, "итого две точки")
	_eq(sp.is_drawable(), true, "≥2 точек — рисуемо")


# --- simplify выкидывает почти-коллинеарные точки ---
func _test_simplify_collinear() -> void:
	var sp := StrokePath.new()
	# Прямая линия из частых точек: после упрощения должны остаться только концы.
	for i in range(11):
		sp.add_sample(Vector3(i * 0.1, 0, 0))
	_eq(sp.point_count(), 11, "до упрощения 11")
	sp.simplify()
	_eq(sp.point_count(), 2, "коллинеарные схлопнуты до концов")


# --- simplify сохраняет точку перегиба ---
func _test_simplify_keeps_corner() -> void:
	var sp := StrokePath.new()
	sp.add_sample(Vector3(0, 0, 0))
	sp.add_sample(Vector3(1, 0, 0))
	sp.add_sample(Vector3(1, 1, 0))   # явный угол — должен уцелеть
	sp.simplify()
	_eq(sp.point_count(), 3, "угол сохранён")


# --- build_props сериализуем и в пределах лимита ---
func _test_build_props_serializable() -> void:
	var sp := StrokePath.new()
	for i in range(5):
		sp.add_sample(Vector3(i * 0.1, sin(i), 0))
	var props := sp.build_props(Color(1, 0.5, 0), 0.02)
	_eq(props.has("points") and props.has("color") and props.has("width"), true, "поля props на месте")
	_eq((props["points"] as Array).size(), sp.point_count() * 3, "плоский массив = 3×точек")
	var json := JSON.stringify(props)
	_eq(json != "", "props сериализуем в JSON")
	_eq(json.length() <= SceneChanges.MAX_PROPS_BYTES, "props в пределах лимита")


# --- distance_to_polyline: хит-тест ластика ---
func _test_distance_to_polyline() -> void:
	var sp := StrokePath.new()
	sp.add_sample(Vector3(0, 0, 0))
	sp.add_sample(Vector3(1, 0, 0))
	var flat := sp.to_flat()
	# Точка прямо на середине отрезка — расстояние ~0.
	_eq(StrokePath.distance_to_polyline(flat, Vector3(0.5, 0, 0)) < 0.001, "точка на линии — расстояние ≈0")
	# Точка в стороне — расстояние ~0.5.
	_eq(absf(StrokePath.distance_to_polyline(flat, Vector3(0.5, 0.5, 0)) - 0.5) < 0.001, "сбоку — 0.5")
	# Пустой/короткий путь — INF.
	_eq(StrokePath.distance_to_polyline([0, 0, 0], Vector3.ZERO) == INF, "одна точка — нечего пересекать")


# --- helpers ---
func _eq(a, b = true, msg := "") -> void:
	# Перегрузка: _eq(cond, "msg") или _eq(actual, expected, "msg").
	if typeof(b) == TYPE_STRING:
		msg = b
		b = true
	if a != b:
		_failed = true
		push_error("FAIL: %s (получено %s, ждали %s)" % [msg, str(a), str(b)])
		print("FAIL: %s (получено %s, ждали %s)" % [msg, str(a), str(b)])
	else:
		print("ok: %s" % msg)
