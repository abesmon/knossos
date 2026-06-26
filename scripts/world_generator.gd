class_name WorldGenerator
extends RefCounted

## Фаза геометрии (F) из docs/html-to-3d-topology.md. Превращает раскладку ЕДИНОГО генератора
## пространства (SpaceLayout) в реальное навигируемое 3D-пространство, по которому ходит игрок.
##
## Раскладку (формы комнат из пентамино, их позиции на сетке клеток и коридоры-дорожки)
## целиком считает SpaceLayout — тот же генератор, что кормит отладочный вид сверху
## (scenes/geometry_top_view.gd). WorldGenerator его НЕ дублирует: он только строит геометрию
## из готовых клеточных футпринтов.
##
## Фазы:
##   1. замер объектов     -> футпринт каждой настенной панели (_object_size)
##   2. раскладка           -> SpaceLayout: клетки комнат, двери, коридоры (_consume_layout)
##   3. геометрия           -> полы по клеткам, стены по периметру футпринта с проёмами-дверьми,
##                             полы-коридоры, объекты по стенам (_build_room)
## Случайность — только в цветах/атмосфере (_rng от seed); раскладка детерминирована (seed → SpaceLayout).

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
const GRID := 3.0               # размер клетки сетки SpaceLayout в метрах = ширина коридора/проёма
const WALL_HEIGHT := 3.2        # минимальная высота стен, м
const WALL_THICK := 0.15        # тонкая стена, сдвинутая внутрь комнаты на полтолщины (см. _add_wall_run): у вплотную стоящих комнат стены стыкуются грань-в-грань, без z-fight

# --- Расстановка объектов вдоль дорожек ---
const OBJECT_GAP := 0.2         # зазор между объектами внутри wall-box, м
const OBJECT_BOX_EDGE_PAD := 0.15 # отступ объектов от краёв непрерывного wall-box, м
const OBJECT_FLOOR_OFFSET := 1.0 # общий подъём визуального низа объектов над полом, м
const PULL_INSET := 0.3         # на сколько центр притянутого объекта отстоит от края клетки, м
                                # (объект прижат к краю/стене и смотрит на центр клетки = на дорогу)
const HEAD_CLEARANCE := 0.8     # запас над самым высоким объектом до верха стены, м
const EYE_LEVEL := 1.6          # высота центра текстовых/картиночных панелей, м (= высота камеры игрока)
const PANEL_FLOOR_GAP := 0.3    # минимальный зазор от низа высокой панели до пола, м
const TITLE_OVERHANG := 0.4     # на сколько вывеска-заголовок шире проёма с каждой стороны, м
const TITLE_MIN_H := 0.5        # минимальная высота вывески-заголовка над проходом, м
const TITLE_MAX_H := 1.2        # максимальная высота вывески-заголовка (капает крупные h1), м
# Запасной футпринт портала-ссылки (portal.tscn: 1.2 x 2.2 + подпись над ним).
const PORTAL_W := 1.4
const PORTAL_H := 2.6

# --- Масштаб: единая метрика «1 м мира = PX_PER_METER CSS-пикселей страницы» ---
# От неё считается ВСЁ: размеры шрифтов, ширины панелей, картинки (HTML-размеры и реальное
# разрешение текстуры). Один коэффициент px→м для текста и картинок — поэтому картинки больше
# не нужно подгонять под текст, у них общая линейка. Меняешь это число — консистентно
# пересчитывается весь мир. Должно совпадать с ImagePanel.PX_PER_METER и
# RichPanel.PIXEL_PER_METER (docs/html-to-3d-topology.md §13).
const PX_PER_METER := 128.0
# Label3D разводит мировой размер на растровый кегль (качество) и pixel_size (масштаб):
# растр держим в LABEL_RASTER_SCALE× от css-кегля (крупно, не мылит), а pixel_size выводим
# из метрики — тогда итог font_size * pixel_size = css_px / PX_PER_METER (см. _godot_font),
# а качество растра не зависит от выбранного масштаба мира.
const LABEL_RASTER_SCALE := 1.875
const LABEL_PIXEL_SIZE := 1.0 / (PX_PER_METER * LABEL_RASTER_SCALE)
const PANEL_WIDTH_M := 2.2      # ширина текстовой таблички-Label3D, м
const PANEL_MIN_WIDTH_M := 0.6  # короткие подписи не должны занимать полный настенный блок
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
var _m_per_px := 1.0 / PX_PER_METER
var _rich_font_px := 24

# Визуальный паспорт документа (artifact["document"], см. topology_builder): из них небо,
# земля и палитра комнат берут цвета страницы. Базовый цвет — фон <body> (или средний фон
# страницы); _doc_has_base = был ли вообще цвет (иначе тон уходит к сиду URL).
var _doc_base_color := Color(0.5, 0.5, 0.6)  # база неба/палитры (фон документа)
var _doc_has_base := false                   # нашёлся ли цвет фона (иначе тон от сида)
var _doc_fg                                  # Color|null: цвет текста <body> (земля, акценты)

var _dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# Замеры/раскладка по фазам.
var _object_size: Dictionary = {} # objectId -> Vector2(w, h), м
var _room_wall_h: Dictionary = {} # roomId -> высота стен, м
var _object_room: Dictionary = {} # objectId -> roomId
var _object_nodes: Dictionary = {} # objectId -> Node3D уже созданного объекта
var _wall_boxes: Dictionary = {}  # roomId -> Array[{pull, vary0, vary1, cells, length}]
var _object_placements: Dictionary = {} # roomId -> { objectId -> {box, along, y, pull} }

# Раскладка из SpaceLayout (клетки, двери, коридоры) -> абсолютные клетки на общей сетке.
var _layout: Dictionary = {}      # сырой результат SpaceLayout.build
var _foot: Dictionary = {}        # roomId -> { Vector2i (абс. клетка) -> true }: футпринт-множество
var _foot_cells: Dictionary = {}  # roomId -> Array[Vector2i] (абс): для построения полов
var _room_occ: Dictionary = {}    # Vector2i (абс) -> true: все клетки, занятые комнатами
var _door_edges: Dictionary = {}  # roomId -> { edge_key -> true }: рёбра-двери (проёмы в стенах)
var _door_cells: Dictionary = {}  # roomId -> { Vector2i -> true }: клетки-двери (держим их и проходы свободными от объектов)
var _corr_cells: Dictionary = {}  # Vector2i (абс) -> true: клетки полов-коридоров
var _room_entrance: Dictionary = {} # roomId -> {cell:Vector2i, dir:Vector2i}: проём-вход от родителя
var _positions: Dictionary = {}   # roomId -> Vector3 (центр футпринта в мире)
var _shift := Vector3.ZERO        # сдвиг сетки в мир (корень к началу координат)

