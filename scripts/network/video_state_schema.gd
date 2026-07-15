class_name VideoStateSchema
extends RefCounted

const ID := "vrweb.video.transport"
const VERSION := 1
const MAX_POSITION := 86400.0 * 30.0


static func definition(default_rank: int) -> Dictionary:
	return {
		"version": VERSION,
		"fields": {
			"playing": {"type": "bool", "default": false},
			"anchor_position": {"type": "float", "default": 0.0, "min": 0.0, "max": MAX_POSITION},
			"anchor_authority_msec": {"type": "int", "default": 0, "min": 0},
			"media_revision": {"type": "int", "default": 0, "min": 0},
		},
		"sample_fields": {
			"position": {"type": "float", "default": 0.0, "min": 0.0, "max": MAX_POSITION},
			"playing": {"type": "bool", "default": false},
			"revision": {"type": "int", "default": 0, "min": 0},
		},
		"default_write_rule": {"rank": {"op": "lte", "value": default_rank}},
		"commands": {
			"set_playing": {"reducer": VideoStateSchema.reduce_set_playing},
			"seek": {"reducer": VideoStateSchema.reduce_seek},
		},
	}


static func reduce_set_playing(_state: Dictionary, args: Dictionary, context: Dictionary) -> Dictionary:
	if typeof(args.get("playing")) != TYPE_BOOL or not _valid_position(args.get("position")):
		return {}
	return {
		"playing": bool(args["playing"]),
		"anchor_position": float(args["position"]),
		"anchor_authority_msec": int(context.get("authority_msec", 0)),
	}


static func reduce_seek(state: Dictionary, args: Dictionary, context: Dictionary) -> Dictionary:
	if not _valid_position(args.get("position")):
		return {}
	return {
		"playing": bool(state.get("playing", false)),
		"anchor_position": float(args["position"]),
		"anchor_authority_msec": int(context.get("authority_msec", 0)),
	}


static func _valid_position(value) -> bool:
	return (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) \
			and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= MAX_POSITION
