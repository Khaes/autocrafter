-- machines/flow.lua : postes où les items défilent (ventilateurs, broyeurs, millstone,
-- scie). Le computer verse les ingrédients dans le coffre d'entrée, Create les fait
-- passer dans la machine, les résultats arrivent dans le coffre de sortie.
--
-- Un poste (config.stations) :
--   { inlet = "minecraft:chest_3", output = "minecraft:chest_2",
--     timeout = 30, idle = 10, retries = 3 }
--   timeout : secondes sans aucun mouvement (entrée ou sortie) avant d'abandonner
--   idle    : entrée vide et plus rien n'arrive depuis `idle` s = le passage est fini
--   retries : nouveaux passages si le résultat manque (sortie aléatoire, item passé
--             sans être traité)
-- Recette : `chance` = probabilité du résultat par craft (gravier -> silex : 0.25).
-- Tout ce qui arrive en sortie (sous-produits, items non traités) va au stockage.

local storage = require("storage")
local recipes = require("recipes")

local machine = {}
local name = recipes.displayName

local function contents(inv)
  local total, byName = 0, {}
  for _, it in pairs(peripheral.wrap(inv).list()) do
    total = total + it.count
    byName[it.name] = (byName[it.name] or 0) + it.count
  end
  return total, byName
end

-- Ramène tout l'inventaire au stockage ; false si une case n'a pas pu être vidée
local function empty(inv)
  for slot, it in pairs(peripheral.wrap(inv).list()) do
    if storage.import(inv, slot) < it.count then return false end
  end
  return true
end

-- Verse dans l'entrée de quoi faire `crafts` crafts ; renvoie nil ou une erreur
local function feed(station, recipe, crafts)
  for item, perCraft in pairs(recipes.needs(recipe)) do
    local want = perCraft * crafts
    local sent = storage.export(item, want, station.inlet)
    if sent < want then
      return ("Impossible d'envoyer %d %s vers %s (%d envoyes)"):format(
        want, name(item), station.inlet, sent)
    end
  end
end

-- Crafts à lancer pour obtenir `items` résultats en moyenne
local function craftsFor(recipe, items)
  return math.ceil(items / recipe.output.count / recipes.chance(recipe))
end

function machine.batchSize(station, recipe)
  local batch = 64
  for item, perCraft in pairs(recipes.needs(recipe)) do
    batch = math.min(batch, math.floor(storage.maxStack(item) / perCraft))
  end
  -- Le lot compte en résultats : avec chance 0.25, 16 résultats = 64 ingrédients
  return math.max(1, math.floor(batch * recipes.chance(recipe)))
end

function machine.start(station, recipe, count)
  for _, inv in ipairs({ station.inlet, station.output }) do
    if not inv or not peripheral.isPresent(inv) then
      return "Poste introuvable : " .. tostring(inv)
    end
  end
  -- Restes d'un passage précédent (items arrivés en retard, essai à la main)
  if not empty(station.inlet) or not empty(station.output) then
    return "Poste occupe : " .. station.output
  end
  local want = recipe.output.count * count
  local err = feed(station, recipe, craftsFor(recipe, want))
  if err then
    empty(station.inlet)
    return err
  end
  station.job = {
    recipe = recipe,
    item = recipe.output.name,
    want = want,
    got = 0,         -- résultats déjà rangés (passages précédents)
    tries = 0,
    last = nil,      -- dernier état vu de l'entrée et de la sortie
    since = os.clock(),
  }
end

function machine.poll(station)
  local job = station.job
  local inTotal = contents(station.inlet)
  local outTotal, out = contents(station.output)
  local have = job.got + (out[job.item] or 0)

  if have >= job.want then
    station.job = nil
    -- Résultat, sous-produits et ingrédients en trop retournent au stockage
    if not empty(station.output) or not empty(station.inlet) then
      return nil, "Stockage plein"
    end
    return "done"
  end

  local state = inTotal .. "/" .. outTotal
  if state ~= job.last then
    job.last, job.since = state, os.clock()
    return "running"
  end
  local quiet = os.clock() - job.since

  if inTotal > 0 then
    if quiet > (station.timeout or 30) then
      station.job = nil
      return nil, ("Poste bloque : %s (%d/%d %s)"):format(
        station.inlet, have, job.want, name(job.item))
    end
    return "running"
  end
  if quiet <= (station.idle or 10) then return "running" end

  -- Entrée vide, plus rien n'arrive, il manque des résultats : nouveau passage
  if job.tries >= (station.retries or 3) then
    station.job = nil
    empty(station.output)
    return nil, ("Pas assez de %s : %d/%d apres %d passages"):format(
      name(job.item), have, job.want, job.tries + 1)
  end
  job.got = have
  if not empty(station.output) then
    station.job = nil
    return nil, "Stockage plein"
  end
  job.tries = job.tries + 1
  local err = feed(station, job.recipe, craftsFor(job.recipe, job.want - have))
  if err then
    station.job = nil
    empty(station.inlet)
    return nil, err
  end
  job.last, job.since = nil, os.clock()
  return "running"
end

-- Commande annulée : l'entrée et la sortie reviennent au stockage. Les items déjà
-- dans la machine arrivent plus tard en sortie ; le lot suivant les range d'abord
function machine.cancel(station)
  station.job = nil
  empty(station.inlet)
  empty(station.output)
end

return machine