# Спавн «у первого объекта страницы, лицом к нему» (считается в фазе геометрии).
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
	# Масштаб фиксирован метрикой PX_PER_METER и НЕ зависит от base_px: «14px шрифт» всегда
	# 14/PX_PER_METER м на любой странице. base_px остаётся лишь для детекции заголовков и
	# расчёта реального css-кегля элементов (em-множители), но не для перевода px→м.
	_m_per_px = 1.0 / PX_PER_METER
	_rich_font_px = max(8, int(round(_px_to_m(_base_px) * RichPanel.PIXEL_PER_METER)))
	_root_id = space.get("root", -1)
	if _root_id == -1 or not _rooms.has(_root_id):
		return

	_measure_objects()                       # фаза 1: размеры объектов (нужны для стен/панелей)
	_consume_layout()                        # фаза 2: раскладка от SpaceLayout -> абс. клетки
	_compute_object_layouts()                # фаза 2b: wall-boxes + упаковка объектов по ним

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
	_build_atmosphere(_container, _root_id)     # фаза 3: атмосфера
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
	var bb := _foot_bbox(_root_id)
	spawn_point = _positions.get(_root_id, Vector3.ZERO) + Vector3(0, 1.0, float(bb.size.y) * GRID * 0.3)


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
		return Vector2(RichPanel.estimate_width_m(runs), RichPanel.estimate_height_m(runs, _rich_font_px))
	if type == "heading" and _runs_have_links(obj.get("content", {}).get("runs", [])):
		return Vector2(RichPanel.estimate_width_m(runs), RichPanel.estimate_height_m(runs, _heading_rich_px(obj)))
	if type == "list" and (_list_has_links(obj) or _list_has_images(obj)):
		var list_runs := _list_runs(obj)
		return Vector2(RichPanel.estimate_width_m(list_runs), RichPanel.estimate_height_m(list_runs, _rich_font_px))
	if type == "table" and (_table_has_links(obj) or _table_has_images(obj)):
		var table_runs := _table_runs(obj)
		return Vector2(RichPanel.estimate_width_m(table_runs), RichPanel.estimate_height_m(table_runs, _rich_font_px))
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
	return _panel_size(_truncate(text, 220), glyph_m)


func _measure_image(obj: Dictionary) -> Vector2:
	var content: Dictionary = obj.get("content", {})
	var want_w := _img_px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _img_px_to_m(float(content.get("height_px", 0.0)))
	var fallback_w := ImagePanel.BASE_WIDTH
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
	# Без потолков/пола: картинка занимает ровно свой размер по метрике 1м=512px (footprint
	# для раскладки совпадает с реальным квадом). Пусть будет хоть крошечной, хоть огромной.
	return Vector2(maxf(0.001, w), maxf(0.001, h))


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


# --- Фаза 2: раскладка от SpaceLayout (единый генератор пространства) ---

## Зовёт SpaceLayout (тот же, что кормит вид сверху), переводит его клеточную раскладку в
## абсолютные клетки на общей сетке и извлекает:
##   _foot/_foot_cells — футпринт каждой комнаты (множество и список клеток);
##   _door_edges       — рёбра-двери (где коридор/примыкание пробивает стену) -> проёмы;
##   _corr_cells       — клетки полов-коридоров (свободные клетки на путях);
##   _room_entrance    — проём-вход от родителя (над ним вешается вывеска-заголовок);
##   _positions/_shift — мировые центры комнат и сдвиг корня к началу координат.
func _consume_layout() -> void:
	_layout = SpaceLayout.new().build(_space, _seed)
	var rooms: Dictionary = _layout.get("rooms", {})

	for id in rooms:
		var rd: Dictionary = rooms[id]
		var pos: Vector2i = rd.get("pos", Vector2i.ZERO)
		var cell_set := {}
		var cell_arr: Array = []
		for c in rd.get("cells", []):
			var a: Vector2i = c + pos
			cell_set[a] = true
			cell_arr.append(a)
			_room_occ[a] = true
		_foot[id] = cell_set
		_foot_cells[id] = cell_arr
		_door_edges[id] = {}
		_door_cells[id] = {}

	# Двери и полы-коридоры из связей родитель→ребёнок. Путь связи: [клетка_родителя, ...,
	# клетка_ребёнка]; концы лежат в комнатах (там проёмы-двери), середина — свободные клетки
	# (полы-коридоры). adjacent-связь — путь из двух примыкающих клеток (прямая дверь).
	for co in _layout.get("corridors", []):
		var path: Array = co.get("path", [])
		if path.size() < 2:
			continue
		var f: int = co["from"]
		var t: int = co["to"]
		var d_from: Vector2i = path[1] - path[0]
		if _door_edges.has(f) and _is_unit(d_from):
			_door_edges[f][_edge_key(path[0], d_from)] = true
			_door_cells[f][path[0]] = true
		var last: int = path.size() - 1
		var d_to: Vector2i = path[last - 1] - path[last]
		if _door_edges.has(t) and _is_unit(d_to):
			_door_edges[t][_edge_key(path[last], d_to)] = true
			_door_cells[t][path[last]] = true
			_room_entrance[t] = {"cell": path[last], "dir": d_to}
		for i in range(1, last):
			_corr_cells[path[i]] = true

	# Сдвиг: центр футпринта корня — в начало координат мира.
	var rootbb := _foot_bbox(_root_id)
	var center := Vector2(rootbb.position) + Vector2(rootbb.size) * 0.5
	_shift = -Vector3(center.x * GRID, 0.0, center.y * GRID)

	for id in rooms:
		_positions[id] = _foot_centroid_world(id)


## Высота стен комнаты: не ниже WALL_HEIGHT, с запасом над самым высоким объектом.
func _wall_height(id: int) -> float:
	var top := 0.0
	var placements: Dictionary = _object_placements.get(id, {})
	for obj_id in placements:
		var p: Dictionary = placements[obj_id]
		var size: Vector2 = _object_size.get(obj_id, Vector2(PANEL_WIDTH_M, 1.0))
		top = maxf(top, OBJECT_FLOOR_OFFSET + float(p.get("y", 0.0)) + size.y)
	if top <= 0.0:
		for obj in _rooms[id]["objects"]:
			var size: Vector2 = _object_size.get(obj["id"], Vector2.ZERO)
			top = maxf(top, OBJECT_FLOOR_OFFSET + _object_root_top_y(obj, size))
	return maxf(WALL_HEIGHT, top + HEAD_CLEARANCE)


func _object_root_top_y(obj: Dictionary, size: Vector2) -> float:
	return _object_root_bottom_y(obj, size) + size.y


