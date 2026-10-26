-- machines/flow.lua: stations where items flow through (fans, crushers, millstone,
-- saw). The computer pours the ingredients into the inlet chest, Create moves them
-- through the machine, and the results arrive in the output chest.
--
-- A station (config.stations):
--   { inlet = "minecraft:chest_3", output = "minecraft:chest_2",
--     timeout = 30, idle = 10, retries = 3 }
--   timeout: seconds without any movement (inlet or output) before giving up
--   idle   : inlet empty and nothing new for `idle` s = the pass is over
--   retries: extra passes if results are missing (random output, item that went
--            through without being processed)
-- Recipe: `chance` = probability of the result per craft (gravel -> flint: 0.25).
-- Everything that reaches the output (by-products, unprocessed items) goes to storage.

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

-- Moves the whole inventory back to storage; false if a slot could not be emptied
local function empty(inv)
  for slot, it in pairs(peripheral.wrap(inv).list()) do
    if storage.import(inv, slot) < it.count then return false end
  end
  return true
end

-- Pours into the inlet enough for `crafts` crafts; returns nil or an error
local function feed(station, recipe, crafts)
  for item, perCraft in pairs(recipes.needs(recipe)) do
    local want = perCraft * crafts
    local sent = storage.export(item, want, station.inlet)
    if sent < want then
      return ("Cannot send %d %s to %s (%d sent)"):format(
        want, name(item), station.inlet, sent)
    end
  end
end

-- Crafts to run to get `items` results on average
local function craftsFor(recipe, items)
  return math.ceil(items / recipe.output.count / recipes.chance(recipe))
end

function machine.batchSize(station, recipe)
  local batch = 64
  for item, perCraft in pairs(recipes.needs(recipe)) do
    batch = math.min(batch, math.floor(storage.maxStack(item) / perCraft))
  end
  -- The batch counts results: with chance 0.25, 16 results = 64 ingredients
  return math.max(1, math.floor(batch * recipes.chance(recipe)))
end

function machine.start(station, recipe, count)
  for _, inv in ipairs({ station.inlet, station.output }) do
    if not inv or not peripheral.isPresent(inv) then
      return "Station not found: " .. tostring(inv)
    end
  end
  -- Leftovers of a previous pass (late items, manual try)
  if not empty(station.inlet) or not empty(station.output) then
    return "Station busy: " .. station.output
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
    got = 0,         -- results already stored (previous passes)
    tries = 0,
    last = nil,      -- last seen state of the inlet and the output
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
    -- Result, by-products and extra ingredients go back to storage
    if not empty(station.output) or not empty(station.inlet) then
      return nil, "Storage full"
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
      return nil, ("Station stuck: %s (%d/%d %s)"):format(
        station.inlet, have, job.want, name(job.item))
    end
    return "running"
  end
  if quiet <= (station.idle or 10) then return "running" end

  -- Inlet empty, nothing arrives any more, results are missing: new pass
  if job.tries >= (station.retries or 3) then
    station.job = nil
    empty(station.output)
    return nil, ("Not enough %s: %d/%d after %d passes"):format(
      name(job.item), have, job.want, job.tries + 1)
  end
  job.got = have
  if not empty(station.output) then
    station.job = nil
    return nil, "Storage full"
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

-- Order cancelled: the inlet and the output go back to storage. Items already in
-- the machine reach the output later; the next batch puts them away first
function machine.cancel(station)
  station.job = nil
  empty(station.inlet)
  empty(station.output)
end

return machine
