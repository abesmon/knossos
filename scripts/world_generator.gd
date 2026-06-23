class_name WorldGenerator
extends RefCounted

## Фаза геометрии (F) из docs/html-to-3d-topology.md. Потребляет ТОЛЬКО артефакт
## топологии (Dictionary) + seed и сочиняет конкретное навигируемое пространство.
##
## Раскладка v3 — «кварталы на сетке». Вся геометрия живёт в целочисленных клетках сетки
## GRID, поэтому КАЖДАЯ стена ложится на линию сетки (единое выравнивание). Поддеревья
## пакуются прямоугольниками с «улицами»-зазорами между блоками (кластеризация + компактность);
## коридоры маршрутизируются ортогонально по улицам, не заходя в комнаты и не пересекаясь.
##
## Фазы:
##   1. замер объектов     -> футпринт каждой настенной панели (_object_size)
##   2. размер комнаты      -> сторона под объекты, снапнутая к клеткам (_room_cells/_room_size)
##   3. упаковка блоками     -> комнаты на единой сетке, кластерами (_room_cell, _positions)
##   4. роутинг коридоров    -> ортогональные пути по улицам, проёмы в стенах (_room_openings)
##   5. геометрия            -> полы/стены-с-проёмами/объекты/коридоры
## Случайность — только в цветах/атмосфере (_rng от seed); раскладка детерминирована.

## Геометрия комнат строится не за один кадр, а порциями (тайм-слайс), чтобы тяжёлая
## страница (сотни узлов) не вешала главный поток. Сигнал — когда весь мир достроен
## (нужно main, чтобы просканировать видео-экраны после стриминга). См. _stream_remaining.
signal build_finished

const PORTAL_SCENE := preload("res://actors/portal/portal.tscn")
const RICH_PANEL_SCENE := preload("res://actors/rich_panel/rich_panel.tscn")

## Ключ метаданных с провенансом узла (тип топологии + исходный HTML) — его читает
## отладочный пробник прицела (Player._debug_probe). Заполняется только если в артефакте
## есть "sources" (т.е. топология собрана с debug=true). См. _attach_debug.
const DEBUG_META := "vrweb_debug"

# --- Сетка ---
const GRID := 3.0               # размер клетки сетки = ширина коридора/проёма, м
const STREET_CELLS := 1         # зазор-улица между комнатами (≥ ширины коридора), клеток
const ROOM_MIN_CELLS := 2       # минимальная сторона комнаты, клеток
const CORR := -1                # маркер коридорной клетки в _occ (id комнат ≥ 0)

# --- Пружинная утряска раскладки (force-directed) ---
const RELAX_ITERS := 320        # потолок итераций утряски
const RELAX_MAX_STEP := GRID    # максимум сдвига узла за итерацию, м
const RELAX_EPS := 0.01         # порог «утряслось» (макс. сдвиг за итерацию), м
const SPRING_MIN := 0.05        # сила пружины у корня (ближе к корню — слабее)
const SPRING_MAX := 0.22        # сила пружины у листьев (листья тянет сильнее всего)
const GRID_PULL := 0.06         # сила притяжения комнаты к линиям сетки
const COLLIDE_K := 0.6          # сила расталкивания пересекающихся кругов
const RELAX_GAP := GRID * 0.75  # зазор-улица, заложенный в радиус круга комнаты, м
const PLACE_MAX_RADIUS := 256   # потолок спирального поиска свободной клетки при снапе

# --- Гравитация раскладки (безразмерная карта по сиду, проецируется на bbox) ---
# Дополнительная мягкая сила: по сиду выбирается маленькая «карта гравитации» (палитра),
# безразмерно проецируется на оценённый размах раскладки и тянет комнаты к высоким своим
# значениям (gradient ascent по билинейно-интерполированному полю). Слабее пружин и притяжения
# к сетке; жёсткий снэп (_snap_to_cells) всё равно последнее слово ⇒ сетка/непересечение целы.
const GRAVITY_K := 0.9          # сила притяжения к высоким значениям карты (мягче пружин/сетки)
const GRAVITY_COVER := 1.6      # над-покрытие: во сколько зона проекции шире оценённого размаха

const WALL_HEIGHT := 3.2        # минимальная высота стен, м
const WALL_THICK := 0.15        # тонкая стена, сдвинутая внутрь комнаты на полтолщины (см. _add_wall_seg): у вплотную стоящих комнат стены стыкуются грань-в-грань, без z-fight
const ROUTE_EXPAND := 16        # запас области поиска коридора вокруг пары комнат, клеток

# --- Расстановка объектов по стенам ---
const OBJECT_INSET := 1.2       # отступ объекта от своей стены внутрь комнаты, м
const CORNER_MARGIN := 1.0      # отступ крайних объектов от углов вдоль стены, м
const OBJECT_GAP := 0.6         # зазор между соседними панелями вдоль стены, м
const HEAD_CLEARANCE := 0.8     # запас над самым высоким объектом до верха стены, м
const DOOR_MARGIN := 0.5        # отступ объектов от края проёма вдоль стены, м
const EYE_LEVEL := 1.6          # высота центра текстовых/картиночных панелей, м (= высота камеры игрока)
const PANEL_FLOOR_GAP := 0.3    # минимальный зазор от низа высокой панели до пола, м
const TITLE_OVERHANG := 0.4     # на сколько вывеска-заголовок шире проёма с каждой стороны, м
const TITLE_MIN_H := 0.5        # минимальная высота вывески-заголовка над проходом, м
const TITLE_MAX_H := 1.2        # максимальная высота вывески-заголовка (капает крупные h1), м
# Запасной футпринт портала-ссылки (portal.tscn: 1.2 x 2.2 + подпись над ним).
const PORTAL_W := 1.4
const PORTAL_H := 2.6

# --- Масштаб: единый перевод CSS-пикселей страницы в метры мира ---
const M_PER_BASE_LINE := 0.18   # мир-высота глифа базового текста, м
const LABEL_PIXEL_SIZE := 0.006 # Label3D: 1px кегля Godot -> м
const PANEL_WIDTH_M := 2.2      # ширина текстовой таблички-Label3D, м
const IMAGE_FALLBACK_EM := 20.0 # ширина картинки без размеров в HTML, в «эмах» базы
const VIDEO_FALLBACK_EM := 26.0 # ширина <video> без размеров в HTML, в «эмах» базы (экран крупнее картинки)
const HEADING_EM := {1: 2.0, 2: 1.5, 3: 1.17, 4: 1.0, 5: 0.83, 6: 0.67}

var _space: Dictionary
var _rooms: Dictionary
var _root_id: int = -1
var _seed: int
var _rng := RandomNumberGenerator.new()
var _base_url: String = ""
var _image_loader: ImageLoader = null
var _sources: Dictionary = {}     # id -> исходный HTML (есть только при debug-сборке топологии)
var _debug: bool = false          # привязывать ли провенанс к узлам (есть "sources" в артефакте)
var _base_px := 16.0
var _m_per_px := M_PER_BASE_LINE / 16.0
var _rich_w_m := 2.375
var _rich_font_px := 24

var _dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# Замеры/раскладка по фазам.
var _parent_of: Dictionary = {}   # childId -> parentId
var _object_size: Dictionary = {} # objectId -> Vector2(w, h), м
var _room_cells: Dictionary = {}  # roomId -> Vector2i: футпринт в клетках (ширина, глубина)
var _room_size: Dictionary = {}   # roomId -> Vector2: футпринт в метрах (cells*GRID)
var _room_wall_h: Dictionary = {} # roomId -> высота стен, м
var _pos2: Dictionary = {}        # roomId -> Vector2: координаты центра при утряске, м
var _radius: Dictionary = {}      # roomId -> float: безопасный радиус круга комнаты, м
var _depth: Dictionary = {}       # roomId -> int: глубина от корня (листья глубже -> пружины сильнее)
var _grav_map: Array = []         # 2D карта гравитации (по сиду): [ряд][столбец] -> float
var _grav_name := ""              # имя выбранной карты (для отладочного вывода)
var _grav_w := 0                  # столбцов в карте
var _grav_h := 0                  # рядов в карте
var _grav_origin := Vector2.ZERO  # левый-верхний угол зоны проекции, м (фикс)
var _grav_extent := Vector2.ONE   # размах зоны проекции, м (фикс, оценка из площади)
var _room_cell: Dictionary = {}   # roomId -> Vector2i: левый-верхний угол комнаты на сетке
var _occ: Dictionary = {}         # Vector2i -> roomId | CORR
var _corr_cells: Dictionary = {}  # Vector2i -> true: клетки полов-коридоров
var _room_openings: Dictionary = {} # roomId -> [{key, lo, hi}] проёмы в стенах (локальные м)
var _room_entrance: Dictionary = {} # roomId -> {key, lo, hi}: проём-вход от родителя (над ним — вывеска-заголовок)
var _direct_child: Dictionary = {} # childId -> true: соединён с коннектором прямым проёмом (без коридора)
var _object_room: Dictionary = {} # objectId -> roomId
var _positions: Dictionary = {}   # roomId -> Vector3 (центр пола, мир)
var _shift := Vector3.ZERO        # сдвиг сетки в мир (корень к началу координат)

# Спавн «у первого объекта страницы, лицом к нему» (считается в фазе 5).
var _first_obj_id: int = -1        # id первого объекта в порядке чтения (см. _find_first_object_id)
var _has_spawn_obj: bool = false   # нашли ли первый объект при расстановке
var _spawn_obj_world := Vector3.ZERO  # мир-позиция первого объекта (на полу)
var _spawn_inward := Vector3.ZERO     # направление от стены первого объекта внутрь комнаты
var _spawn_max_d: float = 3.5         # потолок отступа спавна от объекта (чтобы не вылезти из комнаты)
var _spawn_done: bool = false         # спавн уже задан напрямую (вход через титульный проём)

# Результат генерации, нужный main.
var spawn_point := Vector3.ZERO
var spawn_look_at := Vector3.ZERO      # точка, на которую игрок смотрит при спавне
var has_spawn_look: bool = false       # валиден ли spawn_look_at
var label_positions: Dictionary = {}   # anchorId -> Vector3
var build_complete: bool = false       # весь мир достроен (стриминг по кадрам завершён)

