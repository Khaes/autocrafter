-- machines/burner.lua: heating a station with a blaze burner
-- The modem cannot see the burner, but it sees a deployer (1 slot = held item).
-- The deployer gives its item to the burner once the burner is down to 10-15 % fuel.
-- Fuel is put in its hand only during a heated batch, then taken back: the burner
-- goes out while the station is idle.
--
-- Station (config.stations): { name = "create:basin_3", heat = "superheated",
--                              burner = "create:deployer_1", fuel = { ... } }
--   heat: highest level the station can reach
--   fuel: fuels per level, else config.fuel, else FUEL below

local config = require("config")
local storage = require("storage")

local burner = {}

local LEVELS = { heated = 1, superheated = 2 }
local FUEL = {
  heated = { "minecraft:charcoal", "minecraft:coal" },
  superheated = { "create:blaze_cake" },
}

-- 0 = no heat, 1 = heated, 2 = superheated
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

-- Takes back what the deployer holds; false if the storage is full
function burner.clear(station)
  if not station.burner then return true end
  local held = peripheral.wrap(station.burner).list()[1]
  if not held then return true end
  return storage.import(station.burner, 1) >= held.count
end

-- Gives the deployer a fuel of level `heat` if it does not hold one;
-- returns nil, or an error message
function burner.feed(station, heat)
  if not station.burner then
    return "No burner for " .. station.name .. " (burner in config.json)"
  end
  if not peripheral.isPresent(station.burner) then
    return "Burner not found: " .. station.burner
  end
  local held = peripheral.wrap(station.burner).list()[1]
  if held and isFuel(station, heat, held.name) then return end
  if held and not burner.clear(station) then return "Storage full" end
  for _, f in ipairs(fuels(station, heat)) do
    if storage.export(f, 1, station.burner) > 0 then return end
  end
  return ("No %s fuel for %s"):format(heat, station.name)
end

return burner
