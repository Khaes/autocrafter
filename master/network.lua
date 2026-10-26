-- network.lua: network blocks named in the configuration (step 9)
--
-- check()  : every block of the configuration (storage, buffer, outputs, trash,
--            tanks, station blocks, workers), present or not, and the network blocks
--            that no role uses. Result kept in network.state.
-- repair() : the modem renumbers a block that was broken and placed again
--            (chest_1 -> chest_3). When a single block of a type is missing and a
--            single new block of that type appeared, it replaces it in config.json
--            and in the configuration in memory.

local config = require("config")
local stations = require("stations")

local network = {}

-- Station fields that are network names, in display order
local KEYS = { "name", "inlet", "output", "spout", "deployer", "burner", "buffer" }
local SIDES = { left = true, right = true, front = true, back = true, top = true, bottom = true }

local function short(name) return (name:gsub("^.-:", "")) end
network.short = short

local function asList(v)
  if type(v) == "string" then return { v } end
  return v or {}
end

-- Roles of the configuration: { role, name } or { role, worker = ID } (worker),
-- in display order
function network.roles()
  local t, seen = {}, {}
  local function add(role, name)
    if type(name) == "string" and not seen[role .. name] then
      seen[role .. name] = true
      t[#t + 1] = { role = role, name = name }
    end
  end
  for _, n in ipairs(asList(config.storage)) do add("storage", n) end
  add("buffer", config.buffer)
  for _, o in ipairs(stations.outputs()) do add("output", o.name) end
  add("trash", config.trash)
  for _, n in ipairs(asList(config.fluidStorage)) do add("fluids", n) end
  local machines = {}
  for m in pairs(config.stations or {}) do machines[#machines + 1] = m end
  table.sort(machines)
  for _, m in ipairs(machines) do
    for _, s in ipairs(stations.list(m)) do
      if s.worker then t[#t + 1] = { role = m, worker = s.worker } end
      for _, key in ipairs(KEYS) do add(key == "name" and m or (m .. " " .. key), s[key]) end
    end
  end
  return t
end

-- IDs of the network's turtles: { [ID] = network name }
local function turtles()
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not SIDES[n] and peripheral.hasType(n, "turtle") then
      local ok, id = pcall(peripheral.call, n, "getID")
      if ok and id then t[id] = n end
    end
  end
  return t
end

-- Network block that could have a role. Without config.storage, every inventory is
-- storage; without config.fluidStorage, every fluid tank is
local function candidate(n)
  if peripheral.hasType(n, "turtle") then return true end
  if peripheral.hasType(n, "inventory") then return config.storage ~= nil end
  if peripheral.hasType(n, "create:fluid_tank") then return config.fluidStorage ~= nil end
  return peripheral.hasType(n, "fluid_storage")
end

-- state = { rows = roles with present, new = names of the blocks without a role,
--           missing = number of missing blocks, missingSet = { [name] = true } }
function network.check()
  local ids = turtles()
  local rows, used, missingSet, missing = network.roles(), {}, {}, 0
  for _, r in ipairs(rows) do
    if r.worker then
      r.present = ids[r.worker] ~= nil
      if ids[r.worker] then used[ids[r.worker]] = true end
    else
      r.present = peripheral.isPresent(r.name)
      used[r.name] = true
    end
    if not r.present then
      missing = missing + 1
      missingSet[r.name or ("worker " .. r.worker)] = true
    end
  end
  local new = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not SIDES[n] and not used[n] and candidate(n) then new[#new + 1] = n end
  end
  table.sort(new)
  network.state = { rows = rows, new = new, missing = missing, missingSet = missingSet }
  return network.state
end

-- Replaces the names of `map` (old -> new) everywhere in table t
local function rename(t, map, seen)
  seen = seen or {}
  if seen[t] then return end
  seen[t] = true
  for k, v in pairs(t) do
    if type(v) == "string" and map[v] then
      t[k] = map[v]
    elseif type(v) == "table" then
      rename(v, map, seen)
    end
  end
end

-- Possible replacements: { [old] = new }, at most one per block type
function network.repairs()
  local state = network.check()
  local byKind = {}
  for name in pairs(state.missingSet) do
    local kind = not SIDES[name] and name:match("^(.-)_%d+$")
    if kind then
      byKind[kind] = byKind[kind] or { missing = {}, new = {} }
      table.insert(byKind[kind].missing, name)
    end
  end
  for _, n in ipairs(state.new) do
    for kind, b in pairs(byKind) do
      if peripheral.hasType(n, kind) then table.insert(b.new, n) end
    end
  end
  local map = {}
  for _, b in pairs(byKind) do
    if #b.missing == 1 and #b.new == 1 then map[b.missing[1]] = b.new[1] end
  end
  return map
end

-- Applies network.repairs(); returns the replacements made ("chest_1 -> chest_3")
function network.repair()
  local map = network.repairs()
  local done = {}
  for old, new in pairs(map) do done[#done + 1] = short(old) .. " -> " .. short(new) end
  if not done[1] then return done end
  table.sort(done)
  config.edit(function(data) rename(data, map) end)
  rename(config, map)
  network.check()
  return done
end

return network
