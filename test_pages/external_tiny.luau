local label = document.query("#external-label")
local spinner = document.query("#external-spinner")

if not label or not spinner then
  error("linked script demo scene ids are missing")
end

label.set("text", "LINKED LUAU SCRIPT")

local label_accumulator = 1.0
assert(document.on_update(function(frame)
  local t = frame.local_time

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
      "LINKED LUAU SCRIPT\nanimated for %.1f s",
      t))
  end
end))