func _object_root_bottom_y(obj: Dictionary, size: Vector2) -> float:
	if obj.get("function", null) != null and typeof(obj.get("function", null)) == TYPE_DICTIONARY:
		return 0.0
	if obj.get("type", "") == "media" and obj.get("content", {}).get("media_tag", "") == "video":
		var center_video := maxf(EYE_LEVEL, size.y * 0.5 + PANEL_FLOOR_GAP)
		return center_video - size.y * 0.5
	if obj.get("type", "") == "image" or obj.get("type", "") == "figure":
		var center_img := maxf(ImagePanel.EYE_LEVEL, size.y * 0.5 + ImagePanel.FLOOR_GAP)
		return center_img - size.y * 0.5
	var center_y := maxf(EYE_LEVEL, size.y * 0.5 + PANEL_FLOOR_GAP)
	return center_y - size.y * 0.5


## Строит "развёртку" виртуальных стен комнаты: смежные коллинеарные рёбра склеиваются в
## непрерывные wall-boxes, а углы и разрывы остаются разрезами. Затем реальные размеры объектов
## жадно пакуются в эти боксы. Если суммарной площади не хватает, боксы по очереди растут вверх
## на одну клетку, и layout полностью пересчитывается.
func _compute_object_layouts() -> void:
	_wall_boxes.clear()
	_object_placements.clear()
	for id in _rooms.keys():
		var boxes := _object_boxes(id)
		_wall_boxes[id] = boxes
		_object_placements[id] = _pack_room_objects(id, boxes)
	for id in _rooms.keys():
		_room_wall_h[id] = _wall_height(id)


func _object_boxes(id: int) -> Array:
	var rd: Dictionary = _layout.get("rooms", {}).get(id, {})
	var virtual_walls: Array = rd.get("virtual_walls", [])
	if virtual_walls.is_empty():
		return []

	var foot: Dictionary = _foot.get(id, {})
	var door_cells: Dictionary = _door_cells.get(id, {})
	var groups := {}
	for wall in virtual_walls:
		var c: Vector2i = wall.get("cell", Vector2i.ZERO)
		var pull: Vector2i = wall.get("dir", Vector2i.ZERO)
		if not foot.has(c) or door_cells.has(c) or not _wall_clear(id, c, pull):
			continue
		var fixed: int = c.x if pull.x != 0 else c.y
		var vary: int = c.y if pull.x != 0 else c.x
		var key := "%d,%d:%d" % [pull.x, pull.y, fixed]
		if not groups.has(key):
			groups[key] = {"pull": pull, "fixed": fixed, "values": {}}
		groups[key]["values"][vary] = c

	var boxes: Array = []
	for key in groups:
		var g: Dictionary = groups[key]
		var vals: Array = g["values"].keys()
		vals.sort()
		var i := 0
		while i < vals.size():
			var a: int = vals[i]
			var b: int = a
			var cells: Array = [g["values"][a]]
			while i + 1 < vals.size() and int(vals[i + 1]) == b + 1:
				i += 1
				b = int(vals[i])
				cells.append(g["values"][b])
			i += 1
			boxes.append({
				"pull": g["pull"],
				"fixed": int(g["fixed"]),
				"vary0": a,
				"vary1": b + 1,
				"cells": cells,
				"length": float(b - a + 1) * GRID,
				"height_cells": 1,
			})
	boxes.sort_custom(Callable(self, "_sort_object_boxes"))
	return boxes


func _sort_object_boxes(a: Dictionary, b: Dictionary) -> bool:
	var ac: Vector2i = a["cells"][0]
	var bc: Vector2i = b["cells"][0]
	if ac.y == bc.y:
		return ac.x < bc.x
	return ac.y < bc.y


func _pack_room_objects(id: int, boxes: Array) -> Dictionary:
	var objs: Array = _rooms[id].get("objects", [])
	if objs.is_empty():
		return {}
	if boxes.is_empty():
		return _fallback_object_placements(id, objs)

	var heights: Array = []
	for _i in boxes.size():
		heights.append(1)
	var grow_idx := 0
	var guard := 0
	while guard < boxes.size() * 64:
		guard += 1
		var packed := _try_pack_objects(objs, boxes, heights)
		if not packed.is_empty():
			for i in boxes.size():
				boxes[i]["height_cells"] = int(heights[i])
			return packed
		heights[grow_idx] = int(heights[grow_idx]) + 1
		grow_idx = (grow_idx + 1) % boxes.size()
	return _fallback_object_placements(id, objs)


func _try_pack_objects(objs: Array, boxes: Array, heights: Array) -> Dictionary:
	var state: Array = []
	for i in boxes.size():
		state.append({"x": 0.0, "y": 0.0, "row_h": 0.0})

	var placements := {}
	var box_i := 0
	for obj in objs:
		var obj_id: int = obj["id"]
		var size: Vector2 = _object_size.get(obj_id, Vector2(PANEL_WIDTH_M, 1.0))
		var placed := false
		while box_i < boxes.size():
			var box: Dictionary = boxes[box_i]
			var st: Dictionary = state[box_i]
			var inner_w := maxf(0.0, float(box.get("length", GRID)) - OBJECT_BOX_EDGE_PAD * 2.0)
			var inner_h := float(heights[box_i]) * GRID - OBJECT_BOX_EDGE_PAD * 2.0
			var need_w := size.x
			var need_h := size.y
			if inner_w <= 0.0 or inner_h <= 0.0:
				box_i += 1
				continue
			if float(st["x"]) > 0.0 and float(st["x"]) + need_w > inner_w:
				st["x"] = 0.0
				st["y"] = float(st["y"]) + float(st["row_h"]) + OBJECT_GAP
				st["row_h"] = 0.0
			if float(st["y"]) + need_h <= inner_h:
				var along_x := float(st["x"]) + need_w * 0.5
				if need_w > inner_w:
					along_x = inner_w * 0.5
				placements[obj_id] = {
					"box": box_i,
					"along": OBJECT_BOX_EDGE_PAD + along_x,
					"y": OBJECT_BOX_EDGE_PAD + float(st["y"]),
					"pull": box["pull"],
				}
				st["x"] = minf(inner_w + OBJECT_GAP, float(st["x"]) + need_w + OBJECT_GAP)
				st["row_h"] = maxf(float(st["row_h"]), need_h)
				placed = true
				break
			box_i += 1
		if not placed:
			return {}
	return placements


func _fallback_object_placements(id: int, objs: Array) -> Dictionary:
	var slots := _fallback_slots(id)
	var placements := {}
	if slots.is_empty():
		return placements
	var y_by_slot: Array = []
	var prev_half_by_slot: Array = []
	for _i in slots.size():
		y_by_slot.append(0.0)
		prev_half_by_slot.append(0.0)
	for i in objs.size():
		var slot_i := i % slots.size()
		var slot: Dictionary = slots[slot_i]
		var size: Vector2 = _object_size.get(objs[i]["id"], Vector2(PANEL_WIDTH_M, 1.0))
		var y := float(y_by_slot[slot_i])
		if i >= slots.size():
			y += float(prev_half_by_slot[slot_i]) + size.y * 0.5 + OBJECT_GAP
		placements[objs[i]["id"]] = {
			"slot": slot,
			"along": GRID * 0.5,
			"y": y,
			"pull": slot["pull"],
		}
		y_by_slot[slot_i] = y
		prev_half_by_slot[slot_i] = size.y * 0.5
	return placements


