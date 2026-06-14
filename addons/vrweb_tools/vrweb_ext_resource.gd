@tool
class_name VrwebExtResource
extends Resource

## Описание внешнего ресурса VRWeb (<ExtResource>) для авторинга сцены в редакторе.
## Хранит ссылку (url) и целевой тип Godot — то, что при экспорте превращается в
##   <ExtResource id="..." type="<type>" path="<url>"/>
## а ссылка на него в свойстве узла — в значение "ExtResource:::<id>".
##
## Кладётся не в само свойство узла (типы вроде Sprite3D.texture его бы не приняли),
## а в МЕТАДАТУ узла:
##   * meta "vrweb_ext"        -> { "<имя_свойства>": VrwebExtResource } — привязка к свойству;
##   * meta "vrweb_ext_scene"  -> VrwebExtResource(type="PackedScene") — точка <ExtScene>.
## Экспортёр (VrwebExporter) и дебаг-превью (VrwebExtPreview) читают эти меты.
##
## Набор type зеркалит поддерживаемые читателем типы (см. VrwebBuilder.*_TYPES + PackedScene
## для <ExtScene>).

## Ключи метадаты, под которыми ресурс кладётся на узел (общие для экспорта и превью).
const META_BINDINGS := "vrweb_ext"        # { prop: VrwebExtResource }
const META_SCENE := "vrweb_ext_scene"     # VrwebExtResource(PackedScene)

@export var url: String = ""

@export_enum(
	"Texture2D", "ImageTexture", "CompressedTexture2D",
	"AudioStreamMP3", "AudioStreamOggVorbis", "AudioStreamWAV",
	"Mesh", "ArrayMesh",
	"PackedScene"
) var type: String = "Texture2D"
