@tool
class_name VrwebLocalAsset
extends VrwebExtResource

## Project-local source declaration. Export turns it into an ordinary relative ExtResource URL;
## clients never need to know this authoring-only type.

@export_file("*.png", "*.jpg", "*.jpeg", "*.webp", "*.svg", "*.mp3", "*.ogg", "*.wav",
		"*.glb", "*.gltf") var source_path: String = ""

