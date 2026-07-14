@tool
class_name VrwebCompatibility
extends RefCounted

## Versioned Maker Kit vocabulary used by editor export and the headless CLI.
## `compatible` preserves the historical ClassDB-wide exporter behavior; `strict` only accepts
## this portable declarative subset plus classes explicitly exposed by the host registry.

const CATALOG_VERSION := "0.2-mvp1"
const PROFILE_STRICT := "strict"
const PROFILE_COMPATIBLE := "compatible"
const MAX_NODES := 2048
const MAX_RESOURCES := 1024
const MAX_EXTERNAL_RESOURCES := 256
const HEAVY_MESH_TRIANGLES := 100000

const NODE_CLASSES := {
	"Node": true,
	"Node3D": true,
	"MeshInstance3D": true,
	"StaticBody3D": true,
	"CollisionShape3D": true,
	"Area3D": true,
	"Marker3D": true,
	"DirectionalLight3D": true,
	"OmniLight3D": true,
	"SpotLight3D": true,
	"Sprite3D": true,
	"AudioStreamPlayer3D": true,
}

const RESOURCE_CLASSES := {
	"BoxMesh": true,
	"SphereMesh": true,
	"CapsuleMesh": true,
	"CylinderMesh": true,
	"PlaneMesh": true,
	"QuadMesh": true,
	"ArrayMesh": true,
	"StandardMaterial3D": true,
	"BoxShape3D": true,
	"SphereShape3D": true,
	"CapsuleShape3D": true,
	"CylinderShape3D": true,
	"ConvexPolygonShape3D": true,
	"ConcavePolygonShape3D": true,
}

const EXTERNAL_RESOURCE_TYPES := {
	"Texture2D": true,
	"ImageTexture": true,
	"CompressedTexture2D": true,
	"AudioStreamMP3": true,
	"AudioStreamOggVorbis": true,
	"AudioStreamWAV": true,
	"Mesh": true,
	"ArrayMesh": true,
	"PackedScene": true,
}


static func normalized_profile(profile: String) -> String:
	return PROFILE_STRICT if profile.to_lower() == PROFILE_STRICT else PROFILE_COMPATIBLE


static func supports_node(class_name_: String) -> bool:
	return NODE_CLASSES.has(class_name_)


static func supports_resource(class_name_: String) -> bool:
	return RESOURCE_CLASSES.has(class_name_)


static func supports_external_type(class_name_: String) -> bool:
	return EXTERNAL_RESOURCE_TYPES.has(class_name_)