# --- Тайм-слайс билда (стриминг геометрии по кадрам) ---
const BUILD_BUDGET_MS := 6.0           # бюджет создания узлов за кадр, мс (потом await кадра)
var _container: Node3D                  # узел-контейнер всей геометрии под parent (см. _build)
var _on_transition: Callable           # коллбэк переходов, для отложенной достройки комнат
var _built: Dictionary = {}            # roomId -> true: комната уже построена

# Шеринг ресурсов: тысячи стен/полов делят одинаковые BoxMesh/материалы/коллизии вместо
# создания уникального ресурса на каждый бокс (экономит память и время при большой странице).
var _box_mesh_cache: Dictionary = {}   # Vector3 -> BoxMesh
var _box_shape_cache: Dictionary = {}  # Vector3 -> BoxShape3D
var _mat_cache: Dictionary = {}        # Color -> StandardMaterial3D


static func generate(space: Dictionary, parent: Node3D, seed_value: int, on_transition: Callable,
		base_url: String = "", image_loader: ImageLoader = null) -> WorldGenerator:
	var g := WorldGenerator.new()
	g._base_url = base_url
	g._image_loader = image_loader
	g._build(space, parent, seed_value, on_transition)
	# Достройку оставшихся комнат запускаем отдельной корутиной (fire-and-forget): её держит
	# живой подписка на process_frame. Вложенный await внутри _build ломает возобновление,
	# поэтому _build синхронный (раскладка + спавн готовы к возврату), а стриминг — здесь.
	g._stream_remaining()
	return g


func _build(space: Dictionary, parent: Node3D, seed_value: int, on_transition: Callable) -> void:
	_space = space
	_rooms = space.get("rooms", {})
	_sources = space.get("sources", {})
	_debug = space.has("sources")   # топология собрана с debug=true -> есть провенанс
	_seed = seed_value
	_rng.seed = seed_value
	_base_px = float(space.get("typography", {}).get("base_px", 16.0))
	if _base_px <= 0.0:
		_base_px = 16.0
	_m_per_px = M_PER_BASE_LINE / _base_px
	_rich_w_m = float(RichPanel.PANEL_WIDTH_PX) / RichPanel.PIXEL_PER_METER
	_rich_font_px = max(8, int(round(_px_to_m(_base_px) * RichPanel.PIXEL_PER_METER)))
	_root_id = space.get("root", -1)
	if _root_id == -1 or not _rooms.has(_root_id):
		return

	_build_parent_map()
	_measure_objects()                       # фаза 1
	_compute_room_dims()                     # фаза 2 (+ снап к клеткам)
	_relax_layout()                          # фаза 3 (пружинная утряска, seeded)
	_snap_to_cells()                         # снап на сетку + дискретное расталкивание
	_finalize_positions()
	_fill_occupancy()
	_route_corridors()                       # фаза 4

	_first_obj_id = _find_first_object_id()
	for id in _rooms.keys():
		for obj in _rooms[id]["objects"]:
			_object_room[obj["id"]] = id
	_resolve_labels(space.get("labels", {}))   # позиции якорей — из раскладки, не из узлов

	# Вся геометрия живёт под собственным контейнером: при навигации main сносит детей мира,
	# контейнер вместе с ними — и стриминг (_stream_remaining) видит, что он больше не в дереве,
	# и бросает достройку, не подсыпая узлы старой страницы в уже новый мир.
	_container = Node3D.new()
	_container.name = "Generated"
	parent.add_child(_container)
	_on_transition = on_transition

	# Синхронно (до первого кадра): свет/небо — чтобы мир был освещён, и комната спавна —
	# чтобы spawn_point был готов к возврату из generate() и игроку было куда встать.
	# Остальные комнаты достраиваются порциями по кадрам (см. _stream_remaining).
	_build_atmosphere(_container, _root_id)     # фаза 5: атмосфера
	var spawn_room_id: int = _object_room.get(_first_obj_id, _root_id)
	if _rooms.has(spawn_room_id):
		_build_room(spawn_room_id, _container, on_transition)
		_built[spawn_room_id] = true
	_compute_spawn()
	# Остальные комнаты достраивает _stream_remaining (запускается из generate отдельной корутиной).


## Достраивает оставшиеся комнаты и полы-коридоры порциями по кадрам: создаём узлы, пока
## не выйдет бюджет кадра (BUILD_BUDGET_MS), затем ждём следующего кадра. Так тяжёлая
## страница не вешает главный поток. По завершении — build_complete + сигнал build_finished
## (main по нему сканирует видео-экраны). Если мир снесён навигацией (контейнер освобождён
## через queue_free) — молча бросаем: новый мир уже строит свой генератор.
func _stream_remaining() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var start := Time.get_ticks_msec()
	for id in _rooms.keys():
		if not is_instance_valid(_container):
			return
		if _built.has(id):
			continue
		_build_room(id, _container, _on_transition)
		_built[id] = true
		if Time.get_ticks_msec() - start >= BUILD_BUDGET_MS:
			await tree.process_frame
			# Навигация снесла мир (main сделал queue_free контейнера) — бросаем достройку:
			# новый мир строит свой генератор, а узлы старой страницы тут уже не нужны.
			if not is_instance_valid(_container):
				return
			start = Time.get_ticks_msec()
	if not is_instance_valid(_container):
		return
	_build_corridor_floors(_container)
	build_complete = true
	build_finished.emit()


func _build_parent_map() -> void:
	for id in _rooms.keys():
		for ch in _rooms[id]["children"]:
			_parent_of[ch] = id


## Первый объект страницы в порядке чтения: наполнение комнаты идёт раньше её подкомнат,
## заголовок секции — первый объект комнаты (§D). Спускаемся по первым детям, пока не
## встретим комнату со своими объектами. -1, если объектов на странице нет вовсе.
func _find_first_object_id() -> int:
	var id: int = _root_id
	while _rooms.has(id):
		var objs: Array = _rooms[id]["objects"]
		if not objs.is_empty():
			return objs[0]["id"]
		var ch: Array = _rooms[id]["children"]
		if ch.is_empty():
			return -1
		id = ch[0]
	return -1


## Спавн «у первого объекта, лицом к нему» (см. _record_spawn): встаём от объекта внутрь
## комнаты и смотрим на него. Если объектов нет — запасной спавн в корне у его края.
func _compute_spawn() -> void:
	if _spawn_done:   # спавн уже задан через титульный проём (_record_title_spawn)
		return
	if _has_spawn_obj:
		var d: float = clampf(3.5, 1.2, _spawn_max_d)
		spawn_point = _spawn_obj_world + _spawn_inward * d + Vector3(0, 1.0, 0)
		spawn_look_at = _spawn_obj_world + Vector3(0, 1.6, 0)
		has_spawn_look = true
		return
	var root_size: Vector2 = _room_size.get(_root_id, Vector2(GRID * 2, GRID * 2))
	spawn_point = _positions.get(_root_id, Vector3.ZERO) + Vector3(0, 1.0, root_size.y * 0.3)


func _link_count(id: int) -> int:
	var n: int = _rooms[id]["children"].size()
	if _parent_of.has(id):
		n += 1
	return n


# --- Фаза 1: замер объектов (футпринт настенной панели) ---

func _measure_objects() -> void:
	for id in _rooms.keys():
		for obj in _rooms[id]["objects"]:
			_object_size[obj["id"]] = _measure_object(obj)


func _measure_object(obj: Dictionary) -> Vector2:
	var type: String = obj.get("type", "text")
	if type == "image" or type == "figure":
		return _measure_image(obj)
	if type == "media" and obj.get("content", {}).get("media_tag", "") == "video":
		return _measure_video(obj)
	var fn = obj.get("function", null)
	if fn != null and typeof(fn) == TYPE_DICTIONARY:
		return Vector2(PORTAL_W, PORTAL_H)
	var runs: Array = obj.get("content", {}).get("runs", [])
	if type == "text" and not runs.is_empty() and (_runs_have_links(runs) or _obj_text(obj).length() > 200):
		return Vector2(_rich_w_m, RichPanel.estimate_height_m(runs, _rich_font_px))
	if type == "list" and (_list_has_links(obj) or _list_has_images(obj)):
		return Vector2(_rich_w_m, RichPanel.estimate_height_m(_list_runs(obj), _rich_font_px))
	if type == "table" and (_table_has_links(obj) or _table_has_images(obj)):
		return Vector2(_rich_w_m, RichPanel.estimate_height_m(_table_runs(obj), _rich_font_px))
	return _measure_panel(obj)


func _measure_panel(obj: Dictionary) -> Vector2:
	var type: String = obj.get("type", "text")
	var px := _base_px
	var text := ""
	match type:
		"heading":
			var level: int = int(obj.get("content", {}).get("level", 2))
			px = _base_px * float(HEADING_EM.get(level, 1.0))
			text = _obj_text(obj)
		"media":
			text = "▷ " + _obj_text(obj)
		"button", "input":
			text = "▢ " + _obj_text(obj)
		"list":
			text = _list_text(obj)
		"table":
			px = _base_px * 0.9
			text = _table_text(obj)
		_:
			text = _obj_text(obj)
	var glyph_m := _px_to_m(px)
	var h := _panel_height(_truncate(text, 220), glyph_m)
	return Vector2(PANEL_WIDTH_M, h)


func _measure_image(obj: Dictionary) -> Vector2:
	var content: Dictionary = obj.get("content", {})
	var want_w := _px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _px_to_m(float(content.get("height_px", 0.0)))
	var fallback_w := _px_to_m(_base_px * IMAGE_FALLBACK_EM)
	var w := 0.0
	var h := 0.0
	if want_w > 0.0 and want_h > 0.0:
		w = want_w
		h = want_h
	elif want_w > 0.0:
		w = want_w
		h = want_w * ImagePanel.DEFAULT_RATIO
	elif want_h > 0.0:
		h = want_h
		w = want_h / ImagePanel.DEFAULT_RATIO
	else:
		w = fallback_w
		h = fallback_w * ImagePanel.DEFAULT_RATIO
	if w > ImagePanel.MAX_WIDTH:
		var k := ImagePanel.MAX_WIDTH / w
		w *= k
		h *= k
	if h > ImagePanel.MAX_HEIGHT:
		var k2 := ImagePanel.MAX_HEIGHT / h
		w *= k2
		h *= k2
	return Vector2(maxf(0.2, w), maxf(0.2, h))


