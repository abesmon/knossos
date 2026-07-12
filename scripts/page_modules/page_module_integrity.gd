class_name PageModuleIntegrity
extends RefCounted

## Проверяет только целостность/изменение артефакта. Не принимает trust-решений об исполнении.


## module — IR PageModuleCollector; resolved_url уже разрешён fetch-слоем.
## previous_hash — ранее виденный hex SHA-256 той же module identity (если есть).
## Результат: {allowed, code, hash, warnings, same_origin}.
static func verify(module: Dictionary, page_url: String, resolved_url: String,
		bytes: PackedByteArray, previous_hash: String = "") -> Dictionary:
	var digest := _sha256(bytes)
	var actual_hex := digest.hex_encode()
	var actual_sri := "sha256-" + Marshalls.raw_to_base64(digest)
	var warnings: Array[String] = []
	if str(module.get("kind", "")) == "inline":
		return _result(true, "ok", actual_hex, warnings, true, actual_sri)

	var same_origin := same_origin(page_url, resolved_url)
	var expected := str(module.get("integrity", "")).strip_edges()
	if not same_origin and expected.is_empty():
		return _result(false, "cross_origin_integrity_required", actual_hex, warnings, false, actual_sri)
	if not expected.is_empty() and expected != actual_sri:
		if same_origin:
			warnings.append("same-origin integrity не совпадает: ожидался %s, получен %s" \
					% [expected, actual_sri])
		else:
			return _result(false, "integrity_mismatch", actual_hex, warnings, false, actual_sri)
	if same_origin and not previous_hash.is_empty() and previous_hash != actual_hex:
		warnings.append("same-origin module изменился: ранее %s, сейчас %s" \
				% [previous_hash, actual_hex])
	return _result(true, "ok_with_warning" if not warnings.is_empty() else "ok",
			actual_hex, warnings, same_origin, actual_sri)


static func sri_sha256(bytes: PackedByteArray) -> String:
	return "sha256-" + Marshalls.raw_to_base64(_sha256(bytes))


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return PackedByteArray()
	context.update(bytes)
	return context.finish()


static func origin_of(url: String) -> String:
	var scheme_end := url.find("://")
	if scheme_end <= 0:
		return ""
	var scheme := url.substr(0, scheme_end).to_lower()
	var authority_start := scheme_end + 3
	var authority_end := url.length()
	for separator in ["/", "?", "#"]:
		var pos := url.find(separator, authority_start)
		if pos != -1:
			authority_end = mini(authority_end, pos)
	var authority := url.substr(authority_start, authority_end - authority_start).to_lower()
	if authority.is_empty():
		return ""
	# Нормализуем стандартные порты; userinfo в module URL не поддерживаем.
	if authority.contains("@"):
		return ""
	if scheme == "http" and authority.ends_with(":80"):
		authority = authority.left(-3)
	elif scheme == "https" and authority.ends_with(":443"):
		authority = authority.left(-4)
	return scheme + "://" + authority


static func same_origin(page_url: String, resource_url: String) -> bool:
	# В локальных VRWeb-схемах часть после :// — путь, а не HTTP authority.
	for scheme in ["vrwebresource://", "vrweblocal://"]:
		if page_url.begins_with(scheme) or resource_url.begins_with(scheme):
			return page_url.begins_with(scheme) and resource_url.begins_with(scheme)
	var page_origin := origin_of(page_url)
	return not page_origin.is_empty() and page_origin == origin_of(resource_url)


static func _result(allowed: bool, code: String, hash: String, warnings: Array[String],
		same_origin: bool, sri: String) -> Dictionary:
	return {"allowed": allowed, "code": code, "hash": hash, "sri": sri,
		"warnings": warnings, "same_origin": same_origin}
