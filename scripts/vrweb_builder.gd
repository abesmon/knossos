class_name VrwebBuilder
extends RefCounted

const PLACED_IMAGE_SCENE := preload("res://actors/image_panel/placed_image.tscn")

## Парсер собственного синтаксиса VRWeb: блок <vrweb> внутри HTML-документа, который
## описывает 3D-сцену напрямую узлами Godot (Слой 1, расширение из docs/vrweb-overview.md).
##
## Синтаксис намеренно совместим с моделью узлов Godot, чтобы наш клиент мог строить сцену
## один-в-один, а другие реализации — маппить классы на свои аналоги. Пример:
##
##   <vrweb mode="combine|exclusive">
##     <MeshInstance3D mesh="SubResource:::BoxId123"
##                     transform="Transform3D(1.17,0,0, 0,1.16,-0.14, 0,0.14,1.16, 0.15,0.28,0.12)">
##       <StaticBody3D>
##         <CollisionShape3D shape="SubResource:::BoxShape3D_0wfyh"/>
##       </StaticBody3D>
##     </MeshInstance3D>
##
##     <Resource id="BoxId123" type="BoxMesh" size="Vector3(2,1,3)"/>
##     <Resource id="BoxShape3D_0wfyh" type="BoxShape3D" size="Vector3(2,1,3)"/>
##   </vrweb>
##
## Правила:
##   * Имя тега-узла = класс Godot (PascalCase, регистр сохраняет HtmlParser в raw_tag).
##   * Атрибуты узла = свойства узла (snake_case, как в Godot). Значения парсятся как
##     литералы Godot через str_to_var (Transform3D(...), Vector3(...), числа, строки в кавычках).
##   * <Resource id="..." type="ClassName" ...свойства.../> — встроенный суб-ресурс, ссылка
##     по значению "SubResource:::<id>". Строятся синхронно, допускают взаимные ссылки.
##   * <ExtResource id="..." type="ClassName" path="<url>"/> — ВНЕШНИЙ ресурс из интернета,
##     ссылка по значению "ExtResource:::<id>". Качается асинхронно «после» сборки и
##     инжектируется в целевые свойства, когда готов (см. VrwebBuilder.build -> "ext").
##   * mode="exclusive" — HTML игнорируется; "combine" (по умолчанию) — vrweb поверх HTML.
##   * <VRWebSpawner>/<SpawnerPoint> — кастомные мета-теги (правила спавна), не классы Godot.
##
## ⚠️ Безопасность: сейчас инстанцируется ЛЮБОЙ ClassDB-класс/свойство из недоверенной страницы.
## Это принятый риск прототипа — закрыть песочницей до выхода на реальные URL (см. docs/vrweb-tags.md).

const TAG := "vrweb"
const RESOURCE_TAG := "Resource"
const EXT_RESOURCE_TAG := "ExtResource"
const EXT_SCENE_TAG := "ExtScene"
const MIRROR_TAG := "VRWebMirror"
const VIDEO_PLAYER_TAG := "VRWebVideoPlayer"
const VIDEO_SCREEN_TAG := "VRWebVideoScreen"
const IMAGE_TAG := "VRWebImage"
const BLOB_TAG := "VRWebBlob"
const SUBRESOURCE_PREFIX := "SubResource:::"
const EXTRESOURCE_PREFIX := "ExtResource:::"
const MODE_COMBINE := "combine"
const MODE_EXCLUSIVE := "exclusive"

const MIRROR_SCENE := preload("res://scenes/vrweb_mirror.tscn")
const VIDEO_PLAYER_SCRIPT := preload("res://scripts/vrweb_video_player.gd")
const VIDEO_SCREEN_SCRIPT := preload("res://scripts/vrweb_video_screen.gd")

## Типы внешних ресурсов по способу загрузки (см. main._inject_ext_resources).
## TEXTURE — через ImageLoader; AUDIO/MESH — через VrwebResourceLoader (байты + декод).
const TEXTURE_TYPES := {"Texture2D": true, "ImageTexture": true, "CompressedTexture2D": true}
const AUDIO_TYPES := {"AudioStreamMP3": true, "AudioStreamOggVorbis": true, "AudioStreamWAV": true}
const MESH_TYPES := {"Mesh": true, "ArrayMesh": true}

