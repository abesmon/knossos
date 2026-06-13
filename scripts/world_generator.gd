class_name WorldGenerator
extends RefCounted

## Фаза геометрии (F) из docs/html-to-3d-topology.md. Потребляет ТОЛЬКО артефакт
## топологии (Dictionary) + seed и сочиняет конкретное навигируемое пространство:
## координаты, полы/стены, проходы, расстановку объектов. Топология координат не знает.
##
## Раскладка — «tidy tree»: каждое поддерево занимает непересекающуюся полосу по X,
## глубина дерева -> ось Z. Комнаты — полы с бортиками; связи родитель→ребёнок —
## коридоры-мостики; ссылки — порталы; контент — таблички/картины/экраны.

const PORTAL_SCENE := preload("res://actors/portal/portal.tscn")
const RICH_PANEL_SCENE := preload("res://actors/rich_panel/rich_panel.tscn")

const ROOM_SIZE := 9.0          # сторона комнаты (X и Z), м
const ROOM_GAP := 7.0           # зазор между соседними поддеревьями по X
const DEPTH_SPACING := 16.0     # расстояние между уровнями по Z
const WALL_HEIGHT := 3.2
const WALL_THICK := 0.3
const CORRIDOR_WIDTH := 3.0

# --- Масштаб: единый перевод CSS-пикселей страницы в метры мира ---
# База — кегль основного текста (typography.base_px). Одна строка базового текста
# занимает M_PER_BASE_LINE метров; всё остальное (заголовки, картинки, таблицы)
# размеряется тем же коэффициентом _m_per_px, то есть пропорционально этому тексту.
const M_PER_BASE_LINE := 0.18   # мир-высота глифа базового текста, м
const LABEL_PIXEL_SIZE := 0.006 # Label3D: 1px кегля Godot -> м (как было)
const PANEL_WIDTH_M := 2.2      # ширина текстовой таблички-Label3D, м
const IMAGE_FALLBACK_EM := 20.0 # ширина картинки без размеров в HTML, в «эмах» базы
# Относительные кегли заголовков (дефолты браузера, h1..h6) в долях базового текста.
const HEADING_EM := {1: 2.0, 2: 1.5, 3: 1.17, 4: 1.0, 5: 0.83, 6: 0.67}

var _space: Dictionary
var _rooms: Dictionary
var _seed: int
var _rng := RandomNumberGenerator.new()
var _positions: Dictionary = {}   # roomId -> Vector3 (центр пола)
var _object_room: Dictionary = {} # objectId -> roomId (для резолва якорей на объекты)
var _measure_cache: Dictionary = {}
var _base_url: String = ""        # для резолва относительных src картинок
var _image_loader: ImageLoader = null  # прогрессивная подгрузка текстур (может быть null)
var _base_px := 16.0              # базовый кегль текста страницы (typography.base_px)
var _m_per_px := M_PER_BASE_LINE / 16.0  # масштаб CSS-пиксель -> метр

# Результат генерации, нужный main: где ставить игрока, и таблица меток.
var spawn_point := Vector3.ZERO
var label_positions: Dictionary = {}   # anchorId -> Vector3


## Строит геометрию в parent (Node3D). Возвращает себя для доступа к spawn_point.
## base_url + image_loader — для прогрессивной подгрузки картинок (могут быть пустыми).
static func generate(space: Dictionary, parent: Node3D, seed_value: int, on_transition: Callable,
		base_url: String = "", image_loader: ImageLoader = null) -> WorldGenerator:
	var g := WorldGenerator.new()
	g._base_url = base_url
	g._image_loader = image_loader
	g._build(space, parent, seed_value, on_transition)
	return g


func _build(space: Dictionary, parent: Node3D, seed_value: int, on_transition: Callable) -> void:
	_space = space
	_rooms = space.get("rooms", {})
	_seed = seed_value
	_rng.seed = seed_value
	# Масштаб мира из типографики страницы: базовый кегль -> метры на пиксель.
	_base_px = float(space.get("typography", {}).get("base_px", 16.0))
	if _base_px <= 0.0:
		_base_px = 16.0
	_m_per_px = M_PER_BASE_LINE / _base_px
	var root_id: int = space.get("root", -1)
	if root_id == -1 or not _rooms.has(root_id):
		return

	_layout(root_id, 0.0, 0)
	for id in _rooms.keys():
		for obj in _rooms[id]["objects"]:
			_object_room[obj["id"]] = id
		_build_room(id, parent, on_transition)
	_build_corridors(root_id, parent)
	_resolve_labels(space.get("labels", {}))
	_build_atmosphere(parent, root_id)

	spawn_point = _positions.get(root_id, Vector3.ZERO) + Vector3(0, 1.0, ROOM_SIZE * 0.3)