## Описывающий прямоугольник футпринта комнаты (в клетках).
func _foot_bbox(id: int) -> Rect2i:
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for c in _foot_cells.get(id, []):
		lo = lo.min(c)
		hi = hi.max(c)
	if lo.x > hi.x:
		return Rect2i(Vector2i.ZERO, Vector2i.ONE)
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## Центр футпринта комнаты в мире (середина клеток).
func _foot_centroid_world(id: int) -> Vector3:
	var sum := Vector2.ZERO
	var n := 0
	for c in _foot_cells.get(id, []):
		sum += Vector2(c) + Vector2(0.5, 0.5)
		n += 1
	if n == 0:
		return _shift
	sum /= float(n)
	return _cell_world(sum.x, sum.y)


func _cell_world(col: float, row: float) -> Vector3:
	return Vector3(col * GRID, 0.0, row * GRID) + _shift


func _is_unit(d: Vector2i) -> bool:
	return absi(d.x) + absi(d.y) == 1


func _edge_key(cell: Vector2i, d: Vector2i) -> String:
	return "%d,%d:%d,%d" % [cell.x, cell.y, d.x, d.y]


func _dir_key(d: Vector2i) -> String:
	if d == Vector2i(1, 0):
		return "px"
	if d == Vector2i(-1, 0):
		return "nx"
	if d == Vector2i(0, 1):
		return "pz"
	return "nz"


# --- Фаза 3: геометрия комнаты (полы по клеткам, стены по периметру, объекты) ---

func _build_room(id: int, parent: Node3D, on_transition: Callable) -> void:
	var room: Dictionary = _rooms[id]
	# Геометрия строится в МИРОВЫХ координатах (футпринт нерегулярный), поэтому holder в начале
	# координат: дочерние боксы кладутся по абсолютным клеткам.
	var holder := Node3D.new()
	holder.name = "Room_%d" % id
	parent.add_child(holder)
	if _debug:
		_attach_debug(holder, _room_debug_text(id))

	var is_connector: bool = room["kind"] == "connector"
	var floor_color := _room_color(room, is_connector)
	var wall_color := floor_color.lightened(0.1)

	# Полы: по GRID-квадрату на каждую клетку футпринта.
	for c in _foot_cells[id]:
		_add_box(holder, Vector3(GRID, 0.4, GRID), _cell_world(c.x + 0.5, c.y + 0.5) + Vector3(0, -0.2, 0), floor_color, true)

	# Стены — по периметру футпринта, с проёмами на местах дверей.
	var runs := _wall_runs(id)
	var h: float = _room_wall_h[id]
	for r in runs:
		_add_wall_run(holder, r, h, wall_color)

	# Заголовок секции (первый объект-heading комнаты) — вывеска над входным проёмом, читаемая
	# с обеих сторон. Удаётся только если у комнаты есть вход от родителя; иначе (корень)
	# заголовок остаётся настенной табличкой, как обычный объект.
	var title_obj = _room_title_object(id)
	var titled: bool = title_obj != null and _build_room_title(holder, id, title_obj)
	_place_objects(room, holder, on_transition, id, title_obj if titled else null)


## Стены комнаты как набор прямых ПРОБЕГОВ по периметру футпринта. Граничное ребро — это
## грань клетки футпринта, у которой снаружи нет клетки той же комнаты. Рёбра-двери (там, где
## связь пробивает стену) исключаются — на их месте проём. Смежные коллинеарные граничные
## рёбра склеиваются в один пробег (одна длинная стена). Возвращает список пробегов
## {kind, wall_fixed, along_lo, along_hi} (объекты теперь стоят вдоль дорожек, а не по стенам).
func _wall_runs(id: int) -> Array:
	var foot: Dictionary = _foot[id]
	var doors: Dictionary = _door_edges.get(id, {})
	# По каждой стороне (px/nx/pz/nz): fixed-координата стены -> список varying-координат клеток.
	var sides := {"px": {}, "nx": {}, "pz": {}, "nz": {}}
	for c in foot:
		for d in _dirs:
			if foot.has(c + d):
				continue   # внутреннее ребро — стены нет
			if doors.has(_edge_key(c, d)):
				continue   # дверь — проём
			var key := _dir_key(d)
			var fixed: int = c.x if d.x != 0 else c.y
			var vary: int = c.y if d.x != 0 else c.x
			var g: Dictionary = sides[key]
			if not g.has(fixed):
				g[fixed] = []
			g[fixed].append(vary)

	var runs: Array = []
	for key in sides:
		for fixed in sides[key]:
			var vals: Array = sides[key][fixed]
			vals.sort()
			var i := 0
			while i < vals.size():
				var a: int = vals[i]
				var b: int = a
				while i + 1 < vals.size() and vals[i + 1] == b + 1:
					i += 1
					b = vals[i]
				i += 1
				runs.append(_make_run(key, int(fixed), a, b))
	return runs


## Геометрия одного пробега стены. fixed — координата клетки вдоль нормали; [a..b] — диапазон
## клеток вдоль стены. Стена сдвинута внутрь комнаты на полтолщины (внешняя грань на границе
## клетки) — у вплотную стоящих комнат стены стыкуются грань-в-грань, без дырок и z-fight.
func _make_run(key: String, fixed: int, a: int, b: int) -> Dictionary:
	match key:
		"px":
			var outer_x := _cell_world(fixed + 1, 0).x
			return {"kind": "x", "wall_fixed": outer_x - WALL_THICK * 0.5,
				"along_lo": _cell_world(0, a).z, "along_hi": _cell_world(0, b + 1).z}
		"nx":
			var ox := _cell_world(fixed, 0).x
			return {"kind": "x", "wall_fixed": ox + WALL_THICK * 0.5,
				"along_lo": _cell_world(0, a).z, "along_hi": _cell_world(0, b + 1).z}
		"pz":
			var outer_z := _cell_world(0, fixed + 1).z
			return {"kind": "z", "wall_fixed": outer_z - WALL_THICK * 0.5,
				"along_lo": _cell_world(a, 0).x, "along_hi": _cell_world(b + 1, 0).x}
		_:  # nz
			var oz := _cell_world(0, fixed).z
			return {"kind": "z", "wall_fixed": oz + WALL_THICK * 0.5,
				"along_lo": _cell_world(a, 0).x, "along_hi": _cell_world(b + 1, 0).x}


