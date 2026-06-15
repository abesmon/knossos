class_name AvatarParameters
extends RefCounted

## Шина параметров аватара — именованное хранилище сигналов (см. контракт в AvatarParams).
## Источник пишет значения через set_value/apply, аватар подписывается на changed и читает
## через get_value. Источник и аватар не знают друг о друге — общаются только через шину.

## Параметр изменился (эмитим только при реальной смене значения, чтобы аватар не
## дёргал риг каждый кадр на неизменных данных).
signal changed(pname: StringName, value: Variant)

var _values: Dictionary = AvatarParams.defaults()


## Записать значение. Эмитит changed только если значение действительно поменялось.
func set_value(pname: StringName, value: Variant) -> void:
	if _values.has(pname) and _values[pname] == value:
		return
	_values[pname] = value
	changed.emit(pname, value)


func get_value(pname: StringName, default: Variant = null) -> Variant:
	return _values.get(pname, default)


## Снимок всех параметров (для отправки по сети).
func snapshot() -> Dictionary:
	return _values.duplicate()


## Применить пачку параметров (например, пришедшую по сети). Каждый прогоняется через
## set_value, поэтому changed эмитится только для реально изменившихся.
func apply(values: Dictionary) -> void:
	for pname in values:
		set_value(pname, values[pname])
