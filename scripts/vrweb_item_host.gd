class_name VrwebItemHost
extends Node3D

## Носитель ПЕРЕНОСИМОГО ПРЕДМЕТА (item) — ядро «модовой» модели инструментов
## (docs/space/portable-tools.md): эфемерный объект kind="vrweb-item" с props.src указывает
## на item-документ (VRWML-фрагмент + Luau + ассеты), и каждый клиент сам скачивает его,
## строит сцену и запускает скрипты в СОБСТВЕННОМ realm — тем же конвейером, что страницы
## (parser → политика → builder → VrwebLuauRuntime). Так поведение приезжает в мир без
## обновления клиента; песочница и лимиты — стандартные, отдельной permission-модели нет
## (модель браузера).
##
## Жизненный цикл: EphemeralView создаёт хост (_make_node) и удаляет его вместе с объектом
## слоя (remove/TTL/каскад) — realm закрывается сам при выходе из дерева, ownership
## replicated-объектов чистится мостами. src намеренно иммутабелен: смена предмета — это
## remove + add нового объекта, а не мутация существующего.

const MAX_DOC_BYTES := 512 * 1024

## Namespace скриптов предмета: id объекта эфемерного слоя. Два экземпляра одного item —
## два разных realm с разными wire-адресами document.state/remote (state у каждого свой;
## общее состояние автор строит через явные схемы, как обычно).
var _object_id := ""
var _context: Dictionary = {}
var _src := ""
var _fetcher: PageFetcher = null
var _script_fetcher: VrwebScriptFetcher = null
var _runtime: VrwebLuauRuntime = null
var _started := false


## context: { base_url, content_policy, player, file_picker } — из EphemeralView (тот
## передаёт привязку страницы, main дополняет player/file_picker).
func configure(object_id: String, context: Dictionary) -> void:
	_object_id = object_id
	_context = context.duplicate()


## Контракт EphemeralView._apply: данные объекта слоя. Первый вызов с валидным src запускает
## загрузку; последующие update игнорируются (src иммутабелен).
func setup_object(object: Dictionary) -> void:
	if _started:
		return
	var props: Dictionary = object.get("props", {})
	var raw := str(props.get("src", ""))
	if raw.is_empty():
		Log.warn("item", "vrweb-item «%s» без props.src — пропущен" % _object_id)
		return
	_started = true
	_src = PageFetcher.resolve_url(raw, str(_context.get("base_url", "")))
	_fetcher = PageFetcher.new()
	add_child(_fetcher)
	_fetcher.fetched.connect(_on_doc_fetched)
	_fetcher.failed.connect(func(message: String, url: String):
		Log.warn("item", "item «%s» не загрузился: %s (%s)" % [_object_id, message, url]))
	_fetcher.fetch(_src)


func _on_doc_fetched(html: String, final_url: String) -> void:
	if html.to_utf8_buffer().size() > MAX_DOC_BYTES:
		Log.warn("item", "item «%s» больше %d байт — отклонён" % [_object_id, MAX_DOC_BYTES])
		return
	var doc := HtmlParser.parse(html)
	var collection := VrwebScriptDeclaration.collect(doc, final_url)
	for script_error in collection.errors:
		Log.warn("item", "item «%s»: %s" % [_object_id, str(script_error)])
	_script_fetcher = VrwebScriptFetcher.new()
	add_child(_script_fetcher)
	_script_fetcher.fetch_all(collection.scripts, func(script_result: Dictionary):
		if is_inside_tree():
			_materialize(doc, final_url, script_result))


func _materialize(doc: HtmlNode, final_url: String, script_result: Dictionary) -> void:
	for script_error in script_result.errors:
		Log.warn("item", "item «%s» script: %s/%s" % [_object_id,
				str(script_error.get("script_id", "")), str(script_error.get("code", ""))])
	var policy: VrwebContentPolicy = _context.get("content_policy") as VrwebContentPolicy
	if policy == null:
		policy = VrwebContentPolicy.new()
	var built := VrwebBuilder.build(doc, final_url, policy)
	var root: Node = built.get("root")
	if root == null:
		Log.warn("item", "item «%s»: пустой <vrwml> — нечего монтировать" % _object_id)
		return
	# Namespace grabbable-адресов ДО монтажа (регистрация — в _ready): два экземпляра одного
	# item иначе объявили бы одинаковый grab_id и столкнулись бы в hold-состоянии.
	for node in root.find_children("*", "", true, false):
		if node is Grabbable and (node as Grabbable).grab_id != "":
			(node as Grabbable).grab_id = "item-%s.%s" % [_object_id, (node as Grabbable).grab_id]
	add_child(root)

	# Targets: id элементов item-документа -> построенные узлы + суб-ресурсы (как
	# main._build_script_targets, но в масштабе одного предмета).
	var index := SceneHtml.build_page_index(doc)
	var node_map: Dictionary = built.get("nodes", {})
	var targets := {}
	for nid in index.get("nodes", {}):
		var built_node = node_map.get(index["nodes"][nid]["elem"])
		if built_node != null:
			targets[nid] = built_node
	for rid in built.get("resources", {}):
		if not targets.has(rid):
			targets[rid] = built["resources"][rid]

	var scripts: Array = script_result.get("scripts", [])
	if scripts.is_empty():
		return   # предмет без поведения — легальный «просто объект»
	# Namespace realm: id скриптов (и явный realm, если задан) префиксуются id объекта слоя —
	# wire-адреса state/remote у каждого экземпляра предмета свои, даже при явном realm.
	var namespaced: Array = []
	var ns := "item-" + _object_id
	for value in scripts:
		var declaration: Dictionary = (value as Dictionary).duplicate(true)
		declaration["id"] = "%s.%s" % [ns, str(declaration.get("id", ""))]
		var declared_realm := str(declaration.get("realm", ""))
		if not declared_realm.is_empty():
			declaration["realm"] = "%s.%s" % [ns, declared_realm]
		namespaced.append(declaration)

	_runtime = VrwebLuauRuntime.new()
	_runtime.name = "ItemRuntime"
	_runtime.file_picker = _context.get("file_picker", Callable())
	# Ошибка в callback закрывает realm предмета: снаружи это выглядит как «инструмент
	# внезапно перестал реагировать». Без лога такое молча не диагностируется.
	_runtime.script_failed.connect(func(failed_id: String, phase: String, message: String):
		Log.warn("item", "item «%s» скрипт %s/%s: %s" % [_object_id, failed_id, phase, message]))
	add_child(_runtime)
	_runtime.setup(root, targets, final_url, _context.get("player") as Node, policy)
	var activation := _runtime.activate(namespaced)
	for script_error in activation.errors:
		Log.warn("item", "item «%s» activate: %s/%s: %s" % [_object_id,
				str(script_error.script_id), str(script_error.phase), str(script_error.message)])
