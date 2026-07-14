@tool
class_name VrwebExtPreview
extends RefCounted

## Дебаг-превью внешних ресурсов прямо в редакторе: временно качает <ExtResource> по их
## URL и подставляет в открытую сцену — чтобы увидеть/услышать, как оно будет выглядеть,
## БЕЗ записи в файлы. Собирает заявки из меты узлов (см. VrwebExtResource) в ту же форму
## {defs, targets}, что и читатель, и зовёт общий VrwebExtInjector (один код с рантаймом).
##
## Не-сохранение в файлы:
##   * <ExtScene>-дети добавляются без owner -> Godot их не сериализует;
##   * превью свойств (texture/stream/mesh) ставится в реальное свойство, поэтому при
##     сохранении сцены оно бы запеклось — для этого есть clear_preview() (кнопка Clear).
##
## host — узел в дереве редактора (узел плагина), под которым живут лоадеры.

var _host: Node
var _image_loader: ImageLoader


func _init(host: Node) -> void:
	_host = host


## Качает все ext-ресурсы открытой сцены и вставляет превью.
func load_preview(root: Node) -> int:
	if root == null:
		return 0
	var ext := collect_ext(root)
	if ext["targets"].is_empty():
		return 0
	_reset_loaders()
	_image_loader = ImageLoader.new()
	_image_loader.name = "VrwebPreviewImageLoader"
	_host.add_child(_image_loader)
	VrwebExtInjector.inject(ext, _image_loader, _host)
	return ext["targets"].size()


## Снимает превью: обнуляет ext-привязанные свойства и удаляет вставленные <ExtScene>-сцены.
func clear_preview(root: Node) -> void:
	if root == null:
		return
	_clear_node(root)
	_reset_loaders()


## Собирает { defs: {id->{type,url}}, targets: [...] } из меты всего поддерева.
## target — {obj, prop, id} для привязки свойства или {obj, id, child:true} для <ExtScene>.
static func collect_ext(root: Node) -> Dictionary:
	var defs: Dictionary = {}
	var targets: Array = []
	var seq := [0]   # счётчик id в массиве — чтобы мутировать из рекурсии
	_collect_node(root, defs, targets, seq)
	return {"defs": defs, "targets": targets}


static func _collect_node(node: Node, defs: Dictionary, targets: Array, seq: Array) -> void:
	if node.has_meta(VrwebExtResource.META_BINDINGS):
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS)
		for prop in bindings:
			var ext = bindings[prop]
			if ext is VrwebExtResource and ext.url != "":
				var id := _new_id(seq)
				defs[id] = {"type": ext.type, "url": ext.url}
				targets.append({"obj": node, "prop": prop, "id": id})
	if node.has_meta(VrwebExtResource.META_SCENE):
		var ext_scene = node.get_meta(VrwebExtResource.META_SCENE)
		if ext_scene is VrwebExtResource and ext_scene.url != "":
			var id := _new_id(seq)
			defs[id] = {"type": ext_scene.type, "url": ext_scene.url}
			targets.append({"obj": node, "id": id, "child": true})
	for child in node.get_children():
		_collect_node(child, defs, targets, seq)


static func _new_id(seq: Array) -> String:
	var id := "p%d" % seq[0]
	seq[0] += 1
	return id


## Обнуляет ext-свойства узла и сносит детей-сцен у <ExtScene>-плейсхолдеров (owner == null).
func _clear_node(node: Node) -> void:
	if node.has_meta(VrwebExtResource.META_BINDINGS):
		var bindings: Dictionary = node.get_meta(VrwebExtResource.META_BINDINGS)
		for prop in bindings:
			node.set(prop, null)
	if node.has_meta(VrwebExtResource.META_SCENE):
		# Вставленные превью-сцены не имеют owner (не сохраняются) — их и сносим.
		for child in node.get_children():
			if child.owner == null:
				child.free()
	for child in node.get_children():
		if is_instance_valid(child):
			_clear_node(child)


func _reset_loaders() -> void:
	if is_instance_valid(_image_loader):
		_image_loader.queue_free()
	_image_loader = null
	# Лоадер сырых байтов VrwebExtInjector создаёт сам как ребёнка host — сносим прошлый.
	if _host != null:
		for child in _host.get_children():
			if child is VrwebResourceLoader:
				child.queue_free()