## Размер экрана <video>: из width/height (если заданы), иначе запасная ширина с пропорциями
## 16:9 (как у VrwebVideoScreen до прихода кадра). Капится потолками ImagePanel, как картинки.
func _measure_video(obj: Dictionary) -> Vector2:
	var content: Dictionary = obj.get("content", {})
	var want_w := _px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _px_to_m(float(content.get("height_px", 0.0)))
	var ratio := VrwebVideoScreen.DEFAULT_RATIO   # высота/ширина (9/16)
	var w := 0.0
	var h := 0.0
	if want_w > 0.0 and want_h > 0.0:
		w = want_w
		h = want_h
	elif want_w > 0.0:
		w = want_w
		h = want_w * ratio
	elif want_h > 0.0:
		h = want_h
		w = want_h / ratio
	else:
		w = _px_to_m(_base_px * VIDEO_FALLBACK_EM)
		h = w * ratio
	if w > ImagePanel.MAX_WIDTH:
		var k := ImagePanel.MAX_WIDTH / w
		w *= k
		h *= k
	if h > ImagePanel.MAX_HEIGHT:
		var k2 := ImagePanel.MAX_HEIGHT / h
		w *= k2
		h *= k2
	return Vector2(maxf(0.2, w), maxf(0.2, h))


# --- Фаза 2: размер комнаты под объекты, снапнутый к сетке ---

func _compute_room_dims() -> void:
	for id in _rooms.keys():
		_compute_room_dim(id)


func _compute_room_dim(id: int) -> void:
	var objs: Array = _rooms[id]["objects"]
	var total := 0.0
	var max_w := 0.0
	var max_h := 0.0
	for obj in objs:
		var s: Vector2 = _object_size[obj["id"]]
		total += s.x + OBJECT_GAP
		max_w = maxf(max_w, s.x)
		max_h = maxf(max_h, s.y)
	# Периметр (4 стены минус полосы проходов) должен покрыть суммарную длину объектов.
	var doors: int = mini(_link_count(id), 4)
	var need := (total + float(doors) * GRID) * 1.2
	var l := need / 4.0 + 2.0 * CORNER_MARGIN
	l = maxf(l, max_w + 2.0 * (CORNER_MARGIN + DOOR_MARGIN))
	# Снап к клеткам. Комнаты стартуют квадратными; коннекторы могут стать прямоугольными
	# позже, при кластерной упаковке (_pack_clusters).
	var cw: int = max(ROOM_MIN_CELLS, int(ceil(l / GRID)))
	_room_cells[id] = Vector2i(cw, cw)
	_room_size[id] = Vector2(cw, cw) * GRID
	_room_wall_h[id] = maxf(WALL_HEIGHT, max_h + HEAD_CLEARANCE)


# --- Фаза 3: пружинная утряска раскладки (force-directed), seeded ---

## Континуальная утряска: пружины родитель↔ребёнок (листья сильнее, к корню слабее) +
## расталкивание кругов (не дают налезать) + притяжение к сетке (стены ложатся на линии).
## Сид задаёт ТОЛЬКО стартовый разброс; сама релаксация детерминирована ⇒ один сид = один итог.
func _relax_layout() -> void:
	_compute_depths()
	for id in _rooms.keys():
		var s: Vector2 = _room_size[id]
		_radius[id] = maxf(s.x, s.y) * 0.5 + RELAX_GAP
	_rng.seed = _seed
	_pos2[_root_id] = Vector2.ZERO
	_init_positions(_root_id)
	_setup_gravity()

	var max_depth := 1
	for id in _depth.keys():
		max_depth = max(max_depth, _depth[id])

	for _iter in RELAX_ITERS:
		var disp: Dictionary = {}
		for id in _rooms.keys():
			disp[id] = Vector2.ZERO
		_apply_springs(disp, max_depth)
		_apply_collision(disp)
		_apply_grid_pull(disp)
		_apply_gravity(disp)
		var max_move := 0.0
		for id in _rooms.keys():
			var m: Vector2 = (disp[id] as Vector2).limit_length(RELAX_MAX_STEP)
			_pos2[id] += m
			max_move = maxf(max_move, m.length())
		if max_move < RELAX_EPS:
			break


func _compute_depths() -> void:
	_depth[_root_id] = 0
	var q: Array = [_root_id]
	var qi := 0
	while qi < q.size():
		var id: int = q[qi]
		qi += 1
		for ch in _rooms[id]["children"]:
			_depth[ch] = _depth[id] + 1
			q.append(ch)


## Стартовый разброс: каждый ребёнок — на сумму радиусов от родителя в случайную сторону (seed).
func _init_positions(id: int) -> void:
	for ch in _rooms[id]["children"]:
		var ang := _rng.randf() * TAU
		var dist: float = _radius[id] + _radius[ch]
		_pos2[ch] = _pos2[id] + Vector2(cos(ang), sin(ang)) * dist
		_init_positions(ch)


## Пружины родитель↔ребёнок. Длина покоя = соприкосновение кругов; сила растёт с глубиной
## ребёнка (листья тянет сильнее всего, ближе к корню — слабее).
func _apply_springs(disp: Dictionary, max_depth: int) -> void:
	for ch in _rooms.keys():
		if not _parent_of.has(ch):
			continue
		var p: int = _parent_of[ch]
		var d: Vector2 = _pos2[ch] - _pos2[p]
		var dist: float = d.length()
		if dist < 0.0001:
			d = Vector2.RIGHT
			dist = 0.0001
		var dir: Vector2 = d / dist
		var rest: float = _radius[p] + _radius[ch]
		var t: float = float(_depth[ch]) / float(max_depth)
		var k: float = lerpf(SPRING_MIN, SPRING_MAX, t)
		var f: float = k * (dist - rest)
		disp[ch] -= dir * f * 0.5
		disp[p] += dir * f * 0.5


## Расталкивание пересекающихся кругов — комнаты не налезают и не схлопываются.
func _apply_collision(disp: Dictionary) -> void:
	var ids: Array = _rooms.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: int = ids[i]
			var b: int = ids[j]
			var d: Vector2 = _pos2[b] - _pos2[a]
			var dist: float = d.length()
			var mind: float = _radius[a] + _radius[b]
			if dist >= mind:
				continue
			var dir: Vector2 = (d / dist) if dist > 0.0001 else Vector2.RIGHT
			var push: float = (mind - dist) * COLLIDE_K
			disp[a] -= dir * push * 0.5
			disp[b] += dir * push * 0.5


## Притяжение к сетке: тянет комнату так, чтобы её угол (а значит и стены) лёг на линии GRID.
func _apply_grid_pull(disp: Dictionary) -> void:
	for id in _rooms.keys():
		var half: Vector2 = _room_size[id] * 0.5
		var corner: Vector2 = _pos2[id] - half
		var snap_corner := Vector2(roundf(corner.x / GRID) * GRID, roundf(corner.y / GRID) * GRID)
		var target: Vector2 = snap_corner + half
		disp[id] += (target - _pos2[id]) * GRID_PULL


## Гравитация: тянет комнату в сторону роста поля карты (gradient ascent по билинейной выборке).
func _apply_gravity(disp: Dictionary) -> void:
	if _grav_map.is_empty():
		return
	for id in _rooms.keys():
		disp[id] += _grav_grad(_pos2[id]) * GRAVITY_K


## Выбирает карту по сиду из палитры и задаёт фикс-зону проекции вокруг корня (в начале координат).
## Размах оценивается из суммарной площади комнат (квадрат, упаковывающий их без зазоров),
## расширенный GRAVITY_COVER ⇒ комнаты в норме не выходят за зону (за краями — зеркальное отражение).
func _setup_gravity() -> void:
	_grav_map = _pick_gravity_map(_seed)
	_grav_h = _grav_map.size()
	_grav_w = 0 if _grav_h == 0 else (_grav_map[0] as Array).size()
	if _grav_w == 0:
		return
	var total_cells := 0.0
	for id in _rooms.keys():
		var rc: Vector2i = _room_cells[id]
		total_cells += float(rc.x * rc.y)
	var side: float = sqrt(maxf(total_cells, 1.0)) * GRID * GRAVITY_COVER
	_grav_extent = Vector2(side, side)
	_grav_origin = -_grav_extent * 0.5   # центр зоны — в начале координат (там же корень)
	_print_gravity()


## Отладочный вывод применённой гравитации: имя карты, её сетка значений и размах зоны проекции.
func _print_gravity() -> void:
	var grid_str := ""
	for row in _grav_map:
		var cells := PackedStringArray()
		for v in row:
			cells.append(str(int(v)))
		grid_str += "\n    " + " ".join(cells)
	print("[WorldGen] gravity: «%s» (%dx%d, k=%.3f), зона %.1fx%.1f м:%s"
			% [_grav_name, _grav_w, _grav_h, GRAVITY_K, _grav_extent.x, _grav_extent.y, grid_str])


## Палитра безразмерных карт гравитации. Сид выбирает одну. Значения: чем выше — тем сильнее
## притягивает (0 — нейтраль). Билинейная интерполяция сглаживает грубые клетки в градиент.
## Каждая запись: [имя, ряды-строки]. Имя кладётся в `_grav_name` для отладочного вывода.
func _pick_gravity_map(seed_value: int) -> Array:
	var palette := [
		["крест",     ["00100", "00200", "12221", "00200", "00100"]],  # стягивает к центральному кресту
		["два-полюса", ["101", "101", "101"]],                          # растаскивает влево/вправо
		["диагональ", ["100", "010", "001"]],                           # вытягивает по диагонали
		["кольцо",    ["111", "101", "111"]],                           # выталкивает к периметру
		["холм",      ["00000", "01110", "01210", "01110", "00000"]],   # один центральный сгусток
	]
	var idx: int = abs(seed_value) % palette.size()
	_grav_name = palette[idx][0]
	return _parse_gravity_map(palette[idx][1])


## Строки цифр -> 2D-массив float.
func _parse_gravity_map(rows: Array) -> Array:
	var out: Array = []
	for row in rows:
		var s: String = row
		var line: Array = []
		for i in s.length():
			line.append(float(s.substr(i, 1).to_int()))
		out.append(line)
	return out


