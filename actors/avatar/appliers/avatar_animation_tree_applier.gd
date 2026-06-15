class_name AvatarAnimationTreeApplier
extends AvatarApplier

## Универсальный аппликатор: КОПИРУЕТ параметры аватара в AnimationTree по таблице привязок —
## ровно как в VRChat, где состояние просто уезжает в Animator, а вся анимация живёт в дереве
## блендов/переходов. Аватару не нужен код: модель + AnimationTree + этот узел с заполненными
## bindings в инспекторе. Добавить реакцию = добавить строку привязки + узел в дерево, а не
## править скрипт.

@export var animation_tree: AnimationTree
@export var bindings: Array[AvatarParamBinding] = []

var _map: Dictionary = {}   # StringName -> String (путь свойства в дереве)


func _ready() -> void:
	for b in bindings:
		if b != null and b.param != &"":
			_map[b.param] = b.tree_path
	if animation_tree != null:
		animation_tree.active = true


func _apply(pname: StringName, value: Variant) -> void:
	var path: String = _map.get(pname, "")
	if path != "" and animation_tree != null:
		animation_tree.set(path, value)