# --- Раскладка (tidy tree) ---

func _measure(id: int) -> float:
	if _measure_cache.has(id):
		return _measure_cache[id]
	var children: Array = _rooms[id]["children"]
	var own := ROOM_SIZE + ROOM_GAP
	if children.is_empty():
		_measure_cache[id] = own
		return own
	var sum := 0.0
	for c in children:
		sum += _measure(c)
	var w: float = max(own, sum)
	_measure_cache[id] = w
	return w


func _layout(id: int, x_center: float, depth: int) -> void:
	_positions[id] = Vector3(x_center, 0.0, depth * DEPTH_SPACING)
	var children: Array = _rooms[id]["children"]
	if children.is_empty():
		return
	var total := 0.0
	for c in children:
		total += _measure(c)
	var cursor := x_center - total * 0.5
	for c in children:
		var w := _measure(c)
		_layout(c, cursor + w * 0.5, depth + 1)
		cursor += w


# --- Атмосфера (свет + небо), процедурно из данных страницы ---

## Палитра берётся из CSS-фонов страницы; «насыщенность» контента задаёт высоту солнца;
## seed (= hash URL) определяет азимут и оттенок там, где у страницы нет своих цветов.
## Всё детерминировано: один и тот же сайт всегда даёт одно и то же небо.
func _build_atmosphere(parent: Node3D, root_id: int) -> void:
	var palette := _collect_bg_colors()

	# Базовый тон неба: средний цвет фонов страницы либо производный от seed.
	var base_hue: float
	var base_sat: float
	if palette.is_empty():
		_rng.seed = _seed
		base_hue = _rng.randf()
		base_sat = 0.35
	else:
		var avg := Color(0, 0, 0)
		for c in palette:
			avg += c
		avg /= float(palette.size())
		base_hue = avg.h
		base_sat = clampf(avg.s + 0.1, 0.2, 0.7)

	# «Богатство» страницы (число объектов в корне) -> высота солнца: пустая страница —
	# низкое закатное солнце, насыщенная — высокий день.
	var weight := float(_rooms[root_id]["hints"].get("weight", 0))
	var richness := clampf(weight / 30.0, 0.0, 1.0)
	var elevation := deg_to_rad(lerpf(8.0, 65.0, richness))

	# Азимут — от seed, чтобы тени у разных сайтов падали по-разному.
	_rng.seed = _seed ^ 0x9E3779B9
	var azimuth := deg_to_rad(_rng.randf() * 360.0)

	# Чем ниже солнце, тем теплее и краснее свет (закат).
	var warmth := 1.0 - sin(elevation)
	var sun_color := Color.from_hsv(lerpf(base_hue, 0.07, warmth * 0.8), 0.35 + warmth * 0.3, 1.0)

	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color.from_hsv(base_hue, base_sat, 0.55)
	sky.sky_horizon_color = Color.from_hsv(lerpf(base_hue, 0.07, warmth), base_sat * 0.6, lerpf(0.95, 0.7, warmth))
	sky.ground_bottom_color = Color.from_hsv(base_hue, base_sat * 0.5, 0.12)
	sky.ground_horizon_color = sky.sky_horizon_color.darkened(0.3)
	sky.sun_angle_max = 12.0

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_res := Sky.new()
	sky_res.sky_material = sky
	env.sky = sky_res
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = lerpf(0.5, 0.9, richness)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var we := WorldEnvironment.new()
	we.name = "Atmosphere"
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	# Высота (X) + азимут (Y).
	sun.rotation = Vector3(-elevation, azimuth, 0.0)
	sun.light_color = sun_color
	sun.light_energy = lerpf(0.7, 1.3, sin(elevation))
	sun.shadow_enabled = true
	parent.add_child(sun)


func _collect_bg_colors() -> Array:
	var colors: Array = []
	for id in _rooms.keys():
		var css: Dictionary = _rooms[id]["hints"].get("css", {})
		if css.has("bg"):
			var c = _parse_css_color(css["bg"])
			if c != null:
				colors.append(c)
	return colors


# --- Геометрия комнаты ---