## Билинейный градиент поля карты в мировой точке (направлен к росту значения).
## Считается в нормированных uv-координатах ⇒ сила не зависит от масштаба зоны проекции.
func _grav_grad(world: Vector2) -> Vector2:
	var uv := _grav_uv(world)
	var eu: float = 0.5 / float(max(1, _grav_w - 1))
	var ev: float = 0.5 / float(max(1, _grav_h - 1))
	var dx: float = _grav_sample_uv(uv + Vector2(eu, 0.0)) - _grav_sample_uv(uv - Vector2(eu, 0.0))
	var dy: float = _grav_sample_uv(uv + Vector2(0.0, ev)) - _grav_sample_uv(uv - Vector2(0.0, ev))
	return Vector2(dx, dy)


func _grav_uv(world: Vector2) -> Vector2:
	return Vector2((world.x - _grav_origin.x) / _grav_extent.x,
			(world.y - _grav_origin.y) / _grav_extent.y)


## Билинейная выборка карты по uv (вне [0,1] — зеркальное отражение, поле непрерывно на краях).
func _grav_sample_uv(uv: Vector2) -> float:
	var gx := _mirror_index(uv.x * float(_grav_w - 1), _grav_w)
	var gy := _mirror_index(uv.y * float(_grav_h - 1), _grav_h)
	var x0: int = int(floor(gx))
	var y0: int = int(floor(gy))
	var x1: int = min(x0 + 1, _grav_w - 1)
	var y1: int = min(y0 + 1, _grav_h - 1)
	var fx: float = gx - float(x0)
	var fy: float = gy - float(y0)
	var top: float = lerpf(_grav_at(x0, y0), _grav_at(x1, y0), fx)
	var bot: float = lerpf(_grav_at(x0, y1), _grav_at(x1, y1), fx)
	return lerpf(top, bot, fy)


func _grav_at(x: int, y: int) -> float:
	return (_grav_map[y] as Array)[x]


## Отражает координату c в диапазон [0, n-1] (зеркальный тайлинг, период 2*(n-1)).
func _mirror_index(c: float, n: int) -> float:
	if n <= 1:
		return 0.0
	var period: float = 2.0 * float(n - 1)
	var m: float = fposmod(c, period)
	if m > float(n - 1):
		m = period - m
	return m


## Жёсткий снап на целочисленные клетки + дискретное расталкивание: точная сетка и зазор
## ≥STREET_CELLS-улица между комнатами (для прокладки коридоров) гарантированы.
## Упаковка идёт «единицами»: одиночная комната ИЛИ кластер (коннектор + его дети-неконнекторы,
## приклеенные вплотную к стенам коннектора). Единицы ставятся от центра наружу спиральной
## укладкой; каждая — в свою желаемую клетку, иначе спиралью ищется ближайшая свободная.
## Внутри кластера зазора нет (двери прямые), вокруг кластера — улица ≥STREET_CELLS. Детерминированно.
func _snap_to_cells() -> void:
	var desired: Dictionary = {}
	for id in _rooms.keys():
		var half: Vector2 = _room_size[id] * 0.5
		var corner: Vector2 = _pos2[id] - half
		desired[id] = Vector2i(int(round(corner.x / GRID)), int(round(corner.y / GRID)))

	# Кластеры: коннектор-якорь + его дети-неконнекторы (их ставит кластер, не основной цикл).
	var cluster_of: Dictionary = {}   # childId -> connId
	for id in _rooms.keys():
		if _rooms[id]["kind"] != "connector":
			continue
		for ch in _rooms[id]["children"]:
			if _rooms[ch]["kind"] != "connector":
				cluster_of[ch] = id

	# Единицы упаковки: кластеры (по якорю) и одиночные комнаты; ближе к центру — раньше.
	var units: Array = []
	for id in _rooms.keys():
		if cluster_of.has(id):
			continue
		units.append(id)
	units.sort_custom(func(a, b):
		var da: float = (_pos2[a] as Vector2).length_squared()
		var db: float = (_pos2[b] as Vector2).length_squared()
		if absf(da - db) > 0.01:
			return da < db
		return a < b)

	var blocked: Dictionary = {}   # клетки, занятые футпринтами + зазором
	for id in units:
		if _is_cluster_anchor(id):
			_place_cluster(id, desired, blocked)
		else:
			var member := _rect_cells(Vector2i.ZERO, _room_cells[id])
			var off: Vector2i = _place_unit(member, desired[id], blocked)
			_room_cell[id] = off
			_block_unit(member, off, blocked)


## Коннектор-якорь = коннектор, у которого есть хотя бы один ребёнок-неконнектор.
func _is_cluster_anchor(id: int) -> bool:
	if _rooms[id]["kind"] != "connector":
		return false
	for ch in _rooms[id]["children"]:
		if _rooms[ch]["kind"] != "connector":
			return true
	return false


## Ставит кластер (коннектор + дети-неконнекторы вплотную) единым жёстким блоком и регистрирует
## прямые проёмы коннектор↔ребёнок. Коннектор при необходимости растёт, чтобы стена вместила детей.
func _place_cluster(conn: int, desired: Dictionary, blocked: Dictionary) -> void:
	var layout := _build_cluster_layout(conn)
	var member: Dictionary = layout["member"]
	var off: Vector2i = _place_unit(member, desired[conn], blocked)
	_block_unit(member, off, blocked)
	for rid in layout["tops"]:
		_room_cell[rid] = (layout["tops"][rid] as Vector2i) + off
	for op in layout["openings"]:
		_add_opening(op["a"], (op["acell"] as Vector2i) + off, op["adir"])
		_room_entrance[op["b"]] = _add_opening(op["b"], (op["bcell"] as Vector2i) + off, op["bdir"])
		_direct_child[op["b"]] = true


## Локальная раскладка кластера (коннектор в (0,0)): распределяет детей по сторонам по направлению
## из утряски, при тесноте растит коннектор по нужной оси, стопкой клеит детей вплотную к стенам.
## Возвращает {member: клетки-локально, tops: roomId->левый-верх локально, openings:[...]}.
func _build_cluster_layout(conn: int) -> Dictionary:
	var base: Vector2i = _room_cells[conn]
	var sides := {"E": [], "W": [], "N": [], "S": []}
	for ch in _rooms[conn]["children"]:
		if _rooms[ch]["kind"] == "connector":
			continue
		var d: Vector2 = _pos2[ch] - _pos2[conn]
		if absf(d.x) >= absf(d.y):
			sides["E" if d.x >= 0.0 else "W"].append(ch)
		else:
			sides["S" if d.y >= 0.0 else "N"].append(ch)

	# Рост коннектора: стена вдоль оси должна вместить сумму детей этой стороны встык.
	var w: int = maxi(base.x, maxi(_sum_axis(sides["N"], true), _sum_axis(sides["S"], true)))
	var h: int = maxi(base.y, maxi(_sum_axis(sides["E"], false), _sum_axis(sides["W"], false)))
	_room_cells[conn] = Vector2i(w, h)
	_room_size[conn] = Vector2(w, h) * GRID

	var member: Dictionary = {}
	_add_rect(member, Vector2i.ZERO, Vector2i(w, h))
	var tops: Dictionary = {conn: Vector2i.ZERO}
	var openings: Array = []

	# Вертикальные стены (E/W): дети стопкой по строкам, выровнены по центру стены.
	for key in ["E", "W"]:
		@warning_ignore("integer_division")
		var cur: int = (h - _sum_axis(sides[key], false)) / 2
		for ch in sides[key]:
			var ks: Vector2i = _room_cells[ch]
			var cx: int = w if key == "E" else -ks.x
			tops[ch] = Vector2i(cx, cur)
			_add_rect(member, tops[ch], ks)
			@warning_ignore("integer_division")
			var rm: int = clampi(cur + ks.y / 2, 0, h - 1)
			if key == "E":
				openings.append({"a": conn, "acell": Vector2i(w - 1, rm), "adir": Vector2i(1, 0),
						"b": ch, "bcell": Vector2i(w, rm), "bdir": Vector2i(-1, 0)})
			else:
				openings.append({"a": conn, "acell": Vector2i(0, rm), "adir": Vector2i(-1, 0),
						"b": ch, "bcell": Vector2i(-1, rm), "bdir": Vector2i(1, 0)})
			cur += ks.y

	# Горизонтальные стены (N/S): дети стопкой по столбцам, выровнены по центру стены.
	for key in ["N", "S"]:
		@warning_ignore("integer_division")
		var cur: int = (w - _sum_axis(sides[key], true)) / 2
		for ch in sides[key]:
			var ks: Vector2i = _room_cells[ch]
			var cy: int = h if key == "S" else -ks.y
			tops[ch] = Vector2i(cur, cy)
			_add_rect(member, tops[ch], ks)
			@warning_ignore("integer_division")
			var cm: int = clampi(cur + ks.x / 2, 0, w - 1)
			if key == "S":
				openings.append({"a": conn, "acell": Vector2i(cm, h - 1), "adir": Vector2i(0, 1),
						"b": ch, "bcell": Vector2i(cm, h), "bdir": Vector2i(0, -1)})
			else:
				openings.append({"a": conn, "acell": Vector2i(cm, 0), "adir": Vector2i(0, -1),
						"b": ch, "bcell": Vector2i(cm, -1), "bdir": Vector2i(0, 1)})
			cur += ks.x

	return {"member": member, "tops": tops, "openings": openings}


## Сумма размеров детей вдоль оси стены (по X при along_x, иначе по Y), в клетках.
func _sum_axis(children: Array, along_x: bool) -> int:
	var n := 0
	for ch in children:
		var ks: Vector2i = _room_cells[ch]
		n += ks.x if along_x else ks.y
	return n


func _rect_cells(origin: Vector2i, size: Vector2i) -> Dictionary:
	var out: Dictionary = {}
	_add_rect(out, origin, size)
	return out


func _add_rect(into: Dictionary, origin: Vector2i, size: Vector2i) -> void:
	for dx in size.x:
		for dy in size.y:
			into[Vector2i(origin.x + dx, origin.y + dy)] = true


## Спиральный поиск свободного смещения для набора клеток member вокруг желаемого desired.
func _place_unit(member: Dictionary, desired: Vector2i, blocked: Dictionary) -> Vector2i:
	var r := 0
	while r <= PLACE_MAX_RADIUS:
		for off in _ring(r):
			var cand: Vector2i = desired + off
			if _fits_unit(member, cand, blocked):
				return cand
		r += 1
	return desired