## Кастомные мета-теги VRWeb (не классы Godot) — обрабатываются отдельно, в сцену не идут.
const SPAWNER_TAG := "VRWebSpawner"
const SPAWN_POINT_TAG := "SpawnerPoint"
const SPAWN_MODE_RANDOM := "random"
const SPAWN_MODE_FIRST := "first"

## Атрибуты <Resource>/<ExtResource>, которые задают сам ресурс, а не его свойства.
## src — атрибут-ссылка у <ExtScene>.
const RESOURCE_RESERVED := {"id": true, "type": true, "path": true, "src": true}

## Атрибуты <VRWebMirror>, которые задают сам объект, а не свойства узла Node3D.
const MIRROR_RESERVED := {"size": true, "resolution_scale": true, "srgb_decode": true}

## Атрибуты <VRWebVideoScreen>, которые задают привязку/плеер, а не свойства узла Node3D.
const VIDEO_SCREEN_RESERVED := {
	"player": true, "src": true, "size": true,
	"autoplay": true, "loop": true, "volume": true,
}

## Атрибуты <VRWebImage>, которые задают саму картинку, а не свойства узла Node3D.
## width/height — желаемый размер квада в МЕТРАХ (0/нет = натуральный размер текстуры).
const IMAGE_RESERVED := {"src": true, "alt": true, "width": true, "height": true}

var _base_url: String = ""
var _resources: Dictionary = {}     # id -> Resource (встроенные SubResource)
var _ext_defs: Dictionary = {}      # id -> { type: String, url: String } (внешние ресурсы)
var _ext_targets: Array = []        # [{ obj: Object, prop: String, id: String }] — куда вставить ext
var _node_map: Dictionary = {}      # HtmlNode (элемент) -> Node — провенанс для эфемерного оверлея


## Ищет блок <vrweb> в документе и строит из него сцену.
## base_url — адрес страницы, относительно которого резолвятся пути внешних ресурсов.
## Возвращает { found, mode, root, spawn, ext, nodes, resources }:
##   root — Node3D-холдер с построенными узлами (ещё не в дереве) или null, если узлов нет;
##   spawn — { point, look_at } из <VRWebSpawner> или {};
##   ext — { defs: {id->{type,url}}, targets: [{obj,prop,id}] } для асинхронной подгрузки;
##   nodes — { HtmlNode-элемент -> Node }: провенанс «элемент страницы -> построенный узел».
##     По нему эфемерный оверлей (vrweb-patch/vrweb-node, см. docs/space-console.md)
##     адресует РЕАЛЬНЫЕ узлы сцены;
##   resources — { id -> Resource }: суб-ресурсы страницы (для резолва ссылок из оверлея).
static func build(doc: HtmlNode, base_url: String = "") -> Dictionary:
	var b := VrwebBuilder.new()
	b._base_url = base_url
	return b._build(doc)


## Строит ОДИН узел сцены из плоских данных эфемерного объекта kind="vrweb-node":
## tag — класс Godot (или кастомный vrweb-тег), attrs — сырые строки-литералы (как в HTML),
## resources — суб-ресурсы страницы (ссылки "SubResource:::<id>" резолвятся против них).
## Дети не строятся — они приходят отдельными объектами и монтируются вьюхой.
static func build_element(tag: String, attrs: Dictionary, resources: Dictionary, base_url: String = "") -> Node:
	var b := VrwebBuilder.new()
	b._base_url = base_url
	b._resources = resources
	var elem := HtmlNode.new(tag.to_lower())
	elem.raw_tag = tag
	for k in attrs:
		elem.attributes[str(k)] = str(attrs[k])
	return b._build_node(elem)


## Резолв сырого строкового значения атрибута против суб-ресурсов страницы — для применения
## эфемерных патчей (vrweb-patch) к живым узлам. Семантика — как у _resolve_value.
static func resolve_attr_value(raw: String, resources: Dictionary) -> Variant:
	var b := VrwebBuilder.new()
	b._resources = resources
	return b._resolve_value(raw)