func _build_room(id: int, parent: Node3D, on_transition: Callable) -> void:
	var room: Dictionary = _rooms[id]
	var pos: Vector3 = _positions[id]
	var holder := Node3D.new()
	holder.name = "Room_%d" % id
	holder.position = pos
	parent.add_child(holder)

	var is_connector: bool = room["kind"] == "connector"
	# Пол.
	var floor_color := _room_color(room, is_connector)
	_add_box(holder, Vector3(ROOM_SIZE, 0.4, ROOM_SIZE), Vector3(0, -0.2, 0), floor_color, true)

	# Бортики-стены на сторонах БЕЗ связи: -Z к родителю, +Z к детям остаются открыты.
	var has_parent := _has_parent(id)
	var has_children: bool = not room["children"].is_empty()
	var wall_color := floor_color.lightened(0.1)
	_add_wall_x(holder, -ROOM_SIZE * 0.5, wall_color)    # левая (-X)
	_add_wall_x(holder, ROOM_SIZE * 0.5, wall_color)     # правая (+X)
	if not has_parent:
		_add_wall_z(holder, -ROOM_SIZE * 0.5, wall_color)  # задняя (-Z)
	if not has_children:
		_add_wall_z(holder, ROOM_SIZE * 0.5, wall_color)   # передняя (+Z)

	_place_objects(room, holder, on_transition)


func _place_objects(room: Dictionary, holder: Node3D, on_transition: Callable) -> void:
	var objects: Array = room["objects"]
	if objects.is_empty():
		return
	# Расставляем объекты по периметру комнаты, лицом к центру.
	var inset := ROOM_SIZE * 0.5 - 1.2
	var slots := _perimeter_slots(objects.size(), inset)
	for i in objects.size():
		var obj: Dictionary = objects[i]
		var slot: Dictionary = slots[i]
		_build_object(obj, holder, slot["pos"], slot["yaw"], on_transition)


func _build_object(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> void:
	var fn = obj.get("function", null)
	var is_link: bool = fn != null and typeof(fn) == TYPE_DICTIONARY

	# Картинка (в т.ч. картинка-ссылка) -> реальная текстура на квад, подгружается прогрессивно.
	# Несёт функцию перехода прямо в панели, поэтому отдельным порталом её НЕ оборачиваем.
	if obj.get("type", "") == "image":
		_build_image_panel(obj, holder, local_pos, yaw, fn if is_link else null, on_transition)
		return

	# Объект с функцией перехода — это портал (поверх любого типа, §3 топологии).
	if is_link:
		var portal: Portal = PORTAL_SCENE.instantiate()
		portal.setup(fn, _obj_text(obj))
		holder.add_child(portal)
		portal.position = local_pos
		portal.rotation.y = yaw
		if on_transition.is_valid():
			portal.activated.connect(on_transition)
		return

	# Абзац -> единый RichPanel, если есть inline-ссылки или текст длинный (иначе обрежется).
	var runs: Array = obj.get("content", {}).get("runs", [])
	if obj.get("type", "") == "text" and not runs.is_empty():
		if _runs_have_links(runs) or _obj_text(obj).length() > 200:
			_build_rich_panel(runs, holder, local_pos, yaw, on_transition)
			return

	# Кегль каждого типа выражен в CSS-пикселях относительно базового текста страницы;
	# в метры его переводит общий масштаб (_godot_font / _px_to_m).
	match obj.get("type", "text"):
		"heading":
			var level: int = int(obj.get("content", {}).get("level", 2))
			var px: float = _base_px * float(HEADING_EM.get(level, 1.0))
			_build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.95, 0.85, 0.4), px)
		"media":
			_build_panel(holder, local_pos, yaw, "▷ " + _obj_text(obj),
				Color(0.25, 0.25, 0.3), _base_px)
		"button", "input":
			_build_panel(holder, local_pos, yaw, "▢ " + _obj_text(obj),
				Color(0.5, 0.7, 0.5), _base_px)
		"list":
			# Со ссылками внутри -> кликабельный RichPanel; иначе дешёвый Label3D.
			if _list_has_links(obj):
				_build_rich_panel(_list_runs(obj), holder, local_pos, yaw, on_transition)
			else:
				_build_panel(holder, local_pos, yaw, _list_text(obj),
					Color(0.6, 0.6, 0.65), _base_px)
		"table":
			if _table_has_links(obj):
				_build_rich_panel(_table_runs(obj), holder, local_pos, yaw, on_transition)
			else:
				_build_panel(holder, local_pos, yaw, _table_text(obj),
					Color(0.55, 0.6, 0.6), _base_px * 0.9)
		_:
			_build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.85, 0.85, 0.85), _base_px)


