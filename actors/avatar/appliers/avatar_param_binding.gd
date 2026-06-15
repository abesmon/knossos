class_name AvatarParamBinding
extends Resource

## Одна строка таблицы для AvatarAnimationTreeApplier: имя параметра аватара → путь свойства
## в AnimationTree. Примеры tree_path:
##   - float-бленд:  "parameters/look/blend_position"  или  "parameters/run/blend_amount"
##   - условие перехода (bool):  "parameters/conditions/grounded"
## Редактируется в инспекторе — кода аватару не требуется.

@export var param: StringName
@export var tree_path: String
