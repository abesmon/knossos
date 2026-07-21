extends Node

## Smoke test for the pinned Luau GDExtension used by VRWeb page scripting.

var _failed := false


func _ready() -> void:
	_eq(ClassDB.class_exists(&"LuaState"), true, "LuaState extension is registered")
	_eq(ClassDB.class_exists(&"Luau"), true, "Luau compiler is registered")
	if not _failed:
		_test_vm()
		_test_page_runtime()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _test_vm() -> void:
	var state = ClassDB.instantiate(&"LuaState")
	_eq(state.has_signal(&"interrupt"), true, "Luau interrupt hook is available")
	state.open_libs()
	var bytecode: PackedByteArray = Luau.compile("return 40 + 2")
	_eq(state.load_bytecode(bytecode, "@vrweb-source:///smoke.luau"), true,
			"Luau source loads")
	_eq(state.pcall(0, 1), Luau.LUA_OK, "Luau source executes")
	_eq(state.to_integer(-1), 42, "Luau result crosses the host boundary")
	state.close()


func _test_page_runtime() -> void:
	var page := Node3D.new()
	add_child(page)
	var lamp := Node3D.new()
	page.add_child(lamp)
	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	runtime.setup(page, {"lamp": lamp}, "https://example.test/world/index.html", null,
			VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var source := """
assert(Object == nil and FileAccess == nil and os == nil and debug == nil)
assert(require == nil and loadstring == nil)
assert(SharedUtils ~= nil and SharedUtils.increment(40) == 42)
local lamp = document.query("#lamp")
assert(lamp ~= nil)
assert(lamp.set("visible", "not-a-bool") == false)
assert(document.create("Label3D", { font_size = "not-an-int" }) == nil)
lamp.set("visible", false)
document.session.count = (document.session.count or 0) + 1
assert(document.state.define("lamp_state", {
    version = 1,
    fields = { enabled = { type = "bool", default = false } },
    commands = {},
}))
assert(document.state.ensure("lamp", "lamp_state", { enabled = false }, ""))
-- Regression: handle.on must accept the documented two-argument form; the optional hint
-- is supplied by the trusted runtime wrapper before crossing the host boundary.
lamp.on("activate", function(_event)
    lamp.set("visible", true)
end)
lamp.on("visibility_changed", function(_event)
    document.session.signal_seen = true
end)
"""
	var utility_source := """
SharedUtils = {}
function SharedUtils.increment(value)
    return value + 2
end
"""
	var unsupported := runtime.activate([{"id": "wrong.profile", "profile": "other/1",
		"kind": "inline", "source": "return 1", "hash": ""}])
	_eq(unsupported.ok, false, "unsupported runtime profile is rejected")
	var activated := runtime.activate([
		{"id": "page.utils", "profile": "vrweb-luau/1", "kind": "linked",
			"source": utility_source, "hash": utility_source.sha256_text()},
		{"id": "page.lamp", "profile": "vrweb-luau/1", "kind": "inline",
			"source": source, "hash": source.sha256_text()},
	])
	_eq(activated.ok, true, "page script with two-argument handle.on activates")
	_eq(activated.activated, ["page.utils", "page.lamp"],
			"linked utility and inline consumer execute in document order")
	_eq(lamp.visible, false, "top-level mutation commits after successful execution")
	_eq(runtime.session_of("page.lamp").get("count"), 1, "document.session is captured")
	_eq(runtime.session_of("page.utils").get("count"), 1,
			"document.session is shared by all script tags on the page")
	var duplicate := runtime.activate([{"id": "page.lamp", "profile": "vrweb-luau/1",
		"kind": "inline", "source": "return 1", "hash": ""}])
	_eq(duplicate.ok, false, "an active script id cannot be overwritten through activate")
	var bridge = lamp.get_meta(VrwebScriptInputBridge.META, null)
	_eq(bridge is VrwebScriptInputBridge, true, "activation handler uses opaque host bridge")
	if bridge is VrwebScriptInputBridge:
		_eq(bridge.hint(), "", "two-argument handle.on supplies an empty hint")
		bridge.dispatch(Vector3.ZERO)
	_eq(lamp.visible, true, "Luau callback mutates borrowed handle")
	_eq(runtime.session_of("page.lamp").get("signal_seen"), true,
			"two-argument handle.on dispatches a native signal")

	var bad := runtime.replace("page.lamp", "local = broken", runtime.active_hashes()["page.lamp"])
	_eq(bad.ok, false, "invalid hot reload is rejected")
	_eq(runtime.session_of("page.lamp").get("count"), 1, "failed reload preserves session")
	var loop := runtime.replace("page.lamp", "while true do end",
			runtime.active_hashes()["page.lamp"])
	_eq(loop.ok, false, "watchdog interrupts an infinite top-level loop")
	_eq(runtime.active_hashes().has("page.lamp"), true, "watchdog keeps old revision active")
	var active_before_commit_failure: String = runtime.active_hashes()["page.lamp"]
	var invalid_commit := runtime.replace("page.lamp", """
document.state.define("lamp_state", { version = 1, fields = {}, commands = {} })
""", active_before_commit_failure)
	_eq(invalid_commit.ok, false, "failed staged state commit rejects replacement")
	_eq(runtime.active_hashes()["page.lamp"], active_before_commit_failure,
			"failed commit preserves active revision")

	var replacement := """
assert(SharedUtils.increment(40) == 42)
local lamp = document.query("#lamp")
document.session.count = (document.session.count or 0) + 1
lamp.on("activate", function(_event)
    lamp.set("visible", false)
end, "Switch v2")
"""
	var replaced := runtime.replace("page.lamp", replacement, runtime.active_hashes()["page.lamp"])
	_eq(replaced.ok, true, "valid hot reload commits")
	_eq(runtime.session_of("page.lamp").get("count"), 2, "hot reload preserves session")
	bridge = lamp.get_meta(VrwebScriptInputBridge.META, null)
	if bridge is VrwebScriptInputBridge:
		_eq(bridge.hint(), "Switch v2", "three-argument handle.on preserves its hint")
		bridge.dispatch(Vector3.ZERO)
	_eq(lamp.visible, false, "hot reload atomically replaces handlers")
	var callback_loop := """
local lamp = document.query("#lamp")
lamp.on("activate", function(_event)
    while true do end
end, "Loop")
"""
	var loop_replaced := runtime.replace("page.lamp", callback_loop,
			runtime.active_hashes()["page.lamp"])
	_eq(loop_replaced.ok, true, "callback watchdog fixture activates")
	bridge = lamp.get_meta(VrwebScriptInputBridge.META, null)
	if bridge is VrwebScriptInputBridge:
		bridge.dispatch(Vector3.ZERO)
	_eq(runtime.active_hashes().has("page.lamp"), false,
			"watchdog removes a realm after an infinite callback")
	runtime.close()
	runtime.queue_free()
	page.queue_free()


func _eq(actual, expected, label: String) -> void:
	if actual == expected:
		print("  [ok]  ", label)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