func _add_wall_run(holder: Node3D, r: Dictionary, h: float, color: Color) -> void:
	var lo: float = r["along_lo"]
	var hi: float = r["along_hi"]
	var center := (lo + hi) * 0.5
	var length := hi - lo
	if length <= 0.05:
		return
	if r["kind"] == "x":
		_add_box(holder, Vector3(WALL_THICK, h, length), Vector3(r["wall_fixed"], h * 0.5, center), color, true)
	else:
		_add_box(holder, Vector3(length, h, WALL_THICK), Vector3(center, h * 0.5, r["wall_fixed"]), color, true)


## Расставляет объекты по заранее посчитанной развёртке виртуальных стен комнаты. Placement
## хранит box + координату вдоль стены + вертикальный offset; старый fallback по клеткам остаётся
## только для комнат без виртуальных стен.
func _place_objects(room: Dictionary, holder: Node3D, on_transition: Callable, id: int, skip_obj = null) -> void:
	var placements: Dictionary = _object_placements.get(id, {})
	for obj in room["objects"]:
		# Заголовок, ушедший вывеской над входом, среди объектов не дублируем.
		if skip_obj != null and obj["id"] == skip_obj["id"]:
			continue
		if not placements.has(obj["id"]):
			continue
		_place_object_at(obj, placements[obj["id"]], id, holder, on_transition)


func _place_object_at(obj: Dictionary, placement: Dictionary, id: int, holder: Node3D, on_transition: Callable) -> void:
	var pull: Vector2i = placement["pull"]
	var face := -pull
	var yaw := atan2(float(face.x), float(face.y))
	var size: Vector2 = _object_size.get(obj["id"], Vector2(PANEL_WIDTH_M, 1.0))
	var base_world := _placement_world(id, placement, obj, size)
	if obj["id"] == _first_obj_id:
		_record_spawn(Vector3(base_world.x, 0.0, base_world.z), face)
	_build_object(obj, holder, base_world, yaw, on_transition)


func _placement_world(id: int, placement: Dictionary, obj: Dictionary, size: Vector2) -> Vector3:
	var root_y := _placement_floor_y(placement) - _object_root_bottom_y(obj, size)
	if placement.has("slot"):
		var slot: Dictionary = placement["slot"]
		var cell: Vector2i = slot["cell"]
		var pull: Vector2i = slot["pull"]
		var pull_off := Vector3(pull.x, 0.0, pull.y) * (GRID * 0.5 - PULL_INSET)
		return _cell_world(cell.x + 0.5, cell.y + 0.5) + pull_off + Vector3(0, root_y, 0)

	var boxes: Array = _wall_boxes.get(id, [])
	var box_i: int = int(placement.get("box", -1))
	if box_i < 0 or box_i >= boxes.size():
		return _positions.get(id, Vector3.ZERO)
	var box: Dictionary = boxes[box_i]
	var pull: Vector2i = box["pull"]
	var along: float = float(placement.get("along", GRID * 0.5))
	if pull.x != 0:
		var x := _cell_world(float(box["fixed"]) + 0.5, 0).x + float(pull.x) * (GRID * 0.5 - PULL_INSET)
		var z := _cell_world(0, float(box["vary0"])).z + along
		return Vector3(x, root_y, z)
	var z2 := _cell_world(0, float(box["fixed"]) + 0.5).z + float(pull.y) * (GRID * 0.5 - PULL_INSET)
	var x2 := _cell_world(float(box["vary0"]), 0).x + along
	return Vector3(x2, root_y, z2)


func _placement_floor_y(placement: Dictionary) -> float:
	return OBJECT_FLOOR_OFFSET + float(placement.get("y", 0.0))


## Слоты под объекты из виртуальных стен комнаты. Каждая виртуальная стена — сторона клетки
## маршрута; объект ставится в эту клетку, притягивается к стороне `pull` и смотрит назад к центру
## клетки. Уникальность — по ребру клетки, а не по клетке: угловая клетка может дать несколько
## полезных стен. Рёбра рядом с дверями отбрасываются через _wall_clear.
func _object_slots(id: int) -> Array:
	var rd: Dictionary = _layout.get("rooms", {}).get(id, {})
	var virtual_walls: Array = rd.get("virtual_walls", [])
	if virtual_walls.is_empty():
		return []
	var foot: Dictionary = _foot[id]
	var door_cells: Dictionary = _door_cells.get(id, {})

	var used := {}
	var slots: Array = []
	for wall in virtual_walls:
		var c: Vector2i = wall.get("cell", Vector2i.ZERO)
		var pull: Vector2i = wall.get("dir", Vector2i.ZERO)
		if not foot.has(c) or door_cells.has(c) or not _wall_clear(id, c, pull):
			continue
		var key := _edge_key(c, pull)
		if used.has(key):
			continue
		used[key] = true
		slots.append({"cell": c, "pull": pull})
	return slots


## Свободна ли стена (сторона `pull` клетки `cell`) от дверей — у самой клетки и у соседних вдоль
## стены (±1): тогда даже широкая панель (до ~2 клеток в обе стороны) не нависнет над проёмом.
func _wall_clear(id: int, cell: Vector2i, pull: Vector2i) -> bool:
	var doors: Dictionary = _door_edges.get(id, {})
	var along := Vector2i(pull.y, -pull.x)   # вдоль стены (перпендикулярно притяжению)
	for k in [-1, 0, 1]:
		if doors.has(_edge_key(cell + along * k, pull)):
			return false
	return true


## Запасные слоты, если у комнаты нет маршрутов: по клеткам футпринта (кроме клеток-дверей),
## притянуты к внешнему краю (прочь от центра) и лицом к центру; притяжение к ребру-двери не
## допускается (объект не должен перекрывать проход).
func _fallback_slots(id: int) -> Array:
	var center := Vector2.ZERO
	var cells: Array = _foot_cells[id]
	for c in cells:
		center += Vector2(c)
	if cells.is_empty():
		return []
	center /= float(cells.size())
	var door_cells: Dictionary = _door_cells.get(id, {})
	var slots: Array = []
	for c in cells:
		if door_cells.has(c):
			continue
		slots.append({"cell": c, "pull": _pick_pull(id, c, _dominant_dir(Vector2(c) - center))})
	return slots


## Подбирает направление притяжения для клетки: предпочтительное `prefer`, иначе поворот, лишь бы
## стена со стороны притяжения была свободна от дверей (объект не перекрывает проход и не нависает
## над ним). Порядок: prefer, его лево, право, назад.
func _pick_pull(id: int, cell: Vector2i, prefer: Vector2i) -> Vector2i:
	for p in [prefer, Vector2i(prefer.y, -prefer.x), Vector2i(-prefer.y, prefer.x), -prefer]:
		if _wall_clear(id, cell, p):
			return p
	return prefer