## Влезает ли набор клеток (со сдвигом off) с зазором-улицей STREET_CELLS от уже занятых.
func _fits_unit(member: Dictionary, off: Vector2i, blocked: Dictionary) -> bool:
	for c in member:
		for dx in range(-STREET_CELLS, STREET_CELLS + 1):
			for dy in range(-STREET_CELLS, STREET_CELLS + 1):
				if blocked.has(Vector2i(c.x + off.x + dx, c.y + off.y + dy)):
					return false
	return true


## Резервирует набор клеток (со сдвигом), расширенный на STREET_CELLS ⇒ соседи держат зазор.
func _block_unit(member: Dictionary, off: Vector2i, blocked: Dictionary) -> void:
	for c in member:
		for dx in range(-STREET_CELLS, STREET_CELLS + 1):
			for dy in range(-STREET_CELLS, STREET_CELLS + 1):
				blocked[Vector2i(c.x + off.x + dx, c.y + off.y + dy)] = true


## Клетки-смещения на «кольце» Чебышёва радиуса r (r=0 — сам центр).
func _ring(r: int) -> Array:
	if r == 0:
		return [Vector2i.ZERO]
	var out: Array = []
	for x in range(-r, r + 1):
		out.append(Vector2i(x, -r))
		out.append(Vector2i(x, r))
	for y in range(-r + 1, r):
		out.append(Vector2i(-r, y))
		out.append(Vector2i(r, y))
	return out


## Сдвигает сетку в мир так, чтобы корень был у начала координат; считает центры комнат.
func _finalize_positions() -> void:
	var rc: Vector2i = _room_cell[_root_id]
	var rcw: Vector2i = _room_cells[_root_id]
	_shift = -Vector3((rc.x + rcw.x * 0.5) * GRID, 0.0, (rc.y + rcw.y * 0.5) * GRID)
	for id in _rooms.keys():
		var c: Vector2i = _room_cell[id]
		var cw: Vector2i = _room_cells[id]
		_positions[id] = _cell_world(c.x + cw.x * 0.5, c.y + cw.y * 0.5)


func _fill_occupancy() -> void:
	for id in _rooms.keys():
		var c: Vector2i = _room_cell[id]
		var cw: Vector2i = _room_cells[id]
		for dx in cw.x:
			for dy in cw.y:
				_occ[Vector2i(c.x + dx, c.y + dy)] = id


func _cell_world(col: float, row: float) -> Vector3:
	return Vector3(col * GRID, 0.0, row * GRID) + _shift


# --- Фаза 4: ортогональный роутинг коридоров по улицам ---

func _route_corridors() -> void:
	# Порядок — BFS от корня (короткие локальные маршруты раньше).
	var order: Array = [_root_id]
	var qi := 0
	while qi < order.size():
		var id: int = order[qi]
		qi += 1
		for ch in _rooms[id]["children"]:
			# Дети-неконнекторы коннектора уже соединены прямым проёмом (кластер) — без коридора.
			if not _direct_child.has(ch):
				_route_edge(id, ch)
			order.append(ch)


func _route_edge(a: int, b: int) -> void:
	# Сначала строго по свободным улицам (коридоры не пересекаются), иначе разрешаем
	# проходить по чужим коридорам (общая клетка-перекрёсток, один пол), иначе фолбэк.
	if _bfs_route(a, b, false):
		return
	if _bfs_route(a, b, true):
		return
	_fallback_route(a, b)


## BFS по клеткам сетки от кольца вокруг a до клетки, смежной с b. allow_corr — можно ли
## проходить по уже проложенным коридорам. Возвращает успех; при успехе резервирует путь
## и регистрирует проёмы у a и b.
func _bfs_route(a: int, b: int, allow_corr: bool) -> bool:
	var lo := Vector2i.ZERO
	var hi := Vector2i.ZERO
	var bounds := _route_bounds(a, b)
	lo = bounds[0]
	hi = bounds[1]

	var came: Dictionary = {}        # cell -> предыдущая клетка (источник указывает на себя)
	var src_room: Dictionary = {}    # source cell -> клетка-стена a, к которой он примыкает
	var frontier: Array = []
	for bc in _border_cells(a):
		for d in _dirs:
			var nb: Vector2i = bc + d
			if _occ.get(nb, CORR - 1) == a:
				continue
			if not _in_bounds(nb, lo, hi) or _passable(nb, allow_corr) == false:
				continue
			if not came.has(nb):
				came[nb] = nb
				src_room[nb] = bc
				frontier.append(nb)

	var qi := 0
	var goal := Vector2i.ZERO
	var goal_b := Vector2i.ZERO
	var found := false
	while qi < frontier.size():
		var cur: Vector2i = frontier[qi]
		qi += 1
		var bcell := _adjacent_to(cur, b)
		if bcell.x != 2147483647:
			goal = cur
			goal_b = bcell
			found = true
			break
		for d in _dirs:
			var nb: Vector2i = cur + d
			if came.has(nb) or not _in_bounds(nb, lo, hi):
				continue
			if _passable(nb, allow_corr):
				came[nb] = cur
				frontier.append(nb)
	if not found:
		return false

	# Восстановление пути источник..goal.
	var path: Array = []
	var node := goal
	while true:
		path.append(node)
		var p: Vector2i = came[node]
		if p == node:
			break
		node = p
	path.reverse()

	for c in path:
		_occ[c] = CORR
		_corr_cells[c] = true

	# Проёмы: у a — между его стеной и первой клеткой пути; у b — между последней и b.
	var a_wall: Vector2i = src_room[path[0]]
	_add_opening(a, a_wall, path[0] - a_wall)
	_room_entrance[b] = _add_opening(b, goal_b, goal - goal_b)
	return true


## Прямой манхэттенский тоннель как крайняя мера (если улицы переполнены). Может пройти
## близко к комнатам, но гарантирует достижимость поддерева.
func _fallback_route(a: int, b: int) -> void:
	var ca: Vector2i = _room_cell[a]
	var cwa: Vector2i = _room_cells[a]
	var cb: Vector2i = _room_cell[b]
	var cwb: Vector2i = _room_cells[b]
	@warning_ignore("integer_division")
	var ac := Vector2i(ca.x + cwa.x / 2, ca.y + cwa.y / 2)
	@warning_ignore("integer_division")
	var bc := Vector2i(cb.x + cwb.x / 2, cb.y + cwb.y / 2)
	var da := _toward(ac, bc)
	var db := _toward(bc, ac)
	var a_wall := _border_toward(a, da)
	var b_wall := _border_toward(b, db)
	var start := a_wall + da
	var goal := b_wall + db
	var path := _manhattan(start, goal)
	for c in path:
		if not _occ.has(c) or _occ[c] == CORR:
			_occ[c] = CORR
		_corr_cells[c] = true
	_add_opening(a, a_wall, da)
	_room_entrance[b] = _add_opening(b, b_wall, db)


func _route_bounds(a: int, b: int) -> Array:
	var ca: Vector2i = _room_cell[a]
	var cwa: Vector2i = _room_cells[a]
	var cb: Vector2i = _room_cell[b]
	var cwb: Vector2i = _room_cells[b]
	var lo := Vector2i(min(ca.x, cb.x), min(ca.y, cb.y)) - Vector2i(ROUTE_EXPAND, ROUTE_EXPAND)
	var hi := Vector2i(max(ca.x + cwa.x, cb.x + cwb.x), max(ca.y + cwa.y, cb.y + cwb.y)) + Vector2i(ROUTE_EXPAND, ROUTE_EXPAND)
	return [lo, hi]


func _in_bounds(c: Vector2i, lo: Vector2i, hi: Vector2i) -> bool:
	return c.x >= lo.x and c.x <= hi.x and c.y >= lo.y and c.y <= hi.y


func _passable(cell: Vector2i, allow_corr: bool) -> bool:
	if not _occ.has(cell):
		return true
	return allow_corr and _occ[cell] == CORR


## Клетки-стены комнаты (периметр футпринта).
func _border_cells(id: int) -> Array:
	var c: Vector2i = _room_cell[id]
	var cw: Vector2i = _room_cells[id]
	var out: Array = []
	for dx in cw.x:
		for dy in cw.y:
			if dx == 0 or dy == 0 or dx == cw.x - 1 or dy == cw.y - 1:
				out.append(Vector2i(c.x + dx, c.y + dy))
	return out


## Клетка комнаты id, смежная с cell (или sentinel x=2147483647, если нет).
func _adjacent_to(cell: Vector2i, id: int) -> Vector2i:
	for d in _dirs:
		var nb: Vector2i = cell + d
		if _occ.get(nb, CORR - 1) == id:
			return nb
	return Vector2i(2147483647, 0)


## Регистрирует проём в стене комнаты id: room_cell — клетка-стена, d — наружу (в коридор).
## Возвращает запись проёма {key, lo, hi} (новую либо уже существующую) — вызывающий
## помечает ей вход-от-родителя для вывески-заголовка над проходом.
func _add_opening(id: int, room_cell: Vector2i, d: Vector2i) -> Dictionary:
	var c0: Vector2i = _room_cell[id]
	var cw: Vector2i = _room_cells[id]
	var key := _dir_key(d)
	# Проём идёт вдоль стены: у стен ±x — по оси Y (cw.y), у стен ±z — по оси X (cw.x).
	var span: int = cw.y if d.x != 0 else cw.x
	var k: int = (room_cell.y - c0.y) if d.x != 0 else (room_cell.x - c0.x)
	var lo := (-span * 0.5 + float(k)) * GRID
	var op := {"key": key, "lo": lo, "hi": lo + GRID}
	if not _room_openings.has(id):
		_room_openings[id] = []
	# Не дублируем один и тот же проём (две дороги в одну клетку-стену).
	for o in _room_openings[id]:
		if o["key"] == key and absf(o["lo"] - lo) < 0.01:
			return o
	_room_openings[id].append(op)
	return op


func _dir_key(d: Vector2i) -> String:
	if d == Vector2i(1, 0):
		return "px"
	if d == Vector2i(-1, 0):
		return "nx"
	if d == Vector2i(0, 1):
		return "pz"
	return "nz"


func _toward(from: Vector2i, to: Vector2i) -> Vector2i:
	var dx := to.x - from.x
	var dy := to.y - from.y
	if abs(dx) >= abs(dy):
		return Vector2i(signi(dx), 0) if dx != 0 else Vector2i(1, 0)
	return Vector2i(0, signi(dy))


