class_name VrwebExtInjector
extends RefCounted

## Асинхронная подгрузка и вставка внешних ресурсов VRWeb (<ExtResource>) по списку заявок.
## Единая точка для рантайма (scenes/main.gd при навигации) и для дебаг-превью в редакторе
## (addons/vrweb_tools/vrweb_ext_preview.gd) — оба передают одну и ту же структуру `ext`.
##
## `ext` = { defs: { id -> {type, url} }, targets: [ ... ] }, где target — либо свойство
## узла/ресурса ({obj, prop, id}), либо вставка GLTF-сцены ребёнком ({obj, id, child:true}).
## Текстуры качает image_loader (свой декод картинок), остальное — VrwebResourceLoader
## (сырые байты + статические декодеры). res_loader создаётся лениво ребёнком `host`.

## Запускает докачку всех targets. host — узел в дереве, под которым живёт VrwebResourceLoader
## (нужно дерево, т.к. он гоняет HTTPRequest). image_loader должен быть уже в дереве.
static func inject(ext: Dictionary, image_loader: ImageLoader, host: Node) -> void:
	var defs: Dictionary = ext.get("defs", {})
	var targets: Array = ext.get("targets", [])
	if defs.is_empty() or targets.is_empty():
		return

	# Лоадер сырых байтов нужен для всего, кроме текстур; создаём лениво.
	var res_loader: VrwebResourceLoader = null

	for target in targets:
		var def: Dictionary = defs.get(target["id"], {})
		if def.is_empty():
			continue
		var url: String = def["url"]
		var type: String = def["type"]
		var obj: Object = target["obj"]

		# <ExtScene>: вставляем скачанную GLTF/GLB-сцену ребёнком плейсхолдера.
		if target.get("child", false):
			res_loader = _ensure_res_loader(res_loader, host)
			res_loader.request_bytes(url, func(bytes):
				var scene := VrwebResourceLoader.build_gltf_scene(bytes)
				if scene == null:
					return
				if is_instance_valid(obj):
					obj.add_child(scene)
				else:
					scene.free())
			continue

		var prop: String = target["prop"]
		if VrwebBuilder.TEXTURE_TYPES.has(type):
			image_loader.request_image(url, func(tex):
				if tex != null and is_instance_valid(obj):
					obj.set(prop, tex))
		elif VrwebBuilder.AUDIO_TYPES.has(type):
			res_loader = _ensure_res_loader(res_loader, host)
			res_loader.request_bytes(url, func(bytes):
				var stream := VrwebResourceLoader.decode_audio(bytes, type)
				if stream != null and is_instance_valid(obj):
					obj.set(prop, stream)
					# autoplay декларативно: поток пришёл асинхронно после _ready, поэтому
					# проигрыватель не стартует сам — запускаем вручную, если просили autoplay.
					if _is_audio_player(obj) and obj.autoplay and not obj.playing:
						obj.play())
		elif VrwebBuilder.MESH_TYPES.has(type):
			res_loader = _ensure_res_loader(res_loader, host)
			res_loader.request_bytes(url, func(bytes):
				var mesh := VrwebResourceLoader.extract_first_mesh(bytes)
				if mesh != null and is_instance_valid(obj):
					obj.set(prop, mesh))
		else:
			push_warning("[VRWeb] ExtResource type «%s» пока не поддержан" % type)


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
