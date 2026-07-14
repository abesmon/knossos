@tool
class_name VrwebFormat
extends RefCounted

## Stable vocabulary shared by the authoring exporter and the runtime builder. Keeping these
## names in the addon prevents the export path from depending on Knossos' VrwebBuilder class.

const TAG := "vrweb"
const RESOURCE_TAG := "Resource"
const EXT_RESOURCE_TAG := "ExtResource"
const EXT_SCENE_TAG := "ExtScene"
const SUBRESOURCE_PREFIX := "SubResource:::"
const EXTRESOURCE_PREFIX := "ExtResource:::"
const MODE_COMBINE := "combine"
const MODE_EXCLUSIVE := "exclusive"
const SPAWNER_TAG := "VRWebSpawner"
const SPAWN_POINT_TAG := "SpawnerPoint"


static func normalized_mode(value: String) -> String:
	return MODE_EXCLUSIVE if value == MODE_EXCLUSIVE else MODE_COMBINE