## Клетка-стена комнаты в направлении d (середина соответствующей стороны).
func _border_toward(id: int, d: Vector2i) -> Vector2i:
	var c: Vector2i = _room_cell[id]
	var cw: Vector2i = _room_cells[id]
	if d == Vector2i(1, 0):
		@warning_ignore("integer_division")
		return Vector2i(c.x + cw.x - 1, c.y + cw.y / 2)
	if d == Vector2i(-1, 0):
		@warning_ignore("integer_division")
		return Vector2i(c.x, c.y + cw.y / 2)
	if d == Vector2i(0, 1):
		@warning_ignore("integer_division")
		return Vector2i(c.x + cw.x / 2, c.y + cw.y - 1)
	@warning_ignore("integer_division")
	return Vector2i(c.x + cw.x / 2, c.y)


func _manhattan(start: Vector2i, goal: Vector2i) -> Array:
	var out: Array = []
	var cur := start
	out.append(cur)
	while cur.x != goal.x:
		cur += Vector2i(signi(goal.x - cur.x), 0)
		out.append(cur)
	while cur.y != goal.y:
		cur += Vector2i(0, signi(goal.y - cur.y))
		out.append(cur)
	return out


# --- Фаза 5: геометрия ---

func _build_room(id: int, parent: Node3D, on_transition: Callable) -> void:
	var room: Dictionary = _rooms[id]
	var holder := Node3D.new()
	holder.name = "Room_%d" % id
	holder.position = _positions[id]
	parent.add_child(holder)
	if _debug:
		_attach_debug(holder, _room_debug_text(id))

	var is_connector: bool = room["kind"] == "connector"
	var size: Vector2 = _room_size[id]
	var floor_color := _room_color(room, is_connector)
	_add_box(holder, Vector3(size.x, 0.4, size.y), Vector3(0, -0.2, 0), floor_color, true)
	_build_walls(holder, id, floor_color.lightened(0.1))
	# Заголовок секции (первый объект-heading комнаты) — вывеска над входным проёмом, читаемая
	# с обеих сторон. Удаётся только если у комнаты есть вход от родителя; иначе (корень)
	# заголовок остаётся настенной табличкой, как обычный объект.
	var title_obj = _room_title_object(id)
	var titled: bool = title_obj != null and _build_room_title(holder, id, title_obj)
	_place_objects(room, holder, on_transition, title_obj if titled else null)


## Четыре стены; на каждой вычитаем интервалы-проёмы (_room_openings) и ставим сегменты.
func _build_walls(holder: Node3D, id: int, color: Color) -> void:
	var size: Vector2 = _room_size[id]
	var h: float = _room_wall_h[id]
	var half_x := size.x * 0.5
	var half_z := size.y * 0.5
	var ops: Array = _room_openings.get(id, [])
	for w in _wall_defs():
		# along_half — половина длины стены (по ней режем проёмы); off_half — отступ стены от центра.
		var along_half: float = half_z if w["kind"] == "x" else half_x
		var off_half: float = half_x if w["kind"] == "x" else half_z
		var gaps: Array = []
		for o in ops:
			if o["key"] == w["key"]:
				gaps.append([o["lo"], o["hi"]])
		gaps.sort_custom(func(p, q): return p[0] < q[0])
		var cursor := -along_half
		for g in gaps:
			_add_wall_seg(holder, w, cursor, g[0], off_half, h, color)
			cursor = g[1]
		_add_wall_seg(holder, w, cursor, along_half, off_half, h, color)


func _wall_defs() -> Array:
	return [
		{"kind": "x", "sign": 1.0, "yaw": -PI * 0.5, "key": "px"},
		{"kind": "x", "sign": -1.0, "yaw": PI * 0.5, "key": "nx"},
		{"kind": "z", "sign": 1.0, "yaw": PI, "key": "pz"},
		{"kind": "z", "sign": -1.0, "yaw": 0.0, "key": "nz"},
	]


func _add_wall_seg(holder: Node3D, w: Dictionary, lo: float, hi: float, off_half: float, h: float, color: Color) -> void:
	if hi - lo <= 0.05:
		return
	var center := (lo + hi) * 0.5
	var length := hi - lo
	# Сдвигаем стену внутрь комнаты на половину толщины: внешняя грань ложится точно на границу
	# комнаты. У комнат/коннекторов вплотную стены стыкуются грань-в-грань — без дырок и z-fight.
	var off: float = off_half - WALL_THICK * 0.5
	if w["kind"] == "x":
		_add_box(holder, Vector3(WALL_THICK, h, length), Vector3(w["sign"] * off, h * 0.5, center), color, true)
	else:
		_add_box(holder, Vector3(length, h, WALL_THICK), Vector3(center, h * 0.5, w["sign"] * off), color, true)


## Расставляет объекты по стенам в порядке чтения: стены обходятся по часовой стрелке
## (см. _object_walls), внутри стены — слева направо (курсор u растёт от левого края, см.
## _mk_span/_span_pos). Курсор двигается на ширину объекта + зазор; если объект не влезает
## в остаток текущего пролёта — переходим к следующему (следующая стена/интервал).
func _place_objects(room: Dictionary, holder: Node3D, on_transition: Callable, skip_obj = null) -> void:
	var objs: Array = room["objects"]
	if objs.is_empty():
		return
	var spans := _wall_spans(room["id"])
	if spans.is_empty():
		return
	var si := 0
	for obj in objs:
		# Заголовок, ушедший вывеской над входом, на стене не дублируем.
		if skip_obj != null and obj["id"] == skip_obj["id"]:
			continue
		var w: float = _object_size[obj["id"]].x
		while si < spans.size() and spans[si]["cursor"] + w > spans[si]["length"] + 0.001:
			si += 1
		if si >= spans.size():
			si = spans.size() - 1
		var span: Dictionary = spans[si]
		var u: float = span["cursor"] + w * 0.5
		span["cursor"] = span["cursor"] + w + OBJECT_GAP
		var local_pos := _span_pos(span, u)
		if obj["id"] == _first_obj_id:
			_record_spawn(room["id"], holder.position, local_pos, span["w"])
		_build_object(obj, holder, local_pos, span["w"]["yaw"], on_transition)


## Запоминает геометрию первого объекта для спавна: его мир-позицию, направление внутрь
## комнаты от его стены и потолок отступа (чтобы спавн не вылез за противоположную стену).
func _record_spawn(room_id: int, holder_pos: Vector3, local_pos: Vector3, w: Dictionary) -> void:
	var size: Vector2 = _room_size[room_id]
	var along: float = size.x if w["kind"] == "x" else size.y
	_spawn_obj_world = holder_pos + local_pos
	_spawn_inward = _wall_inward(w)
	_spawn_max_d = along - OBJECT_INSET - 1.0
	_has_spawn_obj = true


## Направление от стены внутрь комнаты (противоположно наружной нормали стены).
func _wall_inward(w: Dictionary) -> Vector3:
	if w["kind"] == "x":
		return Vector3(-w["sign"], 0.0, 0.0)
	return Vector3(0.0, 0.0, -w["sign"])


## Объект-заголовок секции = первый объект комнаты типа "heading" (см. TopologyBuilder:
## заголовок секции кладётся первым). Иначе null (преамбула/коннектор без подписи).
func _room_title_object(id: int):
	var objs: Array = _rooms[id]["objects"]
	if objs.is_empty():
		return null
	var first: Dictionary = objs[0]
	@warning_ignore("incompatible_ternary")
	return first if first.get("type", "") == "heading" else null


## Вывеска-заголовок над входным проёмом комнаты (вход = проём от родителя, _room_entrance).
## Лентой-перемычкой садится в верх проёма; текст дублируется двумя Label3D — внутрь и наружу,
## поэтому название читается и из комнаты, и снаружи. Возвращает false, если входа нет (корень)
## или текст пуст — тогда заголовок остаётся обычной настенной табличкой.
func _build_room_title(holder: Node3D, id: int, title_obj: Dictionary) -> bool:
	var op = _room_entrance.get(id, null)
	if op == null:
		return false
	var text := _truncate(_obj_text(title_obj).strip_edges(), 80)
	if text == "":
		return false

	var size: Vector2 = _room_size[id]
	var half_x := size.x * 0.5
	var half_z := size.y * 0.5
	var wall_h: float = _room_wall_h[id]
	var key: String = op["key"]
	var along: float = (float(op["lo"]) + float(op["hi"])) * 0.5
	var opening_w: float = float(op["hi"]) - float(op["lo"])

	var level: int = int(title_obj.get("content", {}).get("level", 2))
	var font_px: float = _base_px * float(HEADING_EM.get(level, 1.0))
	var glyph_m := _px_to_m(font_px)
	var band_h := clampf(glyph_m * 1.5 + 0.2, TITLE_MIN_H, TITLE_MAX_H)
	var band_w := opening_w + 2.0 * TITLE_OVERHANG
	var center_y := wall_h - band_h * 0.5   # лента-перемычка прижата к верху проёма

	var pos := Vector3.ZERO
	var out_n := Vector3.ZERO          # наружная нормаль стены
	var inward_yaw := 0.0              # ориентация Label3D лицом внутрь комнаты
	match key:
		"px":
			pos = Vector3(half_x, center_y, along); out_n = Vector3(1, 0, 0); inward_yaw = -PI * 0.5
		"nx":
			pos = Vector3(-half_x, center_y, along); out_n = Vector3(-1, 0, 0); inward_yaw = PI * 0.5
		"pz":
			pos = Vector3(along, center_y, half_z); out_n = Vector3(0, 0, 1); inward_yaw = PI
		_:  # nz
			pos = Vector3(along, center_y, -half_z); out_n = Vector3(0, 0, -1); inward_yaw = 0.0

	var node := Node3D.new()
	node.position = pos
	holder.add_child(node)
	# Лента-перемычка: тонкая по нормали стены, длинная вдоль проёма.
	var band_size := Vector3(band_w, band_h, WALL_THICK)
	if out_n.x != 0.0:
		band_size = Vector3(WALL_THICK, band_h, band_w)
	_add_box(node, band_size, Vector3.ZERO, Color(0.95, 0.85, 0.4), false)
	var face_off: float = WALL_THICK * 0.5 + 0.02
	_add_title_label(node, text, font_px, band_w, inward_yaw, out_n * -face_off)        # внутрь
	_add_title_label(node, text, font_px, band_w, inward_yaw + PI, out_n * face_off)    # наружу

	if title_obj["id"] == _first_obj_id:
		_record_title_spawn(holder.position + pos, -out_n, key, half_x, half_z)
	return true


