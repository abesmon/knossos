class_name StatusIcons
extends RefCounted

## Общие иконки статуса (resources/status-icons/) — единый источник для 3D-неймплейта
## (view-bubble над головой) и 2D-UI (список «Пользователи»). Держим маппинг статус→текстура
## в одном месте, чтобы «галочка/предупреждение/ошибка» выглядели одинаково везде.
## См. docs/home-server.md, docs/avatars.md.

enum Status {
	NONE,      ## иконки нет
	VERIFIED,  ## checkmark — личность подтверждена домашним сервером (nick@domain)
	WARNING,   ## warning — что-то не подтверждено (напр. легитимность аватара)
	ERROR,     ## err — отказ/несоответствие (напр. аватар DENIED)
	OFFLINE,   ## no-connection — связь с пиром потеряна (обрыв p2p / grace-период призрака)
}

const CHECKMARK := preload("res://resources/status-icons/checkmark-icon.png")
const WARNING := preload("res://resources/status-icons/warning-icon.png")
const ERROR := preload("res://resources/status-icons/err-icon.png")
const NO_CONNECTION := preload("res://resources/icons/no-connection.png")

## Цвета семафора: галочка — зелёная, warning — жёлтый, err — красный, обрыв связи —
## оранжевый. Иконки монохромные, поэтому цвет накладывается через modulate/self_modulate.
const GREEN := Color(0.35, 0.85, 0.45)
const YELLOW := Color(1.0, 0.82, 0.2)
const RED := Color(0.95, 0.35, 0.35)
const ORANGE := Color(1.0, 0.55, 0.25)


## Текстура иконки для статуса; null для NONE (иконку прячем).
static func texture(status: Status) -> Texture2D:
	match status:
		Status.VERIFIED:
			return CHECKMARK
		Status.WARNING:
			return WARNING
		Status.ERROR:
			return ERROR
		Status.OFFLINE:
			return NO_CONNECTION
		_:
			return null


## Цвет иконки для статуса (накладывается modulate'ом); белый для NONE.
static func color(status: Status) -> Color:
	match status:
		Status.VERIFIED:
			return GREEN
		Status.WARNING:
			return YELLOW
		Status.ERROR:
			return RED
		Status.OFFLINE:
			return ORANGE
		_:
			return Color.WHITE
