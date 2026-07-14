class_name VrwebExtInjector
extends RefCounted

## Асинхронная подгрузка и вставка внешних ресурсов VRWeb (<ExtResource>) по списку заявок.
## Единая точка для рантайма (scenes/main.gd при навигации) и для дебаг-превью в редакторе
## (integrations/knossos/vrweb_tools/vrweb_ext_preview.gd) — оба передают одну структуру `ext`.
##
## `ext` = { defs: { id -> {type, url} }, targets: [ ... ] }, где target — либо свойство
## узла/ресурса ({obj, prop, id}), либо вставка GLTF-сцены ребёнком ({obj, id, child:true}).
## Текстуры качает image_loader (свой декод картинок), остальное — VrwebResourceLoader
## (сеть/файл ОС — сырые байты + декодеры; бандл-ресурс res:// — через ResourceLoader).
## res_loader создаётся лениво ребёнком `host`.

## Запускает докачку всех targets. host — узел в дереве, под которым живёт VrwebResourceLoader
## (нужно дерево, т.к. он гоняет HTTPRequest). image_loader должен быть уже в дереве.
## Необязательный on_complete вызывается, когда все заявки завершились (успехом или отказом):
## AvatarResolver использует это, чтобы упаковать уже заполненное дерево в PackedScene.
static func inject(ext: Dictionary, image_loader: ImageLoader, host: Node,
		on_complete: Callable = Callable()) -> void:
	var defs: Dictionary = ext.get("defs", {})
	var targets: Array = ext.get("targets", [])
	if defs.is_empty() or targets.is_empty():
		if on_complete.is_valid():
			on_complete.call()
		return

	var requests: Array = []
	for target in targets:
		if not defs.get(target.get("id", ""), {}).is_empty():
			requests.append(target)
	if requests.is_empty():
		if on_complete.is_valid():
			on_complete.call()
		return
	var completion := {"pending": requests.size(), "called": false}
	var done := func() -> void:
		completion.pending = int(completion.pending) - 1
		if int(completion.pending) == 0 and not bool(completion.called):
			completion.called = true
			if on_complete.is_valid():
				on_complete.call()

	# Лоадер сырых байтов нужен для всего, кроме текстур; создаём лениво.
	var res_loader: VrwebResourceLoader = null

	for target in requests:
		var def: Dictionary = defs.get(target["id"], {})
		var url: String = def["url"]
		var type: String = def["type"]
		var obj: Object = target["obj"]

		# <ExtScene>: вставляем скачанную GLTF/GLB-сцену ребёнком плейсхолдера.
		if target.get("child", false):
			res_loader = _ensure_res_loader(res_loader, host)
			res_loader.request_scene(url, func(scene):
				if scene != null and is_instance_valid(obj):
					obj.add_child(scene)
				elif scene != null:
					scene.free()
				done.call())
			continue

		var prop: String = target["prop"]
		if VrwebBuilder.TEXTURE_TYPES.has(type):
			image_loader.request_image(url, func(tex):
				if tex != null and is_instance_valid(obj):
					obj.set(prop, tex)
				done.call())
		elif VrwebBuilder.AUDIO_TYPES.has(type):
			res_loader = _ensure_res_loader(res_loader, host)
			res_loader.request_audio(url, type, func(stream):
				if stream != null and is_instance_valid(obj):
					obj.set(prop, stream)
					# autoplay декларативно: поток пришёл асинхронно после _ready, поэтому
					# проигрыватель не стартует сам — запускаем вручную, если просили autoplay.
					if _is_audio_player(obj) and obj.autoplay and not obj.playing:
						obj.play()
				done.call())
		elif VrwebBuilder.MESH_TYPES.has(type):
			res_loader = _ensure_res_loader(res_loader, host)
			res_loader.request_mesh(url, func(mesh):
				if mesh != null and is_instance_valid(obj):
					obj.set(prop, mesh)
				done.call())
		else:
			Log.warn("extres", "ExtResource type «%s» пока не поддержан" % type)
			done.call()


## Узел — один из аудиопроигрывателей (есть свойства autoplay/playing и метод play()).
static func _is_audio_player(obj: Object) -> bool:
	return obj is AudioStreamPlayer or obj is AudioStreamPlayer2D or obj is AudioStreamPlayer3D


## Создаёт VrwebResourceLoader под host при первой необходимости (один на сессию инжекта).
static func _ensure_res_loader(loader: VrwebResourceLoader, host: Node) -> VrwebResourceLoader:
	if loader != null:
		return loader
	loader = VrwebResourceLoader.new()
	loader.name = "VrwebResourceLoader"
	host.add_child(loader)
	return loader