func _build(doc: HtmlNode) -> Dictionary:
	var block := doc.find_descendant(TAG)
	var empty_ext := {"defs": {}, "targets": []}
	if block == null:
		return {"found": false, "mode": MODE_COMBINE, "root": null, "spawn": {}, "ext": empty_ext,
			"nodes": {}, "resources": {}}

	var mode := block.get_attr("mode", MODE_COMBINE).to_lower()
	if mode != MODE_EXCLUSIVE:
		mode = MODE_COMBINE

	_collect_ext(block)
	_build_resources(block)
	var spawn := _build_spawn(block)

	var root := Node3D.new()
	root.name = "VRWeb"
	for child in block.children:
		if child.is_text() or _is_meta_tag(child):
			continue
		var node := _build_node(child)
		if node != null:
			root.add_child(node)

	var ext := {"defs": _ext_defs, "targets": _ext_targets}
	if root.get_child_count() == 0:
		root.free()
		return {"found": true, "mode": mode, "root": null, "spawn": spawn, "ext": ext,
			"nodes": {}, "resources": _resources}
	return {"found": true, "mode": mode, "root": root, "spawn": spawn, "ext": ext,
		"nodes": _node_map, "resources": _resources}


## Структурные/мета-теги, которые не инстанцируются как узлы сцены.
func _is_meta_tag(elem: HtmlNode) -> bool:
	return elem.raw_tag == RESOURCE_TAG or elem.raw_tag == EXT_RESOURCE_TAG or elem.raw_tag == SPAWNER_TAG


# --- Внешние ресурсы (<ExtResource>) ---

## Собирает определения внешних ресурсов { id: {type, url} } из всего поддерева <vrweb>.
## Сами байты не качаются — это делает потребитель результата асинхронно (см. main._inject_ext_resources).
func _collect_ext(block: HtmlNode) -> void:
	var defs: Array[HtmlNode] = []
	_collect_by_tag(block, EXT_RESOURCE_TAG, defs)
	for def in defs:
		var id := def.get_attr("id")
		var type := def.get_attr("type")
		var path := def.get_attr("path")
		if id == "" or path == "":
			Log.warn("builder", "<ExtResource> без id/path — пропущен")
			continue
		_ext_defs[id] = {"type": type, "url": PageFetcher.resolve_url(path, _base_url)}


# --- Встроенные ресурсы (<Resource>) ---

## Строит таблицу суб-ресурсов { id: Resource } из всех <Resource> внутри блока.
## Две фазы: сначала инстанцируем пустые ресурсы (чтобы id были известны для ссылок),
## затем проставляем свойства — так работают и взаимные/прямые ссылки между ресурсами.
func _build_resources(block: HtmlNode) -> void:
	var defs: Array[HtmlNode] = []
	_collect_by_tag(block, RESOURCE_TAG, defs)

	for def in defs:
		var id := def.get_attr("id")
		var type := def.get_attr("type")
		if id == "":
			Log.warn("builder", "<Resource> без id — пропущен")
			continue
		if not _can_instantiate(type):
			Log.warn("builder", "неизвестный тип ресурса «%s» (id=%s)" % [type, id])
			continue
		_resources[id] = ClassDB.instantiate(type)

	for def in defs:
		var id := def.get_attr("id")
		if _resources.has(id):
			_apply_attributes(_resources[id], def)


## Собирает в out все элементы поддерева с заданным raw_tag.
func _collect_by_tag(node: HtmlNode, raw_tag: String, out: Array[HtmlNode]) -> void:
	for child in node.children:
		if child.is_text():
			continue
		if child.raw_tag == raw_tag:
			out.append(child)
		_collect_by_tag(child, raw_tag, out)


# --- Узлы сцены ---

## Рекурсивно строит узел Godot из vrweb-элемента и его детей, записывая провенанс
## элемент -> узел (для адресации из эфемерного оверлея).
func _build_node(elem: HtmlNode) -> Node:
	var node := _instantiate_node(elem)
	if node != null:
		_node_map[elem] = node
	return node


