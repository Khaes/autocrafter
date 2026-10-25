-- machines/burner.lua : chauffe d'un poste par un blaze burner
-- Le burner n'est pas vu par le modem : un deployer, lui, l'est (1 case = item tenu).
-- Il donne son item au burner quand celui-ci n'a plus que 10-15 % de combustible.
-- On ne met du combustible dans sa main que pendant un lot chauffé, puis on le
-- reprend : le burner s'éteint quand le poste ne travaille pas.
--
-- Poste (config.stations) : { name = "create:basin_3", heat = "superheated",
--                             burner = "create:deployer_1", fuel = { ... } }
--   heat : niveau maximum que le poste peut atteindre
--   fuel : combustibles par niveau, sinon config.fuel, sinon FUEL ci-dessous

local config = require("config")
local storage = require("storage")

local burner = {}

local LEVELS = { heated = 1, superheated = 2 }
local FUEL = {
  heated = { "minecraft:charcoal", "minecraft:coal" },
  superheated = { "create:blaze_cake" },
}

-- 0 = pas de chaleur, 1 = heated, 2 = superheated
function burner.level(heat)
  return LEVELS[heat] or 0
end

local function fuels(station, heat)
  local t = station.fuel or config.fuel or FUEL
  return t[heat] or {}
end
burner.fuels = fuels

local function isFuel(station, heat, item)
  for _, f in ipairs(fuels(station, heat)) do
    if f == item then return true end
  end
  return false
end

-- Reprend ce que tient le deployer ; false si le stockage est plein
function burner.clear(station)
  if not station.burner then return true end
  local held = peripheral.wrap(station.burner).list()[1]
  if not held then return true end
  return storage.import(station.burner, 1) >= held.count
end

-- Donne au deployer un combustible du niveau `heat` s'il n'en tient pas ;
-- renvoie nil, ou un message d'erreur
function burner.feed(station, heat)
  if not station.burner then
    return "Pas de burner pour " .. station.name .. " (burner dans config.lua)"
  end
  if not peripheral.isPresent(station.burner) then
    return "Burner introuvable : " .. station.burner
  end
  local held = peripheral.wrap(station.burner).list()[1]
  if held and isFuel(station, heat, held.name) then return end
  if held and not burner.clear(station) then return "Stockage plein" end
  for _, f in ipairs(fuels(station, heat)) do
    if storage.export(f, 1, station.burner) > 0 then return end
  end
  return ("Pas de combustible %s pour %s"):format(heat, station.name)
end

return burner
