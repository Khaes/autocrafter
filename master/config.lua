-- config.lua: setup settings, read from DATA_DIR/config.json
--
-- Default setup:
--   * Crafty Turtle (turtle + crafting table)
--   * STORAGE chest above the turtle (or any inventories connected by wired modem)
--   * empty BUFFER chest below the turtle (used as an airlock)
--   * optional advanced monitor on a free side
--
-- config.json keys (a missing key = nil):
--   buffer       : buffer chest (below the turtle), network name
--   bufferDir    : "up" | "down" | "front"; deduced if buffer is a side
--   storage      : storage inventories; missing = all except the buffer and the output.
--                  List them as soon as there are machines on the network (otherwise
--                  depots, basins... count)
--   outputs      : outputs that receive the ordered item, chosen on the main screen for
--                  each order; the first one is the default. Missing = it stays in
--                  storage. Network names, or { name, label }:
--                  [ "minecraft:chest_0", { "name": "minecraft:chest_30", "label": "Workshop" } ]
--                  Old output key (single output): read as outputs = [ output ]
--   trash        : trash (drop into lava): "Empty" button on the main screen;
--                  missing = no button
--   stations     : Create stations, per recipe machine (network names of the blocks)
--     timeout : seconds without a new result before giving up (30 by default)
--     Block broken and placed again (basin_0 -> basin_1): found again on its own if
--     it is the only free one of its type. "type": "create:basin" also works without name.
--     Several stations for one machine: they share the batches at the same time
--       "pressing": [ { "name": "create:depot_0" }, { "name": "create:depot_1" } ]
--     turtle    : worker turtles besides this one: computer ID and network name of
--                 its buffer chest (worker.lua program on the worker)
--     filling   : depot under a spout (spout = name of the spout)
--     deploying : depot under a deployer in "use" mode (deployer = its name)
--     mixing    : basin under a mixer; heat = max level ("heated" or "superheated"),
--                 burner = deployer that feeds the blaze burner. It also does the
--                 recipes without heat.
--     compacting: basin under a press, same keys as mixing
--     washing, smoking, haunting, blasting, crushing, milling, sawing: stations where
--       items flow, inlet chest (inlet) -> machine -> output chest (output)
--       idle: inlet empty and nothing new for idle s = pass over (10 by default)
--       retries: extra passes if the result is missing (3 by default)
--   fluidStorage : fluid tanks (one fluid per tank); missing = every fluid tank
--   fuel         : blaze burner fuels, per level (the first one in stock is used)
--   logFile      : order log; missing = DATA_DIR/log.txt
--   refreshRate  : seconds between two stock readings (10 by default)
--   monitorScale : text size on the monitor, 0.5 to 5 (1 by default)
--   monitor      : monitor of the main screen; missing = the largest (then remembered)
--   screens      : other monitors, chosen by touching them (screens.lua):
--                  { "monitor_1": "logs", "monitor_2": "crafts", "monitor_3": "status" }
--   screenScale  : text size of the other monitors (0.5 by default)
--   sound        : end-of-order sound on a speaker (true by default), music note
--                  button in the title of the main screen

local DATA_DIR = "/recipecrafter"
local PATH = DATA_DIR .. "/config.json"
local config = {}
config.scanned = false
local f = fs.open(PATH, "r")
if f then
  local text = f.readAll()
  f.close()
  local err
  config, err = textutils.unserializeJSON(text)
  if type(config) ~= "table" then
    error("Invalid configuration (" .. PATH .. "): " .. tostring(err), 0)
  end
  -- After reading: unserializeJSON returns a new table
  config.scanned = true
end

config.dataDir = DATA_DIR
config.logFile = config.logFile or DATA_DIR .. "/log.txt"
config.refreshRate = config.refreshRate or 10
config.monitorScale = config.monitorScale or 1
if config.output then
  config.outputs = config.outputs or { config.output }
  config.output = nil
end

-- Edits config.json: fn(file data) changes it, then the file is written back.
-- The configuration in memory does not change (up to the caller if needed)
function config.edit(fn)
  local data = {}
  local file = fs.open(PATH, "r")
  if file then
    data = textutils.unserializeJSON(file.readAll()) or {}
    file.close()
  end
  fn(data)
  fs.makeDir(DATA_DIR)
  file = fs.open(PATH, "w")
  file.write(textutils.serializeJSON(data))
  file.close()
end

return config