## Текст вывески как Label3D, повёрнутый на yaw и сдвинутый на свою грань ленты (offset).
func _add_title_label(node: Node3D, text: String, font_css_px: float, width_m: float,
		yaw: float, offset: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = _godot_font(font_css_px)
	label.outline_size = max(8, int(label.font_size * 0.25))
	label.pixel_size = LABEL_PIXEL_SIZE
	label.width = int(width_m / LABEL_PIXEL_SIZE)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.modulate = Color(0.12, 0.10, 0.0)
	label.rotation.y = yaw
	label.position = offset
	node.add_child(label)


## Спавн, когда первый объект страницы ушёл вывеской над входом: игрок встаёт сразу за
## титульным проёмом и смотрит в комнату (на её центр), въезжая «через заголовок».
func _record_title_spawn(door_world: Vector3, inward: Vector3, key: String,
		half_x: float, half_z: float) -> void:
	var reach: float = half_x if (key == "px" or key == "nx") else half_z
	var d: float = clampf(reach * 0.6, 1.2, 3.0)
	spawn_point = door_world + inward * d + Vector3(0, 1.0, 0)
	spawn_look_at = Vector3(door_world.x, 0.0, door_world.z) + inward * (reach + 1.0) + Vector3(0, 1.6, 0)
	has_spawn_look = true
	_spawn_done = true


func _wall_spans(id: int) -> Array:
	var size: Vector2 = _room_size[id]
	var half_x := size.x * 0.5
	var half_z := size.y * 0.5
	var ops: Array = _room_openings.get(id, [])
	var spans: Array = []
	for w in _object_walls():
		var along_half: float = half_z if w["kind"] == "x" else half_x
		var off_half: float = half_x if w["kind"] == "x" else half_z
		var inset := off_half - OBJECT_INSET
		var along_lo := -along_half + CORNER_MARGIN
		var along_hi := along_half - CORNER_MARGIN
		var gaps: Array = []
		for o in ops:
			if o["key"] == w["key"]:
				gaps.append([o["lo"], o["hi"]])
		gaps.sort_custom(func(p, q): return p[0] < q[0])
		var free := _subtract_gaps(along_lo, along_hi, gaps, DOOR_MARGIN)
		# Интервалы свободны слева направо для зрителя в комнате: у flip-стен «лево» —
		# это высокий конец координаты, поэтому порядок интервалов разворачиваем.
		if w["flip"]:
			free.reverse()
		for iv in free:
			if iv[1] - iv[0] >= 0.6:
				spans.append(_mk_span(w, iv[0], iv[1], inset))
	return spans


## Стены в порядке обхода ПО ЧАСОВОЙ СТРЕЛКЕ (вид сверху, север = -Z):
## север(nz) → восток(px) → юг(pz) → запад(nx). `flip` помечает стены, где «слева направо»
## для зрителя, стоящего в комнате лицом к стене, идёт в сторону УБЫВАНИЯ координаты вдоль стены
## (юг и запад). yaw/sign/key совпадают с _wall_defs (геометрия стен), порядок здесь — только
## для расстановки объектов.
func _object_walls() -> Array:
	return [
		{"kind": "z", "sign": -1.0, "yaw": 0.0, "key": "nz", "flip": false},
		{"kind": "x", "sign": 1.0, "yaw": -PI * 0.5, "key": "px", "flip": false},
		{"kind": "z", "sign": 1.0, "yaw": PI, "key": "pz", "flip": true},
		{"kind": "x", "sign": -1.0, "yaw": PI * 0.5, "key": "nx", "flip": true},
	]


## Свободные интервалы [lo,hi] за вычетом gaps (расширенных margin с каждой стороны).
func _subtract_gaps(lo: float, hi: float, gaps: Array, margin: float) -> Array:
	var free: Array = []
	var cur := lo
	for g in gaps:
		var glo: float = g[0] - margin
		var ghi: float = g[1] + margin
		if glo > cur:
			free.append([cur, minf(glo, hi)])
		cur = maxf(cur, ghi)
		if cur >= hi:
			break
	if cur < hi:
		free.append([cur, hi])
	return free


## Пролёт стены под укладку объектов. Курсор измеряется в u ∈ [0, length] от ЛЕВОГО для
## зрителя края: координата вдоль стены t = base_t + sign_u·u. У flip-стен лево — высокий
## конец (base_t = hi, sign_u = -1), у обычных — низкий (base_t = lo, sign_u = +1).
func _mk_span(w: Dictionary, lo: float, hi: float, inset: float) -> Dictionary:
	var base_t: float = hi if w["flip"] else lo
	var sign_u: float = -1.0 if w["flip"] else 1.0
	return {"w": w, "base_t": base_t, "sign_u": sign_u, "length": hi - lo, "inset": inset, "cursor": 0.0}


func _span_pos(span: Dictionary, u: float) -> Vector3:
	var w: Dictionary = span["w"]
	var inset: float = span["inset"]
	var t: float = span["base_t"] + span["sign_u"] * u
	if w["kind"] == "x":
		return Vector3(w["sign"] * inset, 0.0, t)
	return Vector3(t, 0.0, w["sign"] * inset)


## Полы коридоров — по одному GRID-квадрату на коридорную клетку.
func _build_corridor_floors(parent: Node3D) -> void:
	for cell in _corr_cells.keys():
		var holder := Node3D.new()
		holder.position = _cell_world(cell.x + 0.5, cell.y + 0.5)
		parent.add_child(holder)
		_add_box(holder, Vector3(GRID, 0.4, GRID), Vector3(0, -0.2, 0), Color(0.3, 0.3, 0.33), true)


# --- Объекты комнаты ---

func _build_object(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> void:
	var node := _spawn_object(obj, holder, local_pos, yaw, on_transition)
	# Провенанс объекта вешаем на его корневой узел: отладочный пробник прицела поднимается
	# от коллайдера к ближайшему предку с метаданными (см. Player._find_debug_meta).
	if _debug and node != null:
		_attach_debug(node, _object_debug_text(obj))


## Создаёт 3D-представление объекта и возвращает его корневой узел (для привязки провенанса).
func _spawn_object(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> Node3D:
	var fn = obj.get("function", null)
	var is_link: bool = fn != null and typeof(fn) == TYPE_DICTIONARY

	if obj.get("type", "") == "image":
		return _build_image_panel(obj, holder, local_pos, yaw, fn if is_link else null, on_transition)

	# <figure> рендерим как картину (alt = подпись из <figcaption>).
	if obj.get("type", "") == "figure":
		return _build_image_panel(obj, holder, local_pos, yaw, null, on_transition)

	if obj.get("type", "") == "media" and obj.get("content", {}).get("media_tag", "") == "video":
		var screen := _build_video_screen(obj, holder, local_pos, yaw)
		if screen != null:
			return screen
		# Нет src или аддон FFmpeg недоступен — падаем на статичную заглушку-панель ниже.

	if is_link:
		var portal: Portal = PORTAL_SCENE.instantiate()
		portal.setup(fn, _obj_text(obj))
		holder.add_child(portal)
		portal.position = local_pos
		portal.rotation.y = yaw
		if on_transition.is_valid():
			portal.activated.connect(on_transition)
		return portal

	var runs: Array = obj.get("content", {}).get("runs", [])
	if obj.get("type", "") == "text" and not runs.is_empty():
		if _runs_have_links(runs) or _obj_text(obj).length() > 200:
			return _build_rich_panel(runs, holder, local_pos, yaw, on_transition)

	match obj.get("type", "text"):
		"heading":
			var level: int = int(obj.get("content", {}).get("level", 2))
			var px: float = _base_px * float(HEADING_EM.get(level, 1.0))
			return _build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.95, 0.85, 0.4), px)
		"media":
			return _build_panel(holder, local_pos, yaw, "▷ " + _obj_text(obj),
				Color(0.25, 0.25, 0.3), _base_px)
		"button", "input":
			return _build_panel(holder, local_pos, yaw, "▢ " + _obj_text(obj),
				Color(0.5, 0.7, 0.5), _base_px)
		"list":
			if _list_has_links(obj) or _list_has_images(obj):
				return _build_rich_panel(_list_runs(obj), holder, local_pos, yaw, on_transition)
			return _build_panel(holder, local_pos, yaw, _list_text(obj),
				Color(0.6, 0.6, 0.65), _base_px)
		"table":
			if _table_has_links(obj) or _table_has_images(obj):
				return _build_rich_panel(_table_runs(obj), holder, local_pos, yaw, on_transition)
			return _build_panel(holder, local_pos, yaw, _table_text(obj),
				Color(0.55, 0.6, 0.6), _base_px * 0.9)
		"code":
			# Блок кода: отдельная тёмная панель (моноширинный рендер — на будущее).
			return _build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.16, 0.18, 0.22), _base_px)
		"quote":
			var qruns: Array = obj.get("content", {}).get("runs", [])
			if not qruns.is_empty() and _runs_have_links(qruns):
				return _build_rich_panel(qruns, holder, local_pos, yaw, on_transition)
			return _build_panel(holder, local_pos, yaw, "« " + _obj_text(obj) + " »",
				Color(0.38, 0.40, 0.5), _base_px)
		_:
			return _build_panel(holder, local_pos, yaw, _obj_text(obj),
				Color(0.85, 0.85, 0.85), _base_px)


func _build_panel(holder: Node3D, local_pos: Vector3, yaw: float, text: String, color: Color, font_css_px: float) -> Node3D:
	var node := Node3D.new()
	holder.add_child(node)
	node.position = local_pos
	node.rotation.y = yaw
	var font := _godot_font(font_css_px)
	var glyph_m := _px_to_m(font_css_px)
	var clipped := _truncate(text, 220)
	var height := _panel_height(clipped, glyph_m)
	# Центр панели — на уровне глаз (а не низом на полу): мелкие таблички висят перед
	# лицом, высокие приподняты так, чтобы низ не вжимался в пол (PANEL_FLOOR_GAP).
	var center_y := maxf(EYE_LEVEL, height * 0.5 + PANEL_FLOOR_GAP)
	_add_box(node, Vector3(PANEL_WIDTH_M, height, 0.15), Vector3(0, center_y, 0), color, false)
	var label := Label3D.new()
	label.text = clipped
	label.font_size = font
	label.outline_size = max(8, int(font * 0.25))
	label.pixel_size = LABEL_PIXEL_SIZE
	label.width = int(PANEL_WIDTH_M / LABEL_PIXEL_SIZE)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector3(0, center_y, 0.1)
	node.add_child(label)
	return node