func _instantiate_node(elem: HtmlNode) -> Node:
	if elem.raw_tag == EXT_SCENE_TAG:
		return _build_ext_scene(elem)
	if elem.raw_tag == MIRROR_TAG:
		return _build_mirror(elem)
	if elem.raw_tag == VIDEO_PLAYER_TAG:
		return _build_video_player(elem)
	if elem.raw_tag == VIDEO_SCREEN_TAG:
		return _build_video_screen(elem)
	if elem.raw_tag == IMAGE_TAG:
		return _build_image(elem)
	if elem.raw_tag == BLOB_TAG:
		# Документная форма realtime-ресурса — не узел: байты уходят в BlobStore.
		_ingest_blob(elem)
		return null
	var cls := elem.raw_tag
	if not _can_instantiate(cls):
		Log.warn("builder", "неизвестный класс узла «%s» — пропущен" % cls)
		return null
	var obj: Object = ClassDB.instantiate(cls)
	if not (obj is Node):
		Log.warn("builder", "«%s» — не Node, пропущен" % cls)
		if obj is Object and not (obj is RefCounted):
			(obj as Object).free()
		return null

	var node := obj as Node
	_apply_attributes(node, elem)
	_route_audio_to_world(node)
	for child in elem.children:
		if child.is_text() or _is_meta_tag(child):
			continue
		var sub := _build_node(child)
		if sub != null:
			node.add_child(sub)
	return node