## Текстовая табличка-Label3D. font_css_px — кегль текста в CSS-пикселях страницы;
## и кегль шрифта, и высота таблички выводятся из него общим масштабом мира.
func _build_panel(holder: Node3D, local_pos: Vector3, yaw: float, text: String, color: Color, font_css_px: float) -> void:
	var node := Node3D.new()
	holder.add_child(node)
	node.position = local_pos
	node.rotation.y = yaw
	var font := _godot_font(font_css_px)
	var glyph_m := _px_to_m(font_css_px)
	var clipped := _truncate(text, 220)
	var height := _panel_height(clipped, glyph_m)
	# Тонкая «табличка».
	_add_box(node, Vector3(PANEL_WIDTH_M, height, 0.15), Vector3(0, height * 0.5, 0), color, false)
	var label := Label3D.new()
	label.text = clipped
	label.font_size = font
	label.outline_size = max(8, int(font * 0.25))
	label.pixel_size = LABEL_PIXEL_SIZE
	# Перенос по ширине таблички: width в пикселях кегля -> метры = width * pixel_size.
	label.width = int(PANEL_WIDTH_M / LABEL_PIXEL_SIZE)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector3(0, height * 0.5, 0.1)
	node.add_child(label)


## Высота таблички под текст: оценка числа строк (явные переносы + перенос по ширине)
## на мир-высоту глифа. Так короткий заголовок — низкая табличка, абзац — высокая.
func _panel_height(text: String, glyph_m: float) -> float:
	var char_w: float = max(0.001, glyph_m * 0.5)
	var per_line: float = max(1.0, PANEL_WIDTH_M / char_w)
	var explicit := 1 + text.count("\n")
	var wrapped := int(ceil(text.length() / per_line))
	var lines: int = max(explicit, wrapped)
	return clampf(lines * glyph_m * 1.5 + 0.4, 1.0, 6.0)


