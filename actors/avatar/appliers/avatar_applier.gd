class_name AvatarApplier
extends Node

## База «аппликатора» — узла, который читает состояние аватара (AvatarParameters) и применяет
## его к чему-то. Корень аватара раздаёт шину через bind_params. Реагируем точечно на сигнал
## changed, а при привязке прогоняем текущий снимок (чтобы не «проспать» уже выставленные
## значения). Для сглаживания наследник добавляет свой _process. См. docs/avatars.md.

var params: AvatarParameters


## Вызывается корнем аватара. Можно переопределить, но обычно достаточно _apply.
func bind_params(p: AvatarParameters) -> void:
	params = p
	p.changed.connect(_on_changed)
	var snap := p.snapshot()
	for pname in snap:
		_apply(pname, snap[pname])


func _on_changed(pname: StringName, value: Variant) -> void:
	_apply(pname, value)


## Реакция на один параметр. Переопределяется наследником (см. AvatarParams).
func _apply(_pname: StringName, _value: Variant) -> void:
	pass