## Аудио-узлы страницы по умолчанию направляем на шину «World» (звуки мира) — чтобы их
## громкость регулировал общий ползунок «Мир» в настройках. Если страница явно задала bus
## своим атрибутом (значение уже не «Master»), уважаем её выбор.
func _route_audio_to_world(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		if String(node.bus) == "Master":
			node.bus = &"World"


## Проставляет свойства объекта из атрибутов элемента.
## "ExtResource:::<id>" не ставится сразу (ресурс ещё не скачан) — регистрируется в _ext_targets
## и будет вставлен асинхронно. Остальное резолвится и ставится немедленно.
func _apply_attributes(obj: Object, elem: HtmlNode) -> void:
	for key in elem.attributes:
		if RESOURCE_RESERVED.has(key):
			continue
		var raw: String = elem.attributes[key]
		if raw.begins_with(EXTRESOURCE_PREFIX):
			var id := raw.substr(EXTRESOURCE_PREFIX.length())
			if _ext_defs.has(id):
				_ext_targets.append({"obj": obj, "prop": key, "id": id})
			else:
				Log.warn("builder", "ссылка на неизвестный ExtResource «%s»" % id)
			continue
		obj.set(key, _resolve_value(raw))


## <ExtScene src="ExtResource:::<id>" transform="..."/> — точка вставки внешней GLTF/GLB-сцены.
## Строит Node3D-плейсхолдер (с его трансформом/свойствами), а скачанная сцена добавляется ему
## ребёнком асинхронно (child-target). Атрибут src указывает на <ExtResource> с путём к .glb.
func _build_ext_scene(elem: HtmlNode) -> Node:
	var node := Node3D.new()
	for key in elem.attributes:
		if key == "src":
			continue
		node.set(key, _resolve_value(elem.attributes[key]))
	var src := elem.get_attr("src")
	if not src.begins_with(EXTRESOURCE_PREFIX):
		Log.warn("builder", "<ExtScene> без src=\"ExtResource:::<id>\"")
		return node
	var id := src.substr(EXTRESOURCE_PREFIX.length())
	if _ext_defs.has(id):
		_ext_targets.append({"obj": node, "id": id, "child": true})
	else:
		Log.warn("builder", "<ExtScene> ссылается на неизвестный ExtResource «%s»" % id)
	return node


## <VRWebMirror size="ширина:высота" transform="..."/> — зеркало в духе VRChat (планарное
## отражение, см. scripts/vrweb_mirror.gd). Это кастомный VRWeb-тег, а не класс Godot, поэтому
## строится особо (как <ExtScene>). size — размеры плоскости в метрах ("1:2" → 1×2 м, одиночное
## "1.5" → квадрат). resolution_scale (0.1..1) — качество текстуры отражения. Прочие атрибуты
## (transform и т.п.) применяются как обычные свойства Node3D.
func _build_mirror(elem: HtmlNode) -> Node:
	var mirror := MIRROR_SCENE.instantiate() as VrwebMirror
	var size := _parse_size(elem.get_attr("size", "1:2"))
	var res_scale := _attr_float(elem, "resolution_scale", 1.0)
	var srgb_decode := _attr_float(elem, "srgb_decode", 0.5)
	mirror.setup(size.x, size.y, res_scale, srgb_decode)
	for key in elem.attributes:
		if MIRROR_RESERVED.has(key):
			continue
		mirror.set(key, _resolve_value(elem.attributes[key]))
	return mirror


## <VRWebVideoPlayer id="..." src="<url>" autoplay loop volume="0.5"/> — логический видео-плеер
## (декод в текстуру, см. scripts/vrweb_video_player.gd). Кастомный тег, не класс Godot —
## headless-узел без геометрии. src резолвится относительно адреса страницы, как ext-ресурсы.
func _build_video_player(elem: HtmlNode) -> Node:
	var node: Node = VIDEO_PLAYER_SCRIPT.new()
	var src := ""
	if elem.has_attr("src"):
		src = PageFetcher.resolve_url(elem.get_attr("src"), _base_url)
	node.setup(elem.get_attr("id"), src, _attr_bool(elem, "autoplay", false),
			_attr_bool(elem, "loop", false), _attr_float(elem, "volume", 1.0))
	return node


## <VRWebVideoScreen player="<id>" size="ш:в" transform="..."/> — поверхность, показывающая
## текстуру плеера (см. scripts/vrweb_video_screen.gd). Привязка: player="<id>" (общий плеер)
## ИЛИ src="<url>" (свой неявный плеер). size — метры (как у зеркала); прочие атрибуты
## (transform и т.п.) — обычные свойства Node3D.
func _build_video_screen(elem: HtmlNode) -> Node:
	var node = VIDEO_SCREEN_SCRIPT.new()
	var src := ""
	if elem.has_attr("src"):
		src = PageFetcher.resolve_url(elem.get_attr("src"), _base_url)
	var size := Vector2.ZERO
	if elem.has_attr("size"):
		size = _parse_size(elem.get_attr("size"))
	node.setup(elem.get_attr("player"), src, size)
	node.autoplay = _attr_bool(elem, "autoplay", false)
	node.loop = _attr_bool(elem, "loop", false)
	node.volume = _attr_float(elem, "volume", 1.0)
	for key in elem.attributes:
		if VIDEO_SCREEN_RESERVED.has(key):
			continue
		node.set(key, _resolve_value(elem.attributes[key]))
	return node


## <VRWebImage src="<url>" alt="..." width="2" height="1.5" position="Vector3(...)"/> —
## картинка, размещённая в мире (кастомный тег, см. docs/network/realtime-resources.md).
## Строит PlacedImage (квад с текстурой, якорь центром); src — realtime-ресурс
## (vrwebblob://) или обычный URL; width/height — метры (0/нет = натуральный размер).
## Прочие атрибуты (position, rotation…) — обычные свойства Node3D. Именно этот тег
## создаёт инструмент размещения (клавиша 3) через эфемерный kind="vrweb-node".
func _build_image(elem: HtmlNode) -> Node:
	var node := PLACED_IMAGE_SCENE.instantiate() as PlacedImage
	var src := elem.get_attr("src")
	# Блоб-ссылки абсолютны и не принадлежат origin'у страницы — общий резолв их исковеркал бы.
	if src != "" and not BlobProtocol.is_blob_url(src):
		src = PageFetcher.resolve_url(src, _base_url)
	node.setup(elem.get_attr("alt"), null,
			_attr_float(elem, "width", 0.0), _attr_float(elem, "height", 0.0))
	node.src = src
	for key in elem.attributes:
		if IMAGE_RESERVED.has(key):
			continue
		node.set(key, _resolve_value(elem.attributes[key]))
	return node


## <VRWebBlob hash="<64 hex sha256>" data="<base64>"/> — вшитые в документ байты
## realtime-ресурса: страница (или запечённый флаш) несёт блоб инлайн, и ссылки
## vrwebblob:// резолвятся без p2p. Хэш сверяет BlobStore.ingest — байты, не совпадающие
## с адресом, молча отбрасываются (подсунуть подмену через документ нельзя).
func _ingest_blob(elem: HtmlNode) -> void:
	var hex := elem.get_attr("hash").to_lower()
	if not BlobProtocol.valid_hex(hex):
		Log.warn("builder", "<VRWebBlob> с кривым hash — пропущен")
		return
	if BlobStore.has_hex(hex):
		return
	BlobStore.ingest(hex, Marshalls.base64_to_raw(elem.get_attr("data")))


## Булев атрибут элемента или fallback (атрибута нет / значение не bool-литерал).
func _attr_bool(elem: HtmlNode, key: String, fallback: bool) -> bool:
	if not elem.has_attr(key):
		return fallback
	var v: Variant = _resolve_value(elem.get_attr(key))
	return v if v is bool else fallback


## Числовой атрибут элемента (float) или fallback, если атрибута нет/значение не число.
func _attr_float(elem: HtmlNode, key: String, fallback: float) -> float:
	if not elem.has_attr(key):
		return fallback
	var v: Variant = _resolve_value(elem.get_attr(key))
	return float(v) if (v is float or v is int) else fallback


## Разбирает size="ширина:высота" (метры) в Vector2. "1.5" без двоеточия — квадрат.
## Нечисловые/пустые части → 1.0.
func _parse_size(raw: String) -> Vector2:
	var parts := raw.split(":")
	var w := _to_float_or(parts[0] if parts.size() > 0 else "", 1.0)
	var h := _to_float_or(parts[1] if parts.size() > 1 else parts[0], 1.0)
	return Vector2(w, h)


func _to_float_or(s: String, fallback: float) -> float:
	s = s.strip_edges()
	return s.to_float() if s.is_valid_float() else fallback


## Превращает строковое значение атрибута в Variant Godot.
## "SubResource:::<id>" -> ранее построенный ресурс; иначе str_to_var (литералы Godot:
## Transform3D(...), Vector3(...), числа, true/false, "строки"); при неудаче — сырая строка.
func _resolve_value(raw: String) -> Variant:
	if raw.begins_with(SUBRESOURCE_PREFIX):
		var id := raw.substr(SUBRESOURCE_PREFIX.length())
		if not _resources.has(id):
			Log.warn("builder", "ссылка на неизвестный SubResource «%s»" % id)
			return null
		return _resources[id]
	var parsed: Variant = str_to_var(raw)
	if parsed == null:
		return raw   # не литерал Godot (обычная строка без кавычек)
	return parsed


# --- Правила спавна (<VRWebSpawner>) ---

## Разбирает <VRWebSpawner> и выбирает точку спавна.
## <VRWebSpawner mode="random|first">
##   <SpawnerPoint transform="Transform3D(...)"/>
##   ...
## </VRWebSpawner>
## point = origin трансформа точки; look_at = origin + forward (-Z, как «вперёд» в Godot).
## mode="random" — случайная точка (свежий RNG, разные игроки спавнятся в разных местах);
## иначе — первая точка. {} если спавнера/валидных точек нет.
func _build_spawn(block: HtmlNode) -> Dictionary:
	var spawner: HtmlNode = null
	for child in block.children:
		if child.raw_tag == SPAWNER_TAG:
			spawner = child
			break
	if spawner == null:
		return {}

	var points: Array[Transform3D] = []
	for child in spawner.children:
		if child.raw_tag != SPAWN_POINT_TAG:
			continue
		if not child.has_attr("transform"):
			Log.warn("builder", "<SpawnerPoint> без transform — пропущен")
			continue
		var value: Variant = _resolve_value(child.get_attr("transform"))
		if value is Transform3D:
			points.append(value)
		else:
			Log.warn("builder", "<SpawnerPoint> transform не Transform3D — пропущен")
	if points.is_empty():
		return {}

	var mode := spawner.get_attr("mode", SPAWN_MODE_FIRST).to_lower()
	var idx := 0
	if mode == SPAWN_MODE_RANDOM:
		idx = randi() % points.size()
	var xform: Transform3D = points[idx]
	var forward: Vector3 = -xform.basis.z
	if forward.length() < 0.0001:
		forward = Vector3(0, 0, -1)
	return {"point": xform.origin, "look_at": xform.origin + forward.normalized()}


# --- Утилиты ---

## class_exists + can_instantiate: класс известен движку и его можно создать.
func _can_instantiate(cls: String) -> bool:
	return cls != "" and ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls)
