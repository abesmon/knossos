class_name VrwebScriptError
extends RefCounted

## Единый контракт результата host-вызовов (docs/space/scripting-api.md): неуспех кодируется
## сентинел-словарём, который доверенный Luau-bootstrap превращает в пару `nil, code`.
## Успешные возвраты сентинела не содержат и проходят без изменений.

const SENTINEL := "__vrweb_error"

## Стандартные коды. Capability может уточнять причину доменным кодом в асинхронных событиях
## ({ok, error}), но синхронный отказ host-вызова использует только этот словарь.
const INVALID_ARGS := "invalid_args"   # аргументы не проходят структурную проверку
const NOT_FOUND := "not_found"         # адресат (объект/свойство/сигнал/запись) не существует
const DENIED := "denied"               # отклонено policy или правами
const UNSUPPORTED := "unsupported"     # операция/класс/формат не поддержаны этим клиентом
const LIMIT := "limit"                 # исчерпан бюджет или превышен размер
const LIFECYCLE := "lifecycle"         # вызов недоступен в текущей фазе realm
const BUSY := "busy"                   # занято другим незавершённым запросом
const INTERNAL := "internal"           # внутренняя ошибка host


static func err(code: String) -> Dictionary:
	return {SENTINEL: code}


static func is_err(value) -> bool:
	return value is Dictionary and (value as Dictionary).has(SENTINEL)
