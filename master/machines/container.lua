-- machines/container.lua : postes Create qui gardent entrée et sortie dans leur
-- propre inventaire (depot, basin). Le computer dépose les ingrédients dans les
-- cases d'entrée, Create travaille, puis le computer récupère les cases de sortie.
--
-- Usage : require("machines.container"){ input = { 1, 1 }, output = { 2, 9 } }
--   maxBatch : crafts max par lot (item drain : 1)
-- Un poste (config.stations) : { name = "create:depot_0", timeout = 30 }
--   spout   : réservoir qui reçoit les fluides de la recette (sinon le bloc lui-même,
--             ex. le basin) ; fluidCapacity : mB max par lot (1000 par défaut)
--   timeout : secondes sans nouveau résultat avant d'abandonner (30 par défaut)
--   type    : à la place de name, ex. "create:basin" = le seul basin libre du réseau
--   heat, burner, fuel : poste chauffé par un blaze burner (voir machines/burner.lua)
--   deployer : deployer au-dessus du depot ; il reçoit l'ingrédient tenu (recipe.held),
--             1 case, une pile max. Il doit être en mode « utiliser » (clic droit).

local stations = require("stations")
local storage = require("storage")
local recipes = require("recipes")
local burner = require("machines.burner")

return function(layout)
  local machine = {}
  local name = recipes.displayName
  local ALL = { 1, math.huge }

  local function inRange(slot, range)
    return slot >= range[1] and slot <= range[2]
  end

  -- Ramène au stockage les cases de `range` ; false si une case n'a pas pu être vidée
  local function empty(station, range)
    for slot, it in pairs(peripheral.wrap(station.name).list()) do
      if inRange(slot, range) and storage.import(station.name, slot) < it.count then
        return false
      end
    end
    return true
  end

  -- Blocs du poste qui contiennent des fluides (spout, basin, item drain)
  local function fluidHolders(station)
    local t = {}
    if station.spout then t[#t + 1] = station.spout end
    if peripheral.hasType(station.name, "fluid_storage") then t[#t + 1] = station.name end
    return t
  end

  -- Ramène les fluides du poste aux réservoirs ; false s'il en reste
  local function emptyFluids(station)
    local ok = true
    for _, n in ipairs(fluidHolders(station)) do
      if not storage.importFluids(n) then ok = false end
    end
    return ok
  end

  -- Toutes les cases : le depot garde le dernier résultat en case d'entrée.
  -- Résultat fluide : quantité dans les réservoirs du bloc.
  local function outputCount(station, item, fluid)
    local n = 0
    local p = peripheral.wrap(station.name)
    for _, it in pairs(fluid and p.tanks() or p.list()) do
      if it.name == item then n = n + (fluid and it.amount or it.count) end
    end
    return n
  end

  -- Reprend ce que tient le deployer du poste ; false si le stockage est plein
  local function clearHand(station)
    if not station.deployer then return true end
    local held = peripheral.wrap(station.deployer).list()[1]
    if not held then return true end
    return storage.import(station.deployer, 1) >= held.count
  end

  -- Remet au stockage ce qui a été envoyé pour un lot qui ne démarre pas
  local function abort(station)
    empty(station, layout.input)
    emptyFluids(station)
    clearHand(station)
    burner.clear(station)
  end

  -- Le modem renumérote un bloc cassé puis reposé (basin_0 -> basin_1). Si le nom
  -- configuré a disparu, on prend le seul bloc du même type qu'aucun poste
  -- n'utilise. Renvoie un message d'erreur si on ne trouve pas.
  local function locate(station)
    if station.name and peripheral.isPresent(station.name) then return end
    local kind = station.type or station.name:match("^(.-)_%d+$") or station.name
    local used = {}
    for _, other in ipairs(stations.all()) do
      if other ~= station and other.name then used[other.name] = true end
    end
    local found
    for _, n in ipairs(peripheral.getNames()) do
      if not used[n] and peripheral.hasType(n, kind) then
        if found then
          return ("Plusieurs %s libres : precise name dans config.lua"):format(kind)
        end
        found = n
      end
    end
    if not found then return "Poste introuvable : " .. (station.name or kind) end
    station.name = found
  end

  -- Une pile par ingrédient dans les cases d'entrée, et les fluides (entrée comme
  -- sortie) doivent tenir dans le réservoir du poste
  function machine.batchSize(station, recipe)
    local batch = layout.maxBatch or 64
    for item, perCraft in pairs(recipes.needs(recipe)) do
      batch = math.min(batch, math.floor(storage.maxStack(item) / perCraft))
    end
    local cap = station.fluidCapacity or 1000
    for _, mB in pairs(recipes.fluids(recipe)) do
      batch = math.min(batch, math.floor(cap / mB))
    end
    if recipe.output.fluid then
      batch = math.min(batch, math.floor(cap / recipe.output.count))
    end
    return math.max(1, batch)
  end

  function machine.start(station, recipe, count)
    local err = locate(station)
    if err then return err end
    if recipe.held then
      if not station.deployer then
        return "Pas de deployer pour " .. station.name .. " (deployer dans config.lua)"
      end
      if not peripheral.isPresent(station.deployer) then
        return "Deployer introuvable : " .. station.deployer
      end
    end
    -- Restes d'un craft précédent ou d'un essai à la main : on les range d'abord
    if not empty(station, ALL) or not emptyFluids(station) or not clearHand(station) then
      return "Poste occupe : " .. station.name
    end
    -- Combustible avant les ingrédients : rien à reprendre si on n'en a pas
    if recipe.heat then
      local fuelErr = burner.feed(station, recipe.heat)
      if fuelErr then return fuelErr end
    elseif not burner.clear(station) then
      return "Stockage plein"
    end
    for item, perCraft in pairs(recipes.needs(recipe)) do
      local want = perCraft * count
      local target = item == recipe.held and station.deployer or station.name
      if storage.export(item, want, target) < want then
        abort(station)
        return ("Impossible d'envoyer %d %s vers %s"):format(want, name(item), target)
      end
    end
    local tank = station.spout or station.name
    for fluid, perCraft in pairs(recipes.fluids(recipe)) do
      local want = perCraft * count
      local sent = storage.exportFluid(fluid, want, tank)
      if sent < want then
        abort(station)
        return ("Impossible d'envoyer %d mB %s vers %s (%d envoyes)"):format(want, name(fluid), tank, sent)
      end
    end
    station.job = {
      item = recipe.output.name,
      fluid = recipe.output.fluid,
      count = recipe.output.count * count,
      seen = 0,
      since = os.clock(),
      heat = recipe.heat,
    }
  end

  function machine.poll(station)
    local job = station.job
    local n = outputCount(station, job.item, job.fluid)
    -- Le burner a pris le combustible : on en remet un tant que le lot n'est pas fini
    if job.heat and n < job.count and burner.feed(station, job.heat) then
      job.noFuel = true
    end
    if n < job.count then
      if n > job.seen then
        job.seen, job.since = n, os.clock()
      elseif os.clock() - job.since > (station.timeout or 30) then
        station.job = nil
        burner.clear(station)
        return nil, ("Poste bloque : %s (%d/%d %s)%s"):format(station.name, n, job.count,
          name(job.item), job.noFuel and " - plus de combustible" or "")
      end
      return "running"
    end
    station.job = nil
    -- Résultat, sous-produits et restes retournent au stockage ; le burner s'éteint
    if not empty(station, ALL) or not emptyFluids(station) or not burner.clear(station)
       or not clearHand(station) then
      return nil, "Stockage plein"
    end
    return "done"
  end

  -- Commande annulée : le lot s'arrête, tout ce qui est dans le poste revient au stockage
  function machine.cancel(station)
    station.job = nil
    empty(station, ALL)
    emptyFluids(station)
    clearHand(station)
    burner.clear(station)
  end

  return machine
end
