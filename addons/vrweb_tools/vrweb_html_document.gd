@tool
class_name VrwebHtmlDocument
extends RefCounted

## Lossless envelope helper for editable HTML scenes. HtmlParser intentionally normalizes
## markup when serializing; this scanner instead remembers the exact source range occupied by
## the first real <vrweb> block, so saving can replace only that range byte-for-byte around it.

const META_SOURCE_PATH := "vrweb_html_source_path"
const META_MODE := "vrweb_html_mode"
const META_IMPORTED := "vrweb_html_imported"
const META_BLOCK_HASH := "vrweb_html_block_hash"
const META_READ_ONLY_REASON := "vrweb_html_read_only_reason"
const META_PREVIEW := "vrweb_html_read_only_preview"
const META_PREVIEW_IMAGE_URL := "vrweb_html_preview_image_url"
const META_PREVIEW_ROOMS := "vrweb_html_preview_rooms"
const META_PREVIEW_DOORS := "vrweb_html_preview_doors"
const META_PREVIEW_CORRIDORS := "vrweb_html_preview_corridors"

const RAW_TEXT_TAGS := {"script": true, "style": true, "textarea": true, "title": true}


## {ok,start,end,block,error}; end is exclusive. Comments and raw-text contents are skipped,
## so strings such as `const demo = "<vrweb>"` are not mistaken for the scene block.
static func locate(source: String) -> Dictionary:
	var lower := source.to_lower()
	var pos := 0
	while pos < source.length():
		var token := _next_tag(source, lower, pos)
		if not bool(token.ok):
			return token
		if bool(token.eof):
			return {"ok": false, "error": "HTML не содержит <vrweb>"}
		pos = int(token.end)
		if bool(token.get("skip", false)):
			continue
		var name := str(token.name)
		if not bool(token.closing) and RAW_TEXT_TAGS.has(name):
			var close_at := lower.find("</" + name, pos)
			if close_at < 0:
				return {"ok": false, "error": "Незакрытый <%s> перед <vrweb>" % name}
			var close_end := _find_tag_end(source, close_at + 2 + name.length())
			if close_end < 0:
				return {"ok": false, "error": "Незакрытый </%s>" % name}
			pos = close_end + 1
			continue
		if name != "vrweb" or bool(token.closing):
			continue
		var start := int(token.start)
		var depth := 1
		while pos < source.length():
			var inner := _next_tag(source, lower, pos)
			if not bool(inner.ok):
				return inner
			if bool(inner.eof):
				return {"ok": false, "error": "Незакрытый <vrweb>"}
			pos = int(inner.end)
			if bool(inner.get("skip", false)):
				continue
			var inner_name := str(inner.name)
			if not bool(inner.closing) and RAW_TEXT_TAGS.has(inner_name):
				var raw_close := lower.find("</" + inner_name, pos)
				if raw_close < 0:
					return {"ok": false, "error": "Незакрытый <%s> внутри <vrweb>" % inner_name}
				var raw_end := _find_tag_end(source, raw_close + 2 + inner_name.length())
				if raw_end < 0:
					return {"ok": false, "error": "Незакрытый </%s>" % inner_name}
				pos = raw_end + 1
				continue
			if inner_name != "vrweb":
				continue
			depth += -1 if bool(inner.closing) else 1
			if depth == 0:
				var finish := int(inner.end)
				return {"ok": true, "start": start, "end": finish,
					"block": source.substr(start, finish - start), "error": ""}
	return {"ok": false, "error": "HTML не содержит <vrweb>"}


static func replace_block(source: String, replacement: String) -> Dictionary:
	var span := locate(source)
	if not bool(span.ok):
		return {"ok": false, "html": "", "error": str(span.error)}
	var start := int(span.start)
	var finish := int(span.end)
	return {"ok": true,
		"html": source.substr(0, start) + replacement + source.substr(finish),
		"error": ""}


## Finds the next syntactic tag. `end` is exclusive. Declarations/comments are returned as
## skip tokens; malformed trailing markup is a hard error because lossless replacement would
## otherwise target an ambiguous range.
static func _next_tag(source: String, lower: String, from: int) -> Dictionary:
	var lt := source.find("<", from)
	if lt < 0:
		return {"ok": true, "eof": true}
	if lower.substr(lt, 4) == "<!--":
		var comment_end := lower.find("-->", lt + 4)
		if comment_end < 0:
			return {"ok": false, "error": "Незакрытый HTML-комментарий"}
		return {"ok": true, "eof": false, "skip": true, "end": comment_end + 3}
	var gt := _find_tag_end(source, lt + 1)
	if gt < 0:
		return {"ok": false, "error": "Незакрытый HTML-тег"}
	var body := source.substr(lt + 1, gt - lt - 1).strip_edges()
	if body.is_empty() or body.begins_with("!") or body.begins_with("?"):
		return {"ok": true, "eof": false, "skip": true, "end": gt + 1}
	var closing := body.begins_with("/")
	if closing:
		body = body.substr(1).strip_edges()
	var name_end := 0
	while name_end < body.length() and not body[name_end] in [" ", "\t", "\r", "\n", "/"]:
		name_end += 1
	var name := body.substr(0, name_end).to_lower()
	return {"ok": true, "eof": false, "skip": name.is_empty(), "start": lt,
		"end": gt + 1, "name": name, "closing": closing}


static func _find_tag_end(source: String, from: int) -> int:
	var quote := ""
	for i in range(from, source.length()):
		var ch := source[i]
		if quote != "":
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == ">":
			return i
	return -1
