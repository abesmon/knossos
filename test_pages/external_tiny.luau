-- The second linked file sees the class declared by external_model.luau and
-- declares another reusable class for the following inline script.
assert(SpeedModel)
SpinnerView = {}
SpinnerView.__index = SpinnerView

function SpinnerView.new(model, spinner, label, status)
  assert(getmetatable(model) == SpeedModel)
  return setmetatable({
    model = model,
    spinner = spinner,
    label = label,
    status = status,
    label_accumulator = 1.0,
  }, SpinnerView)
end

function SpinnerView:show_speed()
  self.status.set("text", string.format(
    "2 · external_tiny.luau\nSpinnerView uses SpeedModel: %.1fx",
    self.model:current_speed()))
end

function SpinnerView:start()
  self.label.set("text", "2 LINKED FILES + 1 INLINE SCRIPT")
  self:show_speed()
  assert(document.on_update(function(frame)
    local speed = self.model:current_speed()
    local t = frame.local_time * speed

    self.spinner.set("position", document.values.vector3(
      math.sin(t * 1.4) * 1.6,
      math.sin(t * 2.8) * 0.35 - 0.15,
      0.0))
    self.spinner.set("rotation_degrees", document.values.vector3(
      t * 55.0,
      t * 90.0,
      t * 25.0))

    self.label_accumulator = self.label_accumulator + frame.delta
    if self.label_accumulator >= 0.1 then
      self.label_accumulator = 0.0
      self.label.set("text", string.format(
        "SHARED PAGE REALM\nview time %.1f s · speed %.1fx",
        t, speed))
    end
  end))
end
