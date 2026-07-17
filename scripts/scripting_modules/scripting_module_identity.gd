class_name ScriptingModuleIdentity
extends RefCounted

## Canonical multiplayer identity for executable page content. It contains declarations and
## hashes only; component bytes are always fetched through the normal page delivery path.


static func canonical(modules: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_module in modules:
		var module := raw_module as Dictionary
		var manifest: Dictionary = module.get("manifest", {})
		var world := str(manifest.get("world", module.get("world", "")))
		var major := 0
		if world.contains("@"):
			var raw_major := world.rsplit("@", true, 1)[-1].get_slice(".", 0)
			if raw_major.is_valid_int(): major = int(raw_major)
		result.append({
			"id": str(module.get("id", "")),
			"runtime": str(manifest.get("runtime", module.get("runtime", ""))),
			"world_major": major,
			"hash": str(module.get("hash", "")),
		})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return str(left.id) < str(right.id))
	return result


static func digest(identity: Array) -> String:
	var canonical_json := JSON.stringify(identity)
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(canonical_json.to_utf8_buffer())
	return context.finish().hex_encode()


static func room_key(page_seed: String, identity: Array) -> String:
	if identity.is_empty(): return page_seed
	return "%s-wasm-%s" % [page_seed, digest(identity).substr(0, 24)]


static func compare(local: Array, remote: Array, runtime_available: bool = true) -> Dictionary:
	if local == remote:
		return {"outcome": "compatible" if runtime_available else "degraded",
			"code": "" if runtime_available else "runtime_unavailable"}
	return {"outcome": "rejected", "code": "module_identity_mismatch"}


static func required_capabilities(modules: Array) -> Array[String]:
	var result: Array[String] = []
	for raw_module in modules:
		var module := raw_module as Dictionary
		var manifest: Dictionary = module.get("manifest", {})
		for capability in manifest.get("requires", module.get("requires", [])):
			if str(capability) not in result:
				result.append(str(capability))
	result.sort()
	return result