func _build_rich_panel(runs: Array, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> void:
	var panel: RichPanel = RICH_PANEL_SCENE.instantiate()
	# Кегль абзаца — базовый текст страницы, как и у дешёвых Label3D-табличек.
	panel.setup(runs, _px_to_m(_base_px))
	holder.add_child(panel)
	panel.rotation.y = yaw
	# Центрируем панель по высоте на уровне глаз, не утапливая в пол.
	var half := panel.get_height_m() * 0.5
	panel.position = local_pos + Vector3(0, max(1.6, half + 0.3), 0)
	if on_transition.is_valid():
		panel.link_activated.connect(on_transition)


## Картинка: ставит ImagePanel с заглушкой и просит лоадер подтянуть текстуру.
## transition != null -> картинка-ссылка (кликабельна, шлёт переход в общий обработчик).
func _build_image_panel(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float,
		transition, on_transition: Callable) -> void:
	var content: Dictionary = obj.get("content", {})
	var alt: String = str(content.get("alt", content.get("text", "")))
	# Размеры картинки из HTML (width/height в px) в метры тем же масштабом, что и текст:
	# картинка оказывается во столько раз крупнее строки, во сколько на странице. 0 = не задано.
	var want_w := _px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _px_to_m(float(content.get("height_px", 0.0)))
	# Картинка без размеров в HTML стартует с ~20em базового текста по ширине.
	var fallback_w := _px_to_m(_base_px * IMAGE_FALLBACK_EM)
	var panel := ImagePanel.new()
	panel.setup(alt, transition, want_w, want_h, fallback_w)
	holder.add_child(panel)
	panel.position = local_pos
	panel.rotation.y = yaw
	if transition != null and on_transition.is_valid():
		panel.link_activated.connect(on_transition)

	var src: String = str(content.get("src", ""))
	if src != "" and _image_loader != null:
		var url := PageFetcher.resolve_url(src, _base_url)
		panel.request_load(url, _image_loader)


func _runs_have_links(runs: Array) -> bool:
	for r in runs:
		if r.get("function", null) != null:
			return true
	return false


# --- Коридоры между родителем и детьми ---

func _build_corridors(id: int, parent: Node3D) -> void:
	var children: Array = _rooms[id]["children"]
	var ppos: Vector3 = _positions[id]
	for c in children:
		var cpos: Vector3 = _positions[c]
		_add_corridor(parent, ppos, cpos)
		_build_corridors(c, parent)


func _add_corridor(parent: Node3D, from_room: Vector3, to_room: Vector3) -> void:
	# Мостик от передней кромки родителя (+Z) к задней кромке ребёнка (-Z).
	var z0 := from_room.z + ROOM_SIZE * 0.5
	var z1 := to_room.z - ROOM_SIZE * 0.5
	if z1 <= z0:
		return
	var mid := Vector3((from_room.x + to_room.x) * 0.5, 0.0, (z0 + z1) * 0.5)
	var length := z1 - z0
	var x_span: float = abs(to_room.x - from_room.x) + CORRIDOR_WIDTH
	var holder := Node3D.new()
	holder.position = mid
	parent.add_child(holder)
	# Пол коридора (широкий, чтобы перекрыть сдвиг по X между уровнями).
	_add_box(holder, Vector3(x_span, 0.4, length), Vector3(0, -0.2, 0),
		Color(0.3, 0.3, 0.33), true)


# --- Метки якорей ---

func _resolve_labels(labels: Dictionary) -> void:
	for anchor_id in labels.keys():
		var target_id: int = labels[anchor_id]
		# Якорь может указывать на комнату напрямую или на объект — тогда берём комнату объекта.
		if _positions.has(target_id):
			label_positions[anchor_id] = _positions[target_id] + Vector3(0, 1.0, 0)
		elif _object_room.has(target_id) and _positions.has(_object_room[target_id]):
			label_positions[anchor_id] = _positions[_object_room[target_id]] + Vector3(0, 1.0, 0)


# --- Масштаб (CSS-пиксели страницы -> метры мира) ---

func _px_to_m(px: float) -> float:
	return px * _m_per_px


## Кегль Label3D (в пикселях Godot) для текста с CSS-кеглем css_px: мир-высота глифа
## получается = css_px * _m_per_px, а Label3D даёт font_size * LABEL_PIXEL_SIZE метров.
func _godot_font(css_px: float) -> int:
	return max(8, int(round(css_px * _m_per_px / LABEL_PIXEL_SIZE)))


# --- Низкоуровневые помощники ---

func _add_wall_x(holder: Node3D, x: float, color: Color) -> void:
	_add_box(holder, Vector3(WALL_THICK, WALL_HEIGHT, ROOM_SIZE),
		Vector3(x, WALL_HEIGHT * 0.5, 0), color, true)


func _add_wall_z(holder: Node3D, z: float, color: Color) -> void:
	_add_box(holder, Vector3(ROOM_SIZE, WALL_HEIGHT, WALL_THICK),
		Vector3(0, WALL_HEIGHT * 0.5, z), color, true)


## Создаёт коробку: MeshInstance3D (+ StaticBody3D со столкновением, если collide).
func _add_box(holder: Node3D, size: Vector3, local_pos: Vector3, color: Color, collide: bool) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	mesh.position = local_pos
	holder.add_child(mesh)
	if collide:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		body.add_child(shape)
		body.position = local_pos
		holder.add_child(body)


func _perimeter_slots(count: int, inset: float) -> Array:
	# Возвращает [{pos, yaw}] равномерно по 4 сторонам, лицом к центру.
	# Порядок — по часовой стрелке (слева направо, сверху вниз).
	# Вид сверху от точки спавна: -Z = верх (дальняя стена), +X = право, +Z = низ, -X = лево.
	var slots: Array = []
	var per_side := int(ceil(count / 4.0))
	var step := (inset * 2.0) / float(per_side + 1)
	# dir задаёт направление обхода стены, чтобы общий путь шёл по часовой стрелке.
	var sides := [
		{"axis": Vector3(1, 0, 0), "base": Vector3(0, 0, -inset), "yaw": 0.0,        "dir": 1.0},   # задняя (верх): слева направо
		{"axis": Vector3(0, 0, 1), "base": Vector3(inset, 0, 0),  "yaw": -PI * 0.5,  "dir": 1.0},   # правая: сверху вниз
		{"axis": Vector3(1, 0, 0), "base": Vector3(0, 0, inset),  "yaw": PI,         "dir": -1.0},  # передняя (низ): справа налево
		{"axis": Vector3(0, 0, 1), "base": Vector3(-inset, 0, 0), "yaw": PI * 0.5,   "dir": -1.0},  # левая: снизу вверх
	]
	var placed := 0
	for s in range(4):
		for k in range(per_side):
			if placed >= count:
				break
			var side: Dictionary = sides[s]
			var offset: float = (-inset + step * (k + 1)) * (side["dir"] as float)
			var pos: Vector3 = side["base"] + (side["axis"] as Vector3) * offset
			slots.append({"pos": pos, "yaw": side["yaw"]})
			placed += 1
	return slots


func _has_parent(id: int) -> bool:
	for rid in _rooms.keys():
		if id in (_rooms[rid]["children"] as Array):
			return true
	return false


func _room_color(room: Dictionary, is_connector: bool) -> Color:
	var css: Dictionary = room["hints"].get("css", {})
	if css.has("bg"):
		var c = _parse_css_color(css["bg"])
		if c != null:
			return c
	if is_connector:
		return Color(0.32, 0.34, 0.4)
	# Слегка варьируем оттенок от seed+id для различимости комнат.
	_rng.seed = _seed + room["id"] * 2654435761
	return Color.from_hsv(_rng.randf(), 0.28, 0.7)


func _parse_css_color(value: String):
	value = value.strip_edges().to_lower()
	# Godot понимает и #hex, и именованные цвета через Color.html.
	if Color.html_is_valid(value):
		return Color.html(value)
	return null


func _obj_text(obj: Dictionary) -> String:
	var content: Dictionary = obj.get("content", {})
	var t: String = content.get("text", content.get("alt", ""))
	if t.strip_edges() == "":
		var fn = obj.get("function", null)
		if fn != null:
			t = fn.get("href", fn.get("target", "ссылка"))
	return t


func _list_text(obj: Dictionary) -> String:
	var items: Array = obj.get("content", {}).get("items", [])
	var lines: PackedStringArray = []
	for it in items:
		lines.append("• " + str(it.get("text", "")))
	return "\n".join(lines)


func _list_has_links(obj: Dictionary) -> bool:
	for it in obj.get("content", {}).get("items", []):
		if _runs_have_links(it.get("runs", [])):
			return true
	return false


## Линеаризует список в прогоны для RichPanel: «•» + прогоны пункта (со ссылками) + перевод.
func _list_runs(obj: Dictionary) -> Array:
	var runs: Array = []
	for it in obj.get("content", {}).get("items", []):
		runs.append({"text": "•  ", "function": null})
		_append_runs(runs, it.get("runs", []), str(it.get("text", "")))
		runs.append({"text": "\n", "function": null})
	return runs


func _table_text(obj: Dictionary) -> String:
	var content: Dictionary = obj.get("content", {})
	var lines: PackedStringArray = []
	var caption: String = content.get("caption", "")
	if caption.strip_edges() != "":
		lines.append("▦ " + caption)
	for row in content.get("rows", []):
		var cells: PackedStringArray = []
		for cell in row.get("cells", []):
			cells.append(str(cell.get("text", "")))
		lines.append(" | ".join(cells))
	return "\n".join(lines)


func _table_has_links(obj: Dictionary) -> bool:
	for row in obj.get("content", {}).get("rows", []):
		for cell in row.get("cells", []):
			if _runs_have_links(cell.get("runs", [])):
				return true
	return false


## Линеаризует таблицу в прогоны для RichPanel: подпись, строки через перевод, ячейки через «|».
func _table_runs(obj: Dictionary) -> Array:
	var content: Dictionary = obj.get("content", {})
	var runs: Array = []
	var caption: String = content.get("caption", "")
	if caption.strip_edges() != "":
		runs.append({"text": "▦ " + caption + "\n", "function": null})
	for row in content.get("rows", []):
		var cells: Array = row.get("cells", [])
		for i in cells.size():
			if i > 0:
				runs.append({"text": "  |  ", "function": null})
			var cell: Dictionary = cells[i]
			_append_runs(runs, cell.get("runs", []), str(cell.get("text", "")))
		runs.append({"text": "\n", "function": null})
	return runs


## Добавляет прогоны ячейки/пункта в общий поток; пусто -> запасной текстовый прогон.
func _append_runs(out: Array, src_runs: Array, fallback_text: String) -> void:
	if src_runs.is_empty():
		if fallback_text != "":
			out.append({"text": fallback_text, "function": null})
		return
	for r in src_runs:
		out.append(r)


func _truncate(s: String, n: int) -> String:
	s = s.strip_edges()
	if s.length() <= n:
		return s
	return s.substr(0, n) + "…"
