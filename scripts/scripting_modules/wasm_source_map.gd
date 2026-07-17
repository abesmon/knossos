class_name WasmSourceMap
extends RefCounted

## Minimal Source Map v3 consumer for guest JavaScript stack frames. It resolves only generated
## line/column to the nearest preceding segment; names and source contents are never exposed.

const _BASE64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const MAX_MAP_BYTES := 8 * 1024 * 1024


static func map_message(message: String, source_map_path: String) -> Dictionary:
	if source_map_path.is_empty() or not FileAccess.file_exists(source_map_path): return {}
	var bytes := FileAccess.get_file_as_bytes(source_map_path)
	if bytes.is_empty() or bytes.size() > MAX_MAP_BYTES: return {}
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed is Dictionary) or int(parsed.get("version", 0)) != 3: return {}
	var generated := str(parsed.get("x_vrweb_generated", parsed.get("file", "")))
	var frame := _guest_frame(message, generated)
	if frame.is_empty(): return {}
	var mapped := _lookup(parsed, int(frame.line) - 1, int(frame.column) - 1)
	if mapped.is_empty(): return {}
	var root := str(parsed.get("sourceRoot", ""))
	var source := str(mapped.source)
	if source.begins_with("/") or source.contains(":\\") or source.contains("../"):
		return {}
	return {"source": root + source, "line": int(mapped.line) + 1,
		"column": int(mapped.column) + 1, "generated_line": int(frame.line),
		"generated_column": int(frame.column)}


static func _guest_frame(message: String, generated: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("([^\\s()]+\\.js):(\\d+):(\\d+)")
	for match_ in regex.search_all(message):
		var file := match_.get_string(1)
		if generated.is_empty() or file.ends_with(generated):
			return {"line": int(match_.get_string(2)), "column": int(match_.get_string(3))}
	return {}


static func _lookup(map: Dictionary, target_line: int, target_column: int) -> Dictionary:
	var sources: Array = map.get("sources", [])
	var lines := str(map.get("mappings", "")).split(";", true)
	if target_line < 0 or target_line >= lines.size(): return {}
	var source_index := 0
	var original_line := 0
	var original_column := 0
	for line_index in target_line + 1:
		var generated_column := 0
		var best := {}
		for segment in str(lines[line_index]).split(",", false):
			var decoded := _decode_segment(segment)
			if decoded.is_empty(): continue
			generated_column += int(decoded[0])
			if decoded.size() >= 4:
				source_index += int(decoded[1])
				original_line += int(decoded[2])
				original_column += int(decoded[3])
				if line_index == target_line and generated_column <= target_column \
						and source_index >= 0 and source_index < sources.size():
					best = {"source": str(sources[source_index]), "line": original_line,
						"column": original_column}
		if line_index == target_line: return best
	return {}


static func _decode_segment(segment: String) -> Array[int]:
	var result: Array[int] = []
	var value := 0
	var shift := 0
	for character in segment:
		var digit := _BASE64.find(character)
		if digit < 0: return []
		var continuation := (digit & 32) != 0
		value += (digit & 31) << shift
		if continuation:
			shift += 5
			continue
		var negative := (value & 1) != 0
		var decoded := value >> 1
		result.append(-decoded if negative else decoded)
		value = 0
		shift = 0
	if shift != 0: return []
	return result