## Доминантное единичное направление к delta (большая ось); по умолчанию +Z.
func _dominant_dir(delta: Vector2) -> Vector2i:
	if absf(delta.x) >= absf(delta.y):
		return Vector2i(signi(int(signf(delta.x))), 0) if delta.x != 0.0 else Vector2i(0, 1)
	return Vector2i(0, signi(int(signf(delta.y))))


## Запоминает первый объект для спавна: его мир-позицию и направление, в которое он смотрит
## (там встаёт игрок и смотрит на объект).
func _record_spawn(world_pos: Vector3, face: Vector2i) -> void:
	_spawn_obj_world = world_pos
	_spawn_inward = Vector3(face.x, 0.0, face.y)
	_spawn_max_d = 3.0
	_has_spawn_obj = true


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
	var ent = _room_entrance.get(id, null)
	if ent == null:
		return false
	var text := _truncate(_obj_text(title_obj).strip_edges(), 80)
	if text == "":
		return false

	var c: Vector2i = ent["cell"]
	var d: Vector2i = ent["dir"]
	var key := _dir_key(d)
	var wall_h: float = _room_wall_h[id]

	var level: int = int(title_obj.get("content", {}).get("level", 2))
	var font_px: float = _base_px * float(HEADING_EM.get(level, 1.0))
	var glyph_m := _px_to_m(font_px)
	var band_h := clampf(glyph_m * 1.5 + 0.2, TITLE_MIN_H, TITLE_MAX_H)
	var opening_w := GRID
	var band_w := opening_w + 2.0 * TITLE_OVERHANG
	var center_y := wall_h - band_h * 0.5   # лента-перемычка прижата к верху проёма

	var pos := Vector3.ZERO
	var out_n := Vector3.ZERO          # наружная нормаль стены
	var inward_yaw := 0.0              # ориентация Label3D лицом внутрь комнаты
	match key:
		"px":
			pos = Vector3(_cell_world(c.x + 1, 0).x, center_y, _cell_world(0, c.y + 0.5).z)
			out_n = Vector3(1, 0, 0); inward_yaw = -PI * 0.5
		"nx":
			pos = Vector3(_cell_world(c.x, 0).x, center_y, _cell_world(0, c.y + 0.5).z)
			out_n = Vector3(-1, 0, 0); inward_yaw = PI * 0.5
		"pz":
			pos = Vector3(_cell_world(c.x + 0.5, 0).x, center_y, _cell_world(0, c.y + 1).z)
			out_n = Vector3(0, 0, 1); inward_yaw = PI
		_:  # nz
			pos = Vector3(_cell_world(c.x + 0.5, 0).x, center_y, _cell_world(0, c.y).z)
			out_n = Vector3(0, 0, -1); inward_yaw = 0.0

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
		_record_title_spawn(pos, -out_n, GRID * 1.2)
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
func _record_title_spawn(door_world: Vector3, inward: Vector3, reach: float) -> void:
	var d: float = clampf(reach * 0.6, 1.2, 3.0)
	spawn_point = door_world + inward * d + Vector3(0, 1.0, 0)
	spawn_look_at = Vector3(door_world.x, 0.0, door_world.z) + inward * (reach + 1.0) + Vector3(0, 1.6, 0)
	has_spawn_look = true
	_spawn_done = true


## Полы и стены коридоров — по одному GRID-квадрату на коридорную клетку. Стена ставится на
## ту сторону клетки, где НЕТ ни другой коридорной клетки (улица продолжается), ни комнаты
## (там стена/дверь самой комнаты) — то есть на открытый край дорожки. Так дорожки больше не
## висят без стен, а проходы в комнаты (через дверь-клетку комнаты) остаются открытыми.
func _build_corridor_floors(parent: Node3D) -> void:
	var floor_color := Color(0.3, 0.3, 0.33)
	var wall_color := floor_color.lightened(0.1)
	for cell in _corr_cells.keys():
		var holder := Node3D.new()
		holder.position = _cell_world(cell.x + 0.5, cell.y + 0.5)
		parent.add_child(holder)
		_add_box(holder, Vector3(GRID, 0.4, GRID), Vector3(0, -0.2, 0), floor_color, true)
		for d in _dirs:
			var nb: Vector2i = cell + d
			if _corr_cells.has(nb) or _room_occ.has(nb):
				continue   # дорожка продолжается / у комнаты своя стена с дверью — стену не ставим
			_add_corr_wall(holder, d, wall_color)


## Стена коридора на стороне d клетки (holder в центре клетки). Сдвинута внутрь на полтолщины:
## внешняя грань ложится на границу клетки, как у стен комнат.
func _add_corr_wall(holder: Node3D, d: Vector2i, color: Color) -> void:
	var half := GRID * 0.5
	var off := half - WALL_THICK * 0.5
	if d.x != 0:
		_add_box(holder, Vector3(WALL_THICK, WALL_HEIGHT, GRID), Vector3(d.x * off, WALL_HEIGHT * 0.5, 0), color, true)
	else:
		_add_box(holder, Vector3(GRID, WALL_HEIGHT, WALL_THICK), Vector3(0, WALL_HEIGHT * 0.5, d.y * off), color, true)


# --- Объекты комнаты ---

func _build_object(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float, on_transition: Callable) -> void:
	var node := _spawn_object(obj, holder, local_pos, yaw, on_transition)
	if node != null:
		_object_nodes[obj["id"]] = node
	# Провенанс объекта вешаем на его корневой узел: отладочный пробник прицела поднимается
	# от коллайдера к ближайшему предку с метаданными (см. Player._find_debug_meta).
	if _debug and node != null:
		_attach_debug(node, _object_debug_text(obj))


func _on_object_size_changed(obj_id: int, size: Vector2) -> void:
	if not _object_room.has(obj_id):
		return
	var old: Vector2 = _object_size.get(obj_id, Vector2.ZERO)
	if old.distance_to(size) <= 0.01:
		return
	_object_size[obj_id] = size
	var room_id: int = _object_room[obj_id]
	var boxes := _object_boxes(room_id)
	_wall_boxes[room_id] = boxes
	_object_placements[room_id] = _pack_room_objects(room_id, boxes)
	_room_wall_h[room_id] = _wall_height(room_id)
	_reposition_room_objects(room_id)


func _reposition_room_objects(room_id: int) -> void:
	var placements: Dictionary = _object_placements.get(room_id, {})
	for obj in _rooms[room_id].get("objects", []):
		var obj_id: int = obj["id"]
		if not placements.has(obj_id) or not _object_nodes.has(obj_id):
			continue
		var node: Node3D = _object_nodes[obj_id]
		if not is_instance_valid(node):
			continue
		var placement: Dictionary = placements[obj_id]
		var size: Vector2 = _object_size.get(obj_id, Vector2(PANEL_WIDTH_M, 1.0))
		var pull: Vector2i = placement["pull"]
		var face := -pull
		node.position = _object_node_position(room_id, placement, obj, size)
		node.rotation.y = atan2(float(face.x), float(face.y))
		if obj_id == _first_obj_id:
			_record_spawn(Vector3(node.position.x, 0.0, node.position.z), face)


