extends Node

## Generic аппликатор идентичности: при получении текстуры игрока находит во всех мешах
## аватара текстурные слоты с маркером UserSettingsAvatarTexture и подменяет их на эту текстуру
## (уникальным материалом на экземпляр — общий из сцены править нельзя, у всех разное лицо).
## Маркер можно положить в любой материал любого меша — применится во всех местах сразу.
## Шину параметров не слушает: реагирует только на apply_identity (корень аватара раздаёт её
## всем узлам с этим методом), поэтому bind_params не реализует.

func apply_identity(_nick: String, face: Texture2D) -> void:
	if face == null:
		return
	var root: Node = owner if owner != null else get_parent()
	if root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		_inject(node, face)


func _inject(mi: MeshInstance3D, face: Texture2D) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		var mat := mi.get_active_material(i)
		if mat == null or not _has_marker(mat):
			continue
		var unique := mat.duplicate()
		_replace_markers(unique, face)
		mi.set_surface_override_material(i, unique)


## Есть ли в материале хоть один текстурный слот с маркером.
func _has_marker(mat: Material) -> bool:
	for prop in mat.get_property_list():
		if prop.type == TYPE_OBJECT and mat.get(prop.name) is UserSettingsAvatarTexture:
			return true
	return false


## Подменить во всех слотах материала маркеры на текстуру игрока.
func _replace_markers(mat: Material, face: Texture2D) -> void:
	for prop in mat.get_property_list():
		if prop.type == TYPE_OBJECT and mat.get(prop.name) is UserSettingsAvatarTexture:
			mat.set(prop.name, face)
