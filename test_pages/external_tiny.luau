local label = document.query("#external-label")
local spinner = document.query("#external-spinner")
local status = document.query("#view-status")

if not label or not spinner or not status then
  error("linked script demo scene ids are missing")
end

-- Module 2: view. `speed` is private to this realm and changes only through
-- the typed endpoint exposed below.
local speed = 1.0

assert(document.remote.expose("apply-speed", {
  version = 1,
  args = { "float" },
}, function(event)
  speed = event.args[1]
  status.set("text", string.format(
    "2 · EXTERNAL VIEW\napply-speed(%.1f) received",
    speed))
end))

label.set("text", "2 LINKED FILES + 1 INLINE SCRIPT")
status.set("text", "2 · EXTERNAL VIEW\nendpoint apply-speed(float) ready")

local label_accumulator = 1.0
assert(document.on_update(function(frame)
  local t = frame.local_time * speed

  spinner.set("position", document.values.vector3(
    math.sin(t * 1.4) * 1.6,
    math.sin(t * 2.8) * 0.35 - 0.15,
    0.0))
  spinner.set("rotation_degrees", document.values.vector3(
    t * 55.0,
    t * 90.0,
    t * 25.0))

  label_accumulator = label_accumulator + frame.delta
  if label_accumulator >= 0.1 then
    label_accumulator = 0.0
    label.set("text", string.format(
      "2 LINKED FILES + 1 INLINE SCRIPT\nview time %.1f s · speed %.1fx",
      t, speed))
  end
end))