func _object_node_position(room_id: int, placement: Dictionary, obj: Dictionary, size: Vector2) -> Vector3:
	var base := _placement_world(room_id, placement, obj, size)
	if _object_node_is_centered(obj):
		return Vector3(base.x, _placement_floor_y(placement) + size.y * 0.5, base.z)
	return base


func _object_node_is_centered(obj: Dictionary) -> bool:
	var type: String = obj.get("type", "")
	if type == "media" and obj.get("content", {}).get("media_tag", "") == "video":
		return true
	if type == "text":
		var runs: Array = obj.get("content", {}).get("runs", [])
		return not runs.is_empty() and (_runs_have_links(runs) or _obj_text(obj).length() > 200)
	if type == "heading":
		return _runs_have_links(obj.get("content", {}).get("runs", []))
	if type == "list":
		return _list_has_links(obj) or _list_has_images(obj)
	if type == "table":
		return _table_has_links(obj) or _table_has_images(obj)
	return false


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
			var hruns: Array = obj.get("content", {}).get("runs", [])
			if _runs_have_links(hruns):
				# Кликабельный заголовок (<h2><a>…</a>, «ENTER →»): RichPanel в кегле заголовка.
				return _build_rich_panel(hruns, holder, local_pos, yaw, on_transition,
					_px_to_m(_heading_css_px(obj)))
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
	var size := _panel_size(clipped, glyph_m)
	var width := size.x
	var height := size.y
	# Центр панели — на уровне глаз (а не низом на полу): мелкие таблички висят перед
	# лицом, высокие приподняты так, чтобы низ не вжимался в пол (PANEL_FLOOR_GAP).
	var center_y := maxf(EYE_LEVEL, height * 0.5 + PANEL_FLOOR_GAP)
	_add_box(node, Vector3(width, height, 0.15), Vector3(0, center_y, 0), color, false)
	var label := Label3D.new()
	label.text = clipped
	label.font_size = font
	label.outline_size = max(8, int(font * 0.25))
	label.pixel_size = LABEL_PIXEL_SIZE
	label.width = int(width / LABEL_PIXEL_SIZE)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector3(0, center_y, 0.1)
	node.add_child(label)
	return node


func _panel_size(text: String, glyph_m: float) -> Vector2:
	var width := _panel_width(text, glyph_m)
	return Vector2(width, _panel_height(text, glyph_m, width))


func _panel_width(text: String, glyph_m: float) -> float:
	var char_w: float = max(0.001, glyph_m * 0.55)
	var max_line := 0
	for line in text.split("\n"):
		max_line = maxi(max_line, line.length())
	var by_longest := float(max_line) * char_w + 0.45
	if text.length() > 80:
		return PANEL_WIDTH_M
	return clampf(by_longest, PANEL_MIN_WIDTH_M, PANEL_WIDTH_M)


func _panel_height(text: String, glyph_m: float, width_m: float) -> float:
	var char_w: float = max(0.001, glyph_m * 0.5)
	var per_line: float = max(1.0, width_m / char_w)
	var explicit := 1 + text.count("\n")
	var wrapped := int(ceil(text.length() / per_line))
	var lines: int = max(explicit, wrapped)
	# Потолок 3.0 м: с центрированием на уровне глаз более высокая панель пробивала бы
	# потолок. Текст сюда и так приходит обрезанным (_truncate до 220 символов).
	return clampf(lines * glyph_m * 1.5 + 0.4, 1.0, 3.0)


## font_world_m < 0 -> кегль базового текста; иначе заданный (для кликабельных заголовков).
func _build_rich_panel(runs: Array, holder: Node3D, local_pos: Vector3, yaw: float,
		on_transition: Callable, font_world_m: float = -1.0) -> Node3D:
	var panel: RichPanel = RICH_PANEL_SCENE.instantiate()
	panel.setup(runs, font_world_m if font_world_m > 0.0 else _px_to_m(_base_px),
		_image_loader, _base_url)
	holder.add_child(panel)
	panel.rotation.y = yaw
	# Центр панели на уровне глаз; высота капнута в RichPanel, поэтому низ не уходит в пол.
	var half := panel.get_height_m() * 0.5
	panel.position = local_pos + Vector3(0, maxf(EYE_LEVEL, half + PANEL_FLOOR_GAP), 0)
	if on_transition.is_valid():
		panel.link_activated.connect(on_transition)
	return panel


## CSS-кегль заголовка (px) по его уровню — для рендера/замера кликабельного заголовка.
func _heading_css_px(obj: Dictionary) -> float:
	var level: int = int(obj.get("content", {}).get("level", 2))
	return _base_px * float(HEADING_EM.get(level, 1.0))


## Кегль заголовка в пикселях вьюпорта RichPanel (для estimate_height_m).
func _heading_rich_px(obj: Dictionary) -> int:
	return max(8, int(round(_px_to_m(_heading_css_px(obj)) * RichPanel.PIXEL_PER_METER)))


