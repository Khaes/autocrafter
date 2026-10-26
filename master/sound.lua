-- sound.lua: end-of-order sound on a speaker on the network or next to the turtle.
-- High chord: order done; low notes: error; nothing for a cancellation. Turned off
-- or on by the button in the title of the main screen, remembered in config.json
-- (sound key, true by default).

local config = require("config")

local sound = {}
sound.enabled = config.sound ~= false

function sound.speaker() return peripheral.find("speaker") end

function sound.toggle()
  sound.enabled = not sound.enabled
  config.sound = sound.enabled
  config.edit(function(data) data.sound = sound.enabled end)
end

-- Notes played together (a speaker plays up to 8 per tick, without waiting)
local NOTES = {
  done = { { "bell", 12 }, { "bell", 16 }, { "bell", 19 } },
  error = { { "bass", 6 }, { "bass", 7 }, { "didgeridoo", 6 } },
}

function sound.play(kind)
  if not sound.enabled or not NOTES[kind] then return end
  local speaker = sound.speaker()
  if not speaker then return end
  for _, n in ipairs(NOTES[kind]) do speaker.playNote(n[1], 1, n[2]) end
end

-- crafter.onFinish: order done, failed or cancelled
function sound.onFinish(order)
  if order.ok then sound.play("done")
  elseif not order.cancel then sound.play("error") end
end

return sound
