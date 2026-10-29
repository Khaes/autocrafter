-- stations.lua: stations from config.stations, grouped by machine
-- A machine has one station { name = ... } or a list of stations { { name = ... }, ... }
-- (`flow` stations: { inlet = ..., output = ... } instead of name)

local config = require("config")
local burner = require("machines.burner")

local stations = {}

-- The turtle itself: one craft at a time. Workers (step 7) are extra "turtle"
-- stations: config.stations.turtle = { { worker = ID, buffer = ... } }
local TURTLE = { name = "turtle" }

-- Stations of a machine, always as a list; an empty list ({} or [] in the JSON)
-- means no station, not a station without a name
local function configured(machineName)
  local s = config.stations and config.stations[machineName]
  if not s or next(s) == nil then return {} end
  if not s[1] then return { s } end
  return s
end

-- Stations that can make the recipes of `machineName` (empty list if none);
-- with `heat`, only those that get hot enough (a superheated station also does heated)
function stations.pool(machineName, heat)
  if machineName == "turtle" then return { TURTLE, table.unpack(configured("turtle")) } end
  -- Stonecutter recipes: the saw stations whose saw is on the network (saw = its name),
  -- the filter chooses among the results of an item
  if machineName == "stonecutting" then
    local t = {}
    for _, s in ipairs(configured("sawing")) do
      if s.saw then t[#t + 1] = s end
    end
    return t
  end
  local t = {}
  for _, s in ipairs(configured(machineName)) do
    if burner.level(s.heat) >= burner.level(heat) then t[#t + 1] = s end
  end
  return t
end

-- Stations of config.stations for `machineName`, always as a list (without the main turtle)
stations.list = configured

-- Possible outputs of an order: config.outputs (network names, or { name, label }).
-- List of { name, label }, the default output first
function stations.outputs()
  local t = {}
  for _, o in ipairs(config.outputs or {}) do
    local name = type(o) == "table" and o.name or o
    t[#t + 1] = { name = name, label = type(o) == "table" and o.label or (name:gsub("^.-:", "")) }
  end
  return t
end

-- Name of the default output (the first one), nil if there is none
function stations.defaultOutput()
  local first = stations.outputs()[1]
  return first and first.name
end

-- Every configured station, all machines together
function stations.all()
  local t = {}
  for machineName in pairs(config.stations or {}) do
    for _, s in ipairs(configured(machineName)) do t[#t + 1] = s end
  end
  return t
end

return stations
