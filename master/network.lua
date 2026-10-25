-- network.lua : blocs du réseau nommés dans la configuration (étape 9)
--
-- check()  : chaque bloc de la configuration (stockage, tampon, sorties, poubelle,
--            réservoirs, blocs des postes, ouvrières), présent ou non, et les blocs du
--            réseau qu'aucun rôle n'utilise. Résultat gardé dans network.state.
-- repair() : le modem renumérote un bloc cassé puis reposé (chest_1 -> chest_3). Quand
--            un seul bloc d'un type manque et qu'un seul nouveau bloc de ce type est
--            apparu, il le remplace dans config.json et dans la configuration en mémoire.

local config = require("config")
local stations = require("stations")

local network = {}

-- Champs d'un poste qui sont des noms réseau, dans l'ordre d'affichage
local KEYS = { "name", "inlet", "output", "spout", "deployer", "burner", "buffer" }
local SIDES = { left = true, right = true, front = true, back = true, top = true, bottom = true }

local function short(name) return (name:gsub("^.-:", "")) end
network.short = short

local function asList(v)
  if type(v) == "string" then return { v } end
  return v or {}
end

-- Rôles de la configuration : { role, name } ou { role, worker = ID } (ouvrière),
-- dans l'ordre d'affichage
function network.roles()
  local t, seen = {}, {}
  local function add(role, name)
    if type(name) == "string" and not seen[role .. name] then
      seen[role .. name] = true
      t[#t + 1] = { role = role, name = name }
    end
  end
  for _, n in ipairs(asList(config.storage)) do add("stockage", n) end
  add("tampon", config.buffer)
  for _, o in ipairs(stations.outputs()) do add("sortie", o.name) end
  add("poubelle", config.trash)
  for _, n in ipairs(asList(config.fluidStorage)) do add("fluides", n) end
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

-- IDs des turtles du réseau : { [ID] = nom réseau }
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

-- Bloc du réseau qui pourrait avoir un rôle. Sans config.storage, tous les inventaires
-- sont du stockage ; sans config.fluidStorage, tous les fluid tanks le sont
local function candidate(n)
  if peripheral.hasType(n, "turtle") then return true end
  if peripheral.hasType(n, "inventory") then return config.storage ~= nil end
  if peripheral.hasType(n, "create:fluid_tank") then return config.fluidStorage ~= nil end
  return peripheral.hasType(n, "fluid_storage")
end

-- state = { rows = rôles avec present, new = noms des blocs sans rôle,
--           missing = nombre de blocs absents, missingSet = { [nom] = true } }
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
      missingSet[r.name or ("ouvriere " .. r.worker)] = true
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

-- Remplace les noms de `map` (ancien -> nouveau) partout dans la table t
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

-- Remplacements possibles : { [ancien] = nouveau }, un par type de bloc au plus
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

-- Applique network.repairs() ; renvoie les remplacements faits (« chest_1 -> chest_3 »)
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
