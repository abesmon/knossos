@tool
class_name VrwebExportRegistry
extends RefCounted

## Optional bridge from the portable exporter to project-specific public VRWeb classes.
## A clean authoring project needs no provider and exports ordinary ClassDB classes. Knossos
## configures its avatar registry through a project setting without becoming an addon import.

const PROVIDER_SETTING := "vrweb/tools/export_registry_script"
const META_PUBLIC_CLASS := "vrweb_public_class"


static func public_name(obj: Object) -> String:
	if obj == null:
		return ""
	if obj.has_meta(META_PUBLIC_CLASS):
		return str(obj.get_meta(META_PUBLIC_CLASS, ""))
	var provider := _provider()
	if provider != null and provider.has_method("public_name"):
		return str(provider.call("public_name", obj))
	return ""


static func instantiate(public_class: String) -> Object:
	var provider := _provider()
	if provider != null and provider.has_method("instantiate"):
		return provider.call("instantiate", public_class) as Object
	return null


static func _provider() -> Script:
	var path := str(ProjectSettings.get_setting(PROVIDER_SETTING, ""))
	if path.is_empty() or not ResourceLoader.exists(path, "Script"):
		return null
	return ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_REUSE) as Script
