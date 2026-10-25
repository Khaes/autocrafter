-- stations.lua : postes de config.stations, regroupés par machine
-- Une machine a un poste { name = ... } ou une liste de postes { { name = ... }, ... }
-- (postes `flow` : { inlet = ..., output = ... } à la place de name)

local config = require("config")
local burner = require("machines.burner")

local stations = {}

-- La turtle elle-même : un seul craft à la fois. Les ouvrières (étape 7) sont des
-- postes « turtle » de plus : config.stations.turtle = { { worker = ID, buffer = ... } }
local TURTLE = { name = "turtle" }

-- Postes d'une machine, toujours en liste ; une liste vide ({} ou [] dans le JSON)
-- veut dire aucun poste, pas un poste sans nom
local function configured(machineName)
  local s = config.stations and config.stations[machineName]
  if not s or next(s) == nil then return {} end
  if not s[1] then return { s } end
  return s
end

-- Postes qui peuvent faire les recettes de `machineName` (liste vide si aucun) ;
-- avec `heat`, seulement ceux qui chauffent assez (un poste superheated fait aussi heated)
function stations.pool(machineName, heat)
  if machineName == "turtle" then return { TURTLE, table.unpack(configured("turtle")) } end
  local t = {}
  for _, s in ipairs(configured(machineName)) do
    if burner.level(s.heat) >= burner.level(heat) then t[#t + 1] = s end
  end
  return t
end

-- Postes de config.stations pour `machineName`, toujours en liste (sans la turtle principale)
stations.list = configured

-- Sorties possibles d'une commande : config.outputs (noms réseau, ou { name, label }).
-- Liste de { name, label }, la sortie par défaut en premier
function stations.outputs()
  local t = {}
  for _, o in ipairs(config.outputs or {}) do
    local name = type(o) == "table" and o.name or o
    t[#t + 1] = { name = name, label = type(o) == "table" and o.label or (name:gsub("^.-:", "")) }
  end
  return t
end

-- Nom de la sortie par défaut (la première), nil s'il n'y en a pas
function stations.defaultOutput()
  local first = stations.outputs()[1]
  return first and first.name
end

-- Tous les postes configurés, toutes machines confondues
function stations.all()
  local t = {}
  for machineName in pairs(config.stations or {}) do
    for _, s in ipairs(configured(machineName)) do t[#t + 1] = s end
  end
  return t
end

return stations
