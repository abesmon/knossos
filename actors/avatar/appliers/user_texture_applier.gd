extends Node

## Generic аппликатор идентичности: при получении текстуры игрока находит во всех мешах
## аватара текстурные слоты с маркером UserSettingsAvatarTexture и подменяет их на эту текстуру
## (уникальным материалом на экземпляр — общий из сцены править нельзя, у всех разное лицо).
## Маркер можно положить в любой материал любого меша — применится во всех местах сразу.
## Шину параметров не слушает: реагирует только на apply_identity (корень аватара раздаёт её
## всем узлам с этим методом), поэтому bind_params не реализует.
##
## Лицо может смениться в настройках уже после первой вставки, поэтому apply_identity обязан
## работать ПОВТОРНО. Наивный «найти маркер и заменить» этого не умеет: после первой вставки
## слот держит уже готовую текстуру (не маркер), и второй проход его не узнаёт. Поэтому места
## вставки (меш + поверхность + исходный материал-с-маркером + имена слотов) фиксируем ОДИН раз
## при первом применении, а дальше каждый раз пере-дублируем исходный материал с новым лицом.

# Записанные места вставки: [{mi, surface, source_mat, props}]. source_mat — исходный материал
# с маркером (никогда не мутируем, только дублируем), props — слоты в нём под подмену.
var _sites: Array = []
var _scanned := false


func apply_identity(_nick: String, face: Texture2D) -> void:
	if face == null:
		return
	if not _scanned:
		_scan()
	for site in _sites:
		var mi: MeshInstance3D = site["mi"]
		if not is_instance_valid(mi):
			continue
		var unique: Material = site["source_mat"].duplicate()
		for prop in site["props"]:
			unique.set(prop, face)
		mi.set_surface_override_material(site["surface"], unique)


## Один раз обходит меши и запоминает поверхности, чей активный материал несёт маркер.
## Ссылку на исходный материал держим как источник для будущих дублей (маркер в нём остаётся).
func _scan() -> void:
	_scanned = true
	var root: Node = owner if owner != null else get_parent()
	if root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if mat == null:
				continue
			var props := _marker_props(mat)
			if not props.is_empty():
				_sites.append({"mi": mi, "surface": i, "source_mat": mat, "props": props})


## Имена текстурных слотов материала, в которых лежит маркер UserSettingsAvatarTexture.
func _marker_props(mat: Material) -> PackedStringArray:
	var out := PackedStringArray()
	for prop in mat.get_property_list():
		if prop.type == TYPE_OBJECT and mat.get(prop.name) is UserSettingsAvatarTexture:
			out.append(prop.name)
	return out
