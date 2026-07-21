class_name VrwebScriptRender
extends RefCounted

## Runtime shader/material resources for one page realm. Engine resources stay behind opaque
## dictionaries; the page can compose them and apply a material through DocumentHost's checked
## property boundary.

const LANGUAGE := "godot-shader"
const STANDARD_SHADER_INPUTS := [{
	"name": "AUTHORITY_TIME",
	"type": "float",
	"writable": false,
	"semantic": "vrweb authority clock in seconds; local monotonic fallback when unsynchronized",
}]
const SHADER_TYPES := {
	"spatial": Shader.MODE_SPATIAL,
	"canvas_item": Shader.MODE_CANVAS_ITEM,
	"particles": Shader.MODE_PARTICLES,
	"sky": Shader.MODE_SKY,
	"fog": Shader.MODE_FOG,
}

var _script_id := ""
var _apply: Callable
var _policy: VrwebContentPolicy
var _valid := true
var _resources: Array[Resource] = []
var _materials: Array[ShaderMaterial] = []
var _authority_time := 0.0


func setup(script_id: String, apply: Callable, policy: VrwebContentPolicy) -> void:
	_script_id = script_id
	_apply = apply
	_policy = policy


## Возвращает поверхность document.shaders (capability vrweb/shaders/1) — без промежуточного
## namespace render: других жителей у него не было.
func api() -> Dictionary:
	return {"supports": supports_shader, "compile": compile_shader,
		"constants": shader_constants}


func shader_constants() -> Array:
	return STANDARD_SHADER_INPUTS.duplicate(true) if _valid else []


func update_clock(clock: Dictionary) -> void:
	if not _valid:
		return
	_authority_time = float(clock.get("authority_time", 0.0))
	for material in _materials:
		if material != null:
			material.set_shader_parameter("AUTHORITY_TIME", _authority_time)


func close() -> void:
	_valid = false
	_materials.clear()
	_resources.clear()
	_apply = Callable()


func supports_shader(descriptor: Dictionary) -> bool:
	if not _valid or str(descriptor.get("language", "")) != LANGUAGE:
		return false
	var version: Dictionary = Engine.get_version_info()
	var expected := "%d.%d" % [int(version.get("major", 0)), int(version.get("minor", 0))]
	return str(descriptor.get("version", "")) == expected \
			and SHADER_TYPES.has(str(descriptor.get("type", "")))


func compile_shader(descriptor: Dictionary) -> Dictionary:
	if not supports_shader(descriptor):
		return _failure("unsupported_format", "shader format is not supported by this client")
	var source := str(descriptor.get("source", ""))
	var shader_type := str(descriptor.get("type", ""))
	if source.is_empty():
		return _failure("empty_source", "shader source is empty")
	if not source.contains("shader_type %s" % shader_type):
		return _failure("shader_type", "source shader_type does not match descriptor")
	if _policy != null and not VrwebContentPolicy.allowed(_policy.evaluate_operation(
			"script_shader_compile", {"language": LANGUAGE, "type": shader_type},
			{"source": "script", "script_id": _script_id})):
		return _failure("policy", "shader compilation is disabled by client policy")
	var injected := _inject_standard_inputs(source, shader_type)
	if injected.is_empty():
		return _failure("shader_type", "shader_type declaration must end with a semicolon")
	var shader := Shader.new()
	shader.code = injected
	_resources.append(shader)
	return {"ok": true, "shader": _shader_handle(shader, descriptor), "diagnostics": [],
		"error": ""}


func _shader_handle(shader: Shader, descriptor: Dictionary) -> Dictionary:
	var format := {
		"language": str(descriptor.get("language", "")),
		"version": str(descriptor.get("version", "")),
		"type": str(descriptor.get("type", "")),
	}
	return {
		"__vrweb_host": "shader",
		"format": func(): return format.duplicate(true),
		"parameters": func(): return _shader_parameters(shader),
		"create_material": func(): return _create_material(shader),
	}


func _shader_parameters(shader: Shader) -> Array:
	if not _valid or shader == null:
		return []
	var result: Array = []
	for item in shader.get_shader_uniform_list():
		result.append({
			"name": str(item.get("name", "")),
			"type": int(item.get("type", TYPE_NIL)),
			"hint": int(item.get("hint", PROPERTY_HINT_NONE)),
			"hint_string": str(item.get("hint_string", "")),
		})
	return result


func _create_material(shader: Shader):
	if not _valid or shader == null:
		return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("AUTHORITY_TIME", _authority_time)
	_materials.append(material)
	_resources.append(material)
	return _material_handle(material)


func _material_handle(material: ShaderMaterial) -> Dictionary:
	return {
		"__vrweb_host": "material",
		"set_parameter": func(name: String, value):
			if not _valid or material == null:
				return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
			if name == "AUTHORITY_TIME":
				# Зарезервированные VRWeb shader inputs read-only для автора.
				return VrwebScriptError.err(VrwebScriptError.DENIED)
			if value is Object:
				return VrwebScriptError.err(VrwebScriptError.INVALID_ARGS)
			material.set_shader_parameter(name, value)
			return true,
		"get_parameter": func(name: String):
			return material.get_shader_parameter(name) if _valid and material != null else null,
		"apply": func(target: Dictionary, property: String):
			if not _valid or not _apply.is_valid():
				return VrwebScriptError.err(VrwebScriptError.LIFECYCLE)
			return _apply.call(material, target, property),
	}


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "shader": null,
		"diagnostics": [{"severity": "error", "message": message}], "error": code}


static func _inject_standard_inputs(source: String, shader_type: String) -> String:
	# Authors use reserved VRWeb names directly. The runtime owns their engine-specific
	# declarations so future standard globals do not require boilerplate in every source.
	if source.contains("uniform float AUTHORITY_TIME"):
		return source
	var type_offset := source.find("shader_type %s" % shader_type)
	var declaration_end := source.find(";", type_offset)
	if type_offset < 0 or declaration_end < 0:
		return ""
	return source.insert(declaration_end + 1,
			"\n\n// Injected VRWeb shader inputs.\nuniform float AUTHORITY_TIME;")
