class_name StateSwitchSchema
extends RefCounted

const ID := "vrweb.state-switch"
const VERSION := 1


static func definition(default_rank: int) -> Dictionary:
	return {
		"version": VERSION,
		"fields": {"enabled": {"type": "bool", "default": false}},
		"default_write_rule": {"rank": {"op": "lte", "value": default_rank}},
		"commands": {"toggle": {"reducer": StateSwitchSchema.reduce_toggle}},
	}


static func reduce_toggle(state: Dictionary, _args: Dictionary, _context: Dictionary) -> Dictionary:
	return {"enabled": not bool(state.get("enabled", false))}
