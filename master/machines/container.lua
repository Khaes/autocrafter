-- machines/container.lua: Create stations that keep input and output in their own
-- inventory (depot, basin). The computer puts the ingredients into the input slots,
-- Create does the work, then the computer collects the output slots.
--
-- Usage: require("machines.container"){ input = { 1, 1 }, output = { 2, 9 } }
--   maxBatch: max crafts per batch (item drain: 1)
-- A station (config.stations): { name = "create:depot_0", timeout = 30 }
--   spout   : tank that receives the recipe's fluids (else the block itself,
--             e.g. the basin); fluidCapacity: max mB per batch (1000 by default)
--   timeout : seconds without a new result before giving up (30 by default)
--   type    : instead of name, e.g. "create:basin" = the only free basin on the network
--   heat, burner, fuel: station heated by a blaze burner (see machines/burner.lua)
--   deployer: deployer above the depot; it receives the held ingredient (recipe.held),
--             1 slot, one stack max. It must be in "use" mode (right click).

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

  -- Moves the slots in `range` back to storage; false if a slot could not be emptied
  local function empty(station, range)
    for slot, it in pairs(peripheral.wrap(station.name).list()) do
      if inRange(slot, range) and storage.import(station.name, slot) < it.count then
        return false
      end
    end
    return true
  end

  -- Blocks of the station that hold fluids (spout, basin, item drain)
  local function fluidHolders(station)
    local t = {}
    if station.spout then t[#t + 1] = station.spout end
    if peripheral.hasType(station.name, "fluid_storage") then t[#t + 1] = station.name end
    return t
  end

  -- Moves the station's fluids back to the tanks; false if some are left
  local function emptyFluids(station)
    local ok = true
    for _, n in ipairs(fluidHolders(station)) do
      if not storage.importFluids(n) then ok = false end
    end
    return ok
  end

  -- Every slot: the depot keeps the last result in its input slot.
  -- Fluid result: amount in the block's tanks.
  local function outputCount(station, item, fluid)
    local n = 0
    local p = peripheral.wrap(station.name)
    for _, it in pairs(fluid and p.tanks() or p.list()) do
      if it.name == item then n = n + (fluid and it.amount or it.count) end
    end
    return n
  end

  -- Takes back what the station's deployer holds; false if the storage is full
  local function clearHand(station)
    if not station.deployer then return true end
    local held = peripheral.wrap(station.deployer).list()[1]
    if not held then return true end
    return storage.import(station.deployer, 1) >= held.count
  end

  -- Puts back into storage what was sent for a batch that does not start
  local function abort(station)
    empty(station, layout.input)
    emptyFluids(station)
    clearHand(station)
    burner.clear(station)
  end

  -- The modem renumbers a block that was broken and placed again (basin_0 -> basin_1).
  -- If the configured name is gone, take the only block of the same type that no
  -- station uses. Returns an error message if none is found.
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
          return ("Several free %s: set name in config.json"):format(kind)
        end
        found = n
      end
    end
    if not found then return "Station not found: " .. (station.name or kind) end
    station.name = found
  end

  -- One stack per ingredient in the input slots, and the fluids (input as well as
  -- output) must fit in the station's tank
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
        return "No deployer for " .. station.name .. " (deployer in config.json)"
      end
      if not peripheral.isPresent(station.deployer) then
        return "Deployer not found: " .. station.deployer
      end
    end
    -- Leftovers of a previous craft or of a manual try: put them away first
    if not empty(station, ALL) or not emptyFluids(station) or not clearHand(station) then
      return "Station busy: " .. station.name
    end
    -- Fuel before the ingredients: nothing to take back if there is none
    if recipe.heat then
      local fuelErr = burner.feed(station, recipe.heat)
      if fuelErr then return fuelErr end
    elseif not burner.clear(station) then
      return "Storage full"
    end
    for item, perCraft in pairs(recipes.needs(recipe)) do
      local want = perCraft * count
      local target = item == recipe.held and station.deployer or station.name
      if storage.export(item, want, target) < want then
        abort(station)
        return ("Cannot send %d %s to %s"):format(want, name(item), target)
      end
    end
    local tank = station.spout or station.name
    for fluid, perCraft in pairs(recipes.fluids(recipe)) do
      local want = perCraft * count
      local sent = storage.exportFluid(fluid, want, tank)
      if sent < want then
        abort(station)
        return ("Cannot send %d mB %s to %s (%d sent)"):format(want, name(fluid), tank, sent)
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
    -- The burner took the fuel: give it another one until the batch is done
    if job.heat and n < job.count and burner.feed(station, job.heat) then
      job.noFuel = true
    end
    if n < job.count then
      if n > job.seen then
        job.seen, job.since = n, os.clock()
      elseif os.clock() - job.since > (station.timeout or 30) then
        station.job = nil
        burner.clear(station)
        return nil, ("Station stuck: %s (%d/%d %s)%s"):format(station.name, n, job.count,
          name(job.item), job.noFuel and " - out of fuel" or "")
      end
      return "running"
    end
    station.job = nil
    -- Result, by-products and leftovers go back to storage; the burner goes out
    if not empty(station, ALL) or not emptyFluids(station) or not burner.clear(station)
       or not clearHand(station) then
      return nil, "Storage full"
    end
    return "done"
  end

  -- Order cancelled: the batch stops, everything in the station goes back to storage
  function machine.cancel(station)
    station.job = nil
    empty(station, ALL)
    emptyFluids(station)
    clearHand(station)
    burner.clear(station)
  end

  return machine
end