func _build_image_panel(obj: Dictionary, holder: Node3D, local_pos: Vector3, yaw: float,
		transition, on_transition: Callable) -> Node3D:
	var content: Dictionary = obj.get("content", {})
	var alt: String = str(content.get("alt", content.get("text", "")))
	var want_w := _img_px_to_m(float(content.get("width_px", 0.0)))
	var want_h := _img_px_to_m(float(content.get("height_px", 0.0)))
	var fallback_w := ImagePanel.BASE_WIDTH
	var panel := ImagePanel.new()
	panel.setup(alt, transition, want_w, want_h, fallback_w)
	holder.add_child(panel)
	panel.position = local_pos
	panel.rotation.y = yaw
	panel.size_changed.connect(func(size: Vector2): _on_object_size_changed(obj["id"], size))
	if transition != null and on_transition.is_valid():
		panel.link_activated.connect(on_transition)

	var src: String = str(content.get("src", ""))
	if src != "" and _image_loader != null:
		var url := PageFetcher.resolve_url(src, _base_url)
		panel.call_deferred("request_load", url, _image_loader)
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
	_resolve_document_palette()

	var base_hue: float
	var base_sat: float
	if _doc_has_base:
		base_hue = _doc_base_color.h
		base_sat = clampf(_doc_base_color.s + 0.1, 0.2, 0.7)
	else:
		_rng.seed = _seed
		base_hue = _rng.randf()
		base_sat = 0.35

	var weight := float(_rooms[root_id]["hints"].get("weight", 0))
	var richness := clampf(weight / 30.0, 0.0, 1.0)
	var elevation := deg_to_rad(lerpf(8.0, 65.0, richness))

	_rng.seed = _seed ^ 0x9E3779B9
	var azimuth := deg_to_rad(_rng.randf() * 360.0)

	var warmth := 1.0 - sin(elevation)
	var sun_color := Color.from_hsv(lerpf(base_hue, 0.07, warmth * 0.8), 0.35 + warmth * 0.3, 1.0)

	var sky := ProceduralSkyMaterial.new()
	# Небо берёт цвет фона документа как есть (тёмный фон -> тёмное небо), горизонт чуть
	# теплеет к закату. Без цвета — процедурная палитра от тона/сида (как раньше).
	if _doc_has_base:
		sky.sky_top_color = _doc_base_color
		var warm := Color.from_hsv(0.07, 0.3, lerpf(0.95, 0.7, warmth))
		sky.sky_horizon_color = _doc_base_color.lerp(warm, 0.15 + 0.35 * warmth)
	else:
		sky.sky_top_color = Color.from_hsv(base_hue, base_sat, 0.55)
		sky.sky_horizon_color = Color.from_hsv(lerpf(base_hue, 0.07, warmth), base_sat * 0.6, lerpf(0.95, 0.7, warmth))
	# Земля: цвет текста <body>, иначе очень тёмный фон документа (см. запрос на визуализацию).
	if _doc_fg != null:
		sky.ground_bottom_color = _doc_fg
	elif _doc_has_base:
		sky.ground_bottom_color = _doc_base_color.darkened(0.85)
	else:
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

	# Фон-картинка <body> -> небо-панорама (асинхронно: до прихода текстуры висит цветное небо).
	var bg_image := str((_space.get("document", {}) as Dictionary).get("bg_image", ""))
	if bg_image != "" and _image_loader != null:
		_apply_sky_image(env, bg_image)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(-elevation, azimuth, 0.0)
	sun.light_color = sun_color
	sun.light_energy = lerpf(0.7, 1.3, sin(elevation))
	sun.shadow_enabled = true
	parent.add_child(sun)


## Заполняет _doc_base_color/_doc_has_base/_doc_fg из паспорта документа: фон <body>
## (или, если его нет, средний CSS-фон комнат страницы) -> база неба/палитры; цвет текста
## <body> -> земля/акценты. Зовётся первой в фазе атмосферы — до раскраски комнат.
func _resolve_document_palette() -> void:
	var doc: Dictionary = _space.get("document", {})
	var bg = _parse_css_color(str(doc.get("bg", "")))
	if bg == null:
		var palette := _collect_bg_colors()
		if not palette.is_empty():
			var avg := Color(0, 0, 0)
			for c in palette:
				avg += c
			bg = avg / float(palette.size())
	if bg != null:
		_doc_base_color = bg
		_doc_has_base = true
	_doc_fg = _parse_css_color(str(doc.get("fg", "")))


## Подгружает фон-картинку документа и подменяет небо панорамой (равнопрямоугольной
## текстурой). Асинхронно через image_loader; если мир уже снесён навигацией — молча выходим.
func _apply_sky_image(env: Environment, src: String) -> void:
	var url := PageFetcher.resolve_url(src, _base_url)
	_image_loader.request_image(url, func(tex: Texture2D):
		if tex == null or not is_instance_valid(_container) or not is_instance_valid(env):
			return
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = tex
		var sky := Sky.new()
		sky.sky_material = pano
		# Небо завязано на ambient/отражения (env.ambient_light_source = SKY), поэтому смена
		# sky_material заставляет рендер пересобрать radiance-кубмапу. В gl_compatibility это
		# идёт синхронно на главном потоке; INCREMENTAL размазывает сборку по кадрам, меньший
		# radiance_size удешевляет её — чтобы подмена скайбокса не давала просадки кадра на
		# слабом GPU. Качество неба-фона не страдает (фильтрация нужна только ambient/отражениям).
		sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		env.sky = sky
	)


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


## Перевод пикселей картинки в метры — та же метрика, что у текста (1м = PX_PER_METER px).
## Сверяемся с ImagePanel.PX_PER_METER, чтобы footprint и реальный квад картинки не разошлись.
func _img_px_to_m(px: float) -> float:
	return px / ImagePanel.PX_PER_METER


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
	# Свой CSS-фон контейнера — высший приоритет (стена/карточка автора).
	var css: Dictionary = room["hints"].get("css", {})
	if css.has("bg"):
		var c = _parse_css_color(css["bg"])
		if c != null:
			return c
	# Иначе палитра комнат тянется от тона документа (фон <body>), а не от случайного цвета,
	# чтобы стены/полы перекликались с цветами страницы. Без цвета документа — старый рандом.
	if is_connector:
		if _doc_has_base:
			return _doc_base_color.darkened(0.4)
		return Color(0.32, 0.34, 0.4)
	_rng.seed = _seed + room["id"] * 2654435761
	if _doc_has_base:
		var h := fposmod(_doc_base_color.h + (_rng.randf() - 0.5) * 0.1, 1.0)
		var s := clampf(_doc_base_color.s * 0.7 + 0.05, 0.05, 0.6)
		var v := clampf(lerpf(0.55, 0.8, _rng.randf()), 0.2, 0.85)
		return Color.from_hsv(h, s, v)
	return Color.from_hsv(_rng.randf(), 0.28, 0.7)


## CSS-цвет -> Color, или null если не распознан. Поддержка: #hex, имена (Color.from_string),
## rgb()/rgba() (alpha игнорируем — миру нужен непрозрачный цвет).
func _parse_css_color(value: String):
	value = value.strip_edges().to_lower()
	if value == "" or value == "transparent":
		return null
	if value.begins_with("rgb"):
		return _parse_rgb(value)
	# from_string принимает и #hex, и именованные цвета; sentinel ловит непарсимое.
	var sentinel := Color(-1.0, -1.0, -1.0, -1.0)
	var c := Color.from_string(value, sentinel)
	if c == sentinel:
		return null
	return c


## rgb(r,g,b) / rgba(r,g,b,a): 0..255 или проценты. Возвращает Color или null.
func _parse_rgb(value: String):
	var open := value.find("(")
	var close := value.find(")", open)
	if open == -1 or close == -1:
		return null
	var parts := value.substr(open + 1, close - open - 1).split(",", false)
	if parts.size() < 3:
		return null
	var ch: Array[float] = []
	for k in 3:
		var t := parts[k].strip_edges()
		if t.ends_with("%"):
			ch.append(clampf(t.substr(0, t.length() - 1).to_float() / 100.0, 0.0, 1.0))
		else:
			ch.append(clampf(t.to_float() / 255.0, 0.0, 1.0))
	return Color(ch[0], ch[1], ch[2])


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
