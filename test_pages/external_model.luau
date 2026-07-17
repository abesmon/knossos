-- Module 1: private model. Other realms cannot access these locals directly.
local VIEW_SCRIPT_ID = "demo.external.view"
local speeds = { 0.5, 1.0, 2.0 }
local speed_index = 2
local status = document.query("#model-status")

if not status then
  error("external model status is missing")
end

local function publish_speed()
  local speed = speeds[speed_index]
  local me = document.players.local_info()
  status.set("text", string.format(
    "1 · EXTERNAL MODEL\nprivate speed = %.1fx\n→ VIEW: apply-speed(speed)",
    speed))
  return document.remote.call(
    me.peer_id, VIEW_SCRIPT_ID, "apply-speed", 1, { speed })
end

assert(document.remote.expose("cycle-speed", {
  version = 1,
  args = {},
}, function(_event)
  speed_index = speed_index % #speeds + 1
  assert(publish_speed())
end))

-- Calls made during activation are delivered after all three realms are committed,
-- so the view endpoint below is ready by the time this message arrives.
assert(publish_speed())
