-- The first linked file declares a reusable class in the page global scope.
SpeedModel = {}
SpeedModel.__index = SpeedModel

function SpeedModel.new(speeds)
  assert(type(speeds) == "table" and #speeds > 0)
  return setmetatable({
    speeds = speeds,
    speed_index = math.min(2, #speeds),
  }, SpeedModel)
end

function SpeedModel:current_speed()
  return self.speeds[self.speed_index]
end

function SpeedModel:cycle_speed()
  self.speed_index = self.speed_index % #self.speeds + 1
  return self:current_speed()
end
