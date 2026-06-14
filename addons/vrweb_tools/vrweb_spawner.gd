@tool
class_name VrwebSpawner
extends Node3D

## Узел-маркер правил спавна для авторинга vrweb-сцены в редакторе.
## Экспортируется как мета-тег <VRWebSpawner mode="...">, а каждый дочерний Marker3D —
## как <SpawnerPoint transform="..."/> (origin → точка спавна, -Z базиса → куда смотреть).
## Сам узел в сцену клиента не инстанцируется (это правило, а не объект) —
## см. VrwebBuilder._build_spawn и docs/vrweb-tags.md.
##
## Поставьте этот узел в сцену, добавьте внутрь несколько Marker3D — это точки спавна.

## mode: "first" — всегда первая точка; "random" — случайная при каждой загрузке.
@export_enum("first", "random") var mode: String = "first"
