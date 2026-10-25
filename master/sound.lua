-- sound.lua : son de fin de commande sur un haut-parleur (speaker) du réseau ou collé à
-- la turtle. Accord aigu : commande finie ; notes graves : erreur ; rien pour une
-- annulation. Coupé ou remis par le bouton du titre de l'écran principal, retenu dans
-- config.json (clé sound, true par défaut).

local config = require("config")

local sound = {}
sound.enabled = config.sound ~= false

function sound.speaker() return peripheral.find("speaker") end

function sound.toggle()
  sound.enabled = not sound.enabled
  config.sound = sound.enabled
  config.edit(function(data) data.sound = sound.enabled end)
end

-- Notes jouées ensemble (un speaker en joue jusqu'à 8 par tick, sans attendre)
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

-- crafter.onFinish : commande finie, en erreur ou annulée
function sound.onFinish(order)
  if order.ok then sound.play("done")
  elseif not order.cancel then sound.play("error") end
end

return sound
