class_name PolicyEvaluator
extends RefCounted

## Pure, fail-closed authorization evaluator. Context is supplied by the authority transport:
## {actor_user_id, is_authority, rank, verified, bindings}. World code declares rules but
## cannot supply the actor identity or room facts.


static func evaluate(rule, context: Dictionary) -> bool:
	if not _valid_rule(rule):
		return false
	if typeof(rule) == TYPE_STRING:
		match str(rule):
			"anyone": return not str(context.get("actor_user_id", "")).is_empty()
			"authority": return bool(context.get("is_authority", false))
			"verified_identity": return bool(context.get("verified", false))
			_: return false
	if typeof(rule) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = rule
	if d.has("rank"):
		return _evaluate_rank(d["rank"], context)
	if d.has("assigned"):
		var name := str(d["assigned"])
		var bindings: Dictionary = context.get("bindings", {})
		var actor := str(context.get("actor_user_id", ""))
		return not actor.is_empty() and str(bindings.get(name, "")) == actor
	if d.has("vacant"):
		var bindings: Dictionary = context.get("bindings", {})
		return str(bindings.get(str(d["vacant"]), "")).is_empty()
	if d.has("any_of") and typeof(d["any_of"]) == TYPE_ARRAY:
		for child in d["any_of"]:
			if evaluate(child, context):
				return true
		return false
	if d.has("all_of") and typeof(d["all_of"]) == TYPE_ARRAY:
		if (d["all_of"] as Array).is_empty():
			return false
		for child in d["all_of"]:
			if not evaluate(child, context):
				return false
		return true
	if d.has("not"):
		return not evaluate(d["not"], context)
	return false


static func _valid_rule(rule) -> bool:
	if typeof(rule) == TYPE_STRING:
		return rule in ["anyone", "authority", "verified_identity"]
	if typeof(rule) != TYPE_DICTIONARY or (rule as Dictionary).size() != 1:
		return false
	var d: Dictionary = rule
	if d.has("rank"):
		if typeof(d.rank) != TYPE_DICTIONARY:
			return false
		var rank_rule: Dictionary = d.rank
		return rank_rule.has("op") and rank_rule.has("value") \
				and typeof(rank_rule.op) == TYPE_STRING \
				and rank_rule.op in ["lt", "lte", "eq", "gte", "gt"] \
				and typeof(rank_rule.value) == TYPE_INT
	if d.has("assigned") or d.has("vacant"):
		var value = d.get("assigned", d.get("vacant"))
		return typeof(value) == TYPE_STRING and not (value as String).is_empty() \
				and (value as String).is_valid_identifier()
	if d.has("any_of") or d.has("all_of"):
		var children = d.get("any_of", d.get("all_of"))
		if typeof(children) != TYPE_ARRAY or (children as Array).is_empty():
			return false
		for child in children:
			if not _valid_rule(child):
				return false
		return true
	if d.has("not"):
		return _valid_rule(d["not"])
	return false


static func _evaluate_rank(value, context: Dictionary) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var rule: Dictionary = value
	var actual := int(context.get("rank", 1 << 30))
	var expected := int(rule.get("value", 0))
	match str(rule.get("op", "")):
		"lt": return actual < expected
		"lte": return actual <= expected
		"eq": return actual == expected
		"gte": return actual >= expected
		"gt": return actual > expected
		_: return false