func _panel_height(text: String, glyph_m: float) -> float:
	var char_w: float = max(0.001, glyph_m * 0.5)
	var per_line: float = max(1.0, PANEL_WIDTH_M / char_w)
	var explicit := 1 + text.count("\n")
	var wrapped := int(ceil(text.length() / per_line))
	var lines: int = max(explicit, wrapped)
	# Потолок 3.0 м: с центрированием на уровне глаз более высокая панель пробивала бы
	# потолок. Текст сюда и так приходит обрезанным (_truncate до 220 символов).
	return clampf(lines * glyph_m * 1.5 + 0.4, 1.0, 3.0)


func _build_rich_panel(runs: Array, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> Node3D:
	var panel: RichPanel = RICH_PANEL_SCENE.instantiate()
	panel.setup(runs, _px_to_m(_base_px))
	holder.add_child(panel)
	panel.rotation.y = yaw
	# Центр панели на уровне глаз; высота капнута в RichPanel, поэтому низ не уходит в пол.
	var half := panel.get_height_m() * 0.5
	panel.position = local_pos + Vector3(0, maxf(EYE_LEVEL, half + PANEL_FLOOR_GAP), 0)
	if on_transition.is_valid():
		panel.link_activated.connect(on_transition)
	return panel


func _build_image_panel(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float,
		transition, on_transition: Callable) -> Node3D:
	var content: Dictionary = obj.get("content", {})
	var alt: String = str(content.get("alt", content.get("text", "")))
	var want_w := _px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _px_to_m(float(content.get("height_px", 0.0)))
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
	return panel


## Строит экран для HTML-тега <video>: тот же VrwebVideoScreen, что и кастомный VRWeb-тег
## (см. docs/video-player.md). Привязку к (неявному) плееру и докачку делает VrwebVideoManager
## при scan. Возвращает null, если нет src или недоступен аддон FFmpeg — тогда рисуем заглушку.
func _build_video_screen(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float) -> Node3D:
	var content: Dictionary = obj.get("content", {})
	var src: String = str(content.get("src", ""))
	if src == "" or not VrwebVideoPlayer.is_available():
		return null
	var url := PageFetcher.resolve_url(src, _base_url)
	var size: Vector2 = _object_size.get(obj["id"], _measure_video(obj))
	var screen := VrwebVideoScreen.new()
	# Ширину фиксируем под раскладку комнаты, высоту 0 — экран сам подгонит её под пропорции
	# кадра (как ImagePanel под текстуру). Неявный плеер ключуется по url в менеджере.
	screen.setup("", url, Vector2(size.x, 0.0))
	screen.autoplay = bool(content.get("autoplay", false))
	screen.loop = bool(content.get("loop", false))
	holder.add_child(screen)
	# Корень эктора на полу; центр квада поднимаем на уровень глаз (как ImagePanel/панели),
	# чтобы низ высокого экрана не уходил под пол.
	var center_y := maxf(EYE_LEVEL, size.y * 0.5 + PANEL_FLOOR_GAP)
	screen.position = local_pos + Vector3(0.0, center_y, 0.0)
	screen.rotation.y = yaw
	return screen


func _runs_have_links(runs: Array) -> bool:
	for r in runs:
		if r.get("function", null) != null:
			return true
	return false


## Есть ли среди прогонов картинка — повод отрисовать список/таблицу богатой панелью
## (RichPanel показывает картинку-прогон), а не плоской текстовой табличкой.
func _runs_have_images(runs: Array) -> bool:
	for r in runs:
		if str(r.get("type", "")) == "image":
			return true
	return false


func _list_has_images(obj: Dictionary) -> bool:
	for it in obj.get("content", {}).get("items", []):
		if _runs_have_images(it.get("runs", [])):
			return true
	return false


func _table_has_images(obj: Dictionary) -> bool:
	for row in obj.get("content", {}).get("rows", []):
		for cell in row.get("cells", []):
			if _runs_have_images(cell.get("runs", [])):
				return true
	return false


# --- Атмосфера (свет + небо), процедурно из данных страницы ---

func _build_atmosphere(parent: Node3D, root_id: int) -> void:
	var palette := _collect_bg_colors()

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

	var weight := float(_rooms[root_id]["hints"].get("weight", 0))
	var richness := clampf(weight / 30.0, 0.0, 1.0)
	var elevation := deg_to_rad(lerpf(8.0, 65.0, richness))

	_rng.seed = _seed ^ 0x9E3779B9
	var azimuth := deg_to_rad(_rng.randf() * 360.0)

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


# --- Метки якорей ---

func _resolve_labels(labels: Dictionary) -> void:
	for anchor_id in labels.keys():
		var target_id: int = labels[anchor_id]
		if _positions.has(target_id):
			label_positions[anchor_id] = _positions[target_id] + Vector3(0, 1.0, 0)
		elif _object_room.has(target_id) and _positions.has(_object_room[target_id]):
			label_positions[anchor_id] = _positions[_object_room[target_id]] + Vector3(0, 1.0, 0)


# --- Отладочный провенанс (тип топологии + исходный HTML) ---

## Кладёт человекочитаемое описание происхождения узла в метаданные DEBUG_META.
## Пробник прицела (Player) читает их и показывает в отладочном оверлее.
func _attach_debug(node: Node, text: String) -> void:
	node.set_meta(DEBUG_META, text)


## Провенанс комнаты/коннектора: тип топологии, семантика, метрики и исходный HTML секции.
func _room_debug_text(id: int) -> String:
	var room: Dictionary = _rooms[id]
	var hints: Dictionary = room.get("hints", {})
	var lines: Array = []
	var kind_ru := "коннектор" if room.get("kind", "") == "connector" else "комната"
	lines.append("● ПРОСТРАНСТВО · %s  #%d" % [kind_ru, id])
	if hints.has("semanticTag"):
		lines.append("семантика: <%s>" % hints["semanticTag"])
	var metrics: Array = ["вес %d" % int(hints.get("weight", 0))]
	if hints.has("degree"):
		metrics.append("степень %d" % int(hints["degree"]))
	metrics.append("объектов %d" % (room.get("objects", []) as Array).size())
	metrics.append("подпространств %d" % (room.get("children", []) as Array).size())
	lines.append(", ".join(metrics))
	if hints.has("css"):
		lines.append("css: %s" % str(hints["css"]))
	_append_source(lines, id)
	return "\n".join(lines)


## Провенанс объекта: тип, функция перехода, родная комната, текст и исходный HTML.
func _object_debug_text(obj: Dictionary) -> String:
	var lines: Array = []
	var oid := int(obj.get("id", -1))
	lines.append("◆ ОБЪЕКТ · %s  #%d" % [obj.get("type", "text"), oid])
	var fn = obj.get("function", null)
	if fn != null and typeof(fn) == TYPE_DICTIONARY:
		var target: String = str(fn.get("href", fn.get("target", "")))
		lines.append("переход: %s %s" % [fn.get("kind", ""), target])
	if _object_room.has(oid):
		lines.append("в пространстве #%d" % int(_object_room[oid]))
	var txt := _obj_text(obj).strip_edges()
	if txt != "":
		lines.append("текст: «%s»" % _truncate(txt, 60))
	_append_source(lines, oid)
	return "\n".join(lines)


## Добавляет схлопнутый исходный HTML узла (если он записан при debug-сборке топологии).
func _append_source(lines: Array, id: int) -> void:
	var src: String = str(_sources.get(id, ""))
	if src.strip_edges() == "":
		return
	lines.append("исходный HTML:")
	lines.append(_collapse_html(src))


## Схлопывает пробелы/переводы строк исходного HTML в одну строку и обрезает для оверлея.
func _collapse_html(html: String) -> String:
	var s := html.strip_edges().replace("\n", " ").replace("\t", " ")
	while s.contains("  "):
		s = s.replace("  ", " ")
	return _truncate(s, 220)


# --- Масштаб (CSS-пиксели страницы -> метры мира) ---

func _px_to_m(px: float) -> float:
	return px * _m_per_px


func _godot_font(css_px: float) -> int:
	return max(8, int(round(css_px * _m_per_px / LABEL_PIXEL_SIZE)))


# --- Низкоуровневые помощники ---

## Боксы (полы/стены) шарят BoxMesh/материал/коллизию через кэши: на тяжёлой странице это
## тысячи узлов, но размеров и цветов среди них немного — ресурсы (Resource, RefCounted)
## безопасно делить между MeshInstance3D, т.к. после создания мы их не мутируем.
func _add_box(holder: Node3D, size: Vector3, local_pos: Vector3, color: Color, collide: bool) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = _shared_box_mesh(size)
	mesh.material_override = _shared_material(color)
	mesh.position = local_pos
	holder.add_child(mesh)
	if collide:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = _shared_box_shape(size)
		body.add_child(shape)
		body.position = local_pos
		holder.add_child(body)


func _shared_box_mesh(size: Vector3) -> BoxMesh:
	if not _box_mesh_cache.has(size):
		var box := BoxMesh.new()
		box.size = size
		_box_mesh_cache[size] = box
	return _box_mesh_cache[size]


func _shared_box_shape(size: Vector3) -> BoxShape3D:
	if not _box_shape_cache.has(size):
		var s := BoxShape3D.new()
		s.size = size
		_box_shape_cache[size] = s
	return _box_shape_cache[size]


func _shared_material(color: Color) -> StandardMaterial3D:
	if not _mat_cache.has(color):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		_mat_cache[color] = mat
	return _mat_cache[color]


func _room_color(room: Dictionary, is_connector: bool) -> Color:
	var css: Dictionary = room["hints"].get("css", {})
	if css.has("bg"):
		var c = _parse_css_color(css["bg"])
		if c != null:
			return c
	if is_connector:
		return Color(0.32, 0.34, 0.4)
	_rng.seed = _seed + room["id"] * 2654435761
	return Color.from_hsv(_rng.randf(), 0.28, 0.7)


func _parse_css_color(value: String):
	value = value.strip_edges().to_lower()
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
