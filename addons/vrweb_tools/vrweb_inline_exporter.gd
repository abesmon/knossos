@tool
class_name VrwebInlineExporter
extends RefCounted

## Portable validation/preparation for the trusted single-file HTML delivery form. Tree and
## property serialization remain VrwebExporter concerns; this class owns the code boundary.

const MIME := "application/vrweb+gdscript"
const RUNTIME := "trusted-gdscript"


static func prepare(script: Variant, module_id: String, base_class: String) -> Dictionary:
	if not (script is GDScript) or str(script.source_code).is_empty():
		return _error("inline Script не является source GDScript")
	var metadata := VrwebModuleMetadata.normalize({
		"id": module_id,
		"version": VrwebModuleMetadata.DEFAULT_VERSION,
		"permissions": [],
		"requires": VrwebModuleMetadata.DEFAULT_REQUIRES,
		"optional": VrwebModuleMetadata.DEFAULT_OPTIONAL,
	})
	if not bool(metadata.ok):
		return _error("; ".join(metadata.errors))
	var source := str(script.source_code)
	var lowered := source.to_lower()
	if lowered.contains("</script"):
		return _error("source содержит </script; используйте package")
	if _has_directive(source, "@tool"):
		return _error("@tool недопустим в inline module; используйте package")
	if _has_directive(source, "class_name"):
		return _error("class_name недопустим: публичное имя задаёт module id")
	if source.contains("res://") or source.contains("user://"):
		return _error("абсолютная resource-ссылка недопустима в inline module; используйте package")
	if _matches(source, "(?m)^\\s*extends\\s+['\"]"):
		return _error("extends внешнего script недопустим в inline module; используйте package")
	if _matches(source, "\\b(?:preload|load)\\s*\\("):
		return _error("inline module не поддерживает load/preload dependencies; используйте package")
	return {"ok": true, "error": "", "definition": {
		"id": module_id, "base": base_class, "source": source,
		"mime": MIME, "runtime": RUNTIME,
	}}


static func _has_directive(source: String, directive: String) -> bool:
	return _matches(source, "(?m)^\\s*%s(?:\\s|$)" % directive)


static func _matches(source: String, pattern: String) -> bool:
	var regex := RegEx.new()
	return regex.compile(pattern) == OK and regex.search(source) != null


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message, "definition": {}}
