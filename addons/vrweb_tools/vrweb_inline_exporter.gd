@tool
class_name VrwebInlineExporter
extends RefCounted

## Validates a portable page-script declaration for the HTML exporter.

const MIME := "application/vrweb+luau"
const MAX_SOURCE_BYTES := 256 * 1024
const MAX_ID_BYTES := 128


static func prepare(raw: Dictionary) -> Dictionary:
	var script_id := str(raw.get("id", ""))
	var source := str(raw.get("source", ""))
	var src := str(raw.get("src", "")).strip_edges()
	if not _valid_id(script_id):
		return _error("script id отсутствует или недопустим")
	if src.is_empty() == source.is_empty():
		return _error("нужно указать ровно одно из source или src")
	if source.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return _error("source превышает лимит")
	if source.to_lower().contains("</script"):
		return _error("inline source содержит </script; используйте linked script")
	return {"ok": true, "error": "", "definition": {
		"id": script_id, "source": source, "src": src,
		"integrity": str(raw.get("integrity", "")).strip_edges(), "mime": MIME,
	}}


static func _valid_id(value: String) -> bool:
	if value.is_empty() or value.to_utf8_buffer().size() > MAX_ID_BYTES:
		return false
	for character in value:
		if not (character >= "a" and character <= "z") \
				and not (character >= "A" and character <= "Z") \
				and not (character >= "0" and character <= "9") \
				and character not in [".", "_", "-"]:
			return false
	return true


static func valid_id(value: String) -> bool:
	return _valid_id(value)


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message, "definition": {}}
