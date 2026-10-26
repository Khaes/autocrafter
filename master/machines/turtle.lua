-- machines/turtle.lua: "turtle" station, 3x3 craft with the crafting table
--
-- Interface shared by every machine driver:
--   batchSize(station, recipe)    -> max number of crafts per batch
--   start(station, recipe, count) -> starts a batch; nil or an error message
--   poll(station)                 -> "running" | "done", or nil + an error message
--   cancel(station)               -> optional: stops the batch, items back to storage
--
-- Two kinds of stations:
--   * the main turtle ({ name = "turtle" }): crafts right away in start();
--   * a worker ({ worker = ID, buffer = chest }, step 7): the ingredients go into
--     its buffer chest, chest slot i = grid slot i, then a rednet order (remote.lua);
--     it crafts and gives everything back to the buffer, which poll() moves back to
--     storage once it has replied. Worker program: worker/worker.lua.

local storage = require("storage")
local recipes = require("recipes")
local remote = require("remote")

local machine = {}
local GRID = storage.GRID
local TIMEOUT = 30 -- seconds without a reply from the worker (else station.timeout)

-- Each grid slot holds a single stack,
-- and the output must fit in the turtle (256 items max).
function machine.batchSize(station, recipe)
  local batch = math.floor(256 / recipe.output.count)
  for item in pairs(recipes.needs(recipe)) do
    batch = math.min(batch, storage.maxStack(item))
  end
  return math.max(1, math.min(batch, 64))
end

-- Moves the worker's buffer back to storage; false if something is left
local function giveBack(station)
  return storage.empty(station.buffer)
end

local function startWorker(station, recipe, count)
  if not remote.isOpen() then return "No modem to talk to the workers" end
  if not peripheral.isPresent(station.buffer) then return "Buffer not found: " .. station.buffer end
  if not giveBack(station) then return "Buffer of worker " .. station.worker .. " full" end
  local cells = {}
  for slot = 1, 9 do
    local item = recipe.grid[slot]
    if item then
      if storage.export(item, count, station.buffer, slot) < count then
        giveBack(station)
        return "Cannot fetch " .. recipes.displayName(item)
      end
      cells[#cells + 1] = slot
    end
  end
  station.job = remote.send(station.worker, { kind = "craft", cells = cells, count = count })
  station.since = os.clock()
end

local function pollWorker(station)
  local reply = remote.take(station.job, station.worker)
  if not reply then
    if os.clock() - station.since < (station.timeout or TIMEOUT) then return "running" end
    station.job = nil
    local err = "Worker " .. station.worker .. " does not reply"
    if not giveBack(station) then err = err .. " (buffer not empty, storage full?)" end
    return nil, err
  end
  station.job = nil
  local back = giveBack(station)
  if not reply.ok then return nil, reply.err or "Worker error" end
  if not back then return nil, "Storage full" end
  return "done"
end

-- Fills the grid and crafts `count` times. The craft is immediate:
-- the result is already back in storage when start() returns.
function machine.start(station, recipe, count)
  if station.worker then return startWorker(station, recipe, count) end
  local err = storage.ready()
  if err then return err end
  if not storage.clearTurtle() then return "Storage or buffer full" end
  for slot = 1, 9 do
    local item = recipe.grid[slot]
    if item and storage.fetch(item, count, GRID[slot]) < count then
      err = "Cannot fetch " .. recipes.displayName(item)
      break
    end
  end
  if not err then
    turtle.select(16)
    local ok, craftErr = turtle.craft(count)
    if not ok then err = "Craft refused: " .. tostring(craftErr) end
  end
  storage.clearTurtle()
  return err
end

function machine.poll(station)
  if station.worker then return pollWorker(station) end
  return "done"
end

return machine
