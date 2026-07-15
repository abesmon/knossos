class_name AvatarAnimationTreeApplier
extends AvatarApplier

## Универсальный аппликатор: КОПИРУЕТ параметры аватара в AnimationTree по таблице привязок —
## ровно как в VRChat, где состояние просто уезжает в Animator, а вся анимация живёт в дереве
## блендов/переходов. Аватару не нужен код: модель + AnimationTree + этот узел с заполненными
## bindings в инспекторе. Добавить реакцию = добавить строку привязки + узел в дерево, а не
## править скрипт.

@export var animation_tree: AnimationTree
## Публичное VRWML-представление ссылки. Authoring `.tscn` может по-прежнему хранить прямую
## ссылку `animation_tree`; exporter преобразует её в относительный NodePath.
@export var animation_tree_path: NodePath
@export var bindings: Array[AvatarParamBinding] = []

var _map: Dictionary = {}   # StringName -> String (путь свойства в дереве)


func _ready() -> void:
	if animation_tree == null and not animation_tree_path.is_empty():
		animation_tree = get_node_or_null(animation_tree_path) as AnimationTree
	for b in bindings:
		if b != null and b.param != &"":
			_map[b.param] = b.tree_path
	if animation_tree != null:
		animation_tree.active = true


func _apply(pname: StringName, value: Variant) -> void:
	var path: String = _map.get(pname, "")
	if path != "" and animation_tree != null:
		animation_tree.set(path, value)
