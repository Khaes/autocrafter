-- main.lua: auto-crafter for a Crafty Turtle (started by startup.lua)

local config = require("config")
local storage = require("storage")
local ui = require("ui")
local crafter = require("crafter")
local remote = require("remote")
local network = require("network")
local screens = require("screens")
local sound = require("sound")
local recipes = require("recipes")

-- Every recipe comes from the AutoCrafter Link mod: without it there is nothing to craft
if not recipes.hasApi() then
  error("AutoCrafter Link mod missing: install autocrafterlink-1.0.0.jar (see README.md)", 0)
end

fs.makeDir(config.dataDir)
remote.open() -- orders to the worker turtles (step 7), over the wired modem

-- Display on the main monitor if there is one, else on the terminal; the other
-- monitors show the logs, the crafts or the status (screens.lua)
local mon, monName = screens.main()
local target = term.current()
if mon then
  mon.setTextScale(config.monitorScale)
  target = mon
end
screens.init(monName)
crafter.onFinish = sound.onFinish

local app = ui.App{ target = target, monitor = monName, refreshRate = config.refreshRate }
local ctx = { app = app, pages = {} }
for _, name in ipairs({ "list", "recipe", "crafts", "logs", "detector", "stations" }) do
  ctx.pages[name] = require("pages." .. name)(ctx)
  app:addPage(name, ctx.pages[name])
end

-- A block added to or removed from the network: configuration checked again, the main
-- screen reports the blocks that just disappeared (step 9)
local function networkChanged()
  if not config.scanned or app.current == "detector" then return end
  local before = network.state and network.state.missingSet or {}
  local state = network.check()
  local lost = {}
  for n in pairs(state.missingSet) do
    if not before[n] then lost[#lost + 1] = n end
  end
  table.sort(lost)
  local back = {}
  for n in pairs(before) do
    if not state.missingSet[n] then back[#back + 1] = n end
  end
  table.sort(back)
  if lost[1] then crafter.log(nil, "Block missing: " .. table.concat(lost, ", ")) end
  if back[1] then crafter.log(nil, "Block reconnected: " .. table.concat(back, ", ")) end
  storage.ready() -- buffer back: the turtle can craft again
  ctx.pages.list.onNetwork(lost)
  if app.current == "stations" then ctx.pages.stations.update() end
  os.queueEvent("network") -- status screen
end

app.onEvent = function(ev)
  -- JEI "+" button with the tablet linked to this computer: the recipe goes into the order
  if ev[1] == "jei_recipe" then ctx.pages.list.order.fromJei(ev[2], ev[4]) end
  if ev[1] == "peripheral" or ev[1] == "peripheral_detach" then networkChanged() end
end

if mon then
  term.clear()
  term.setCursorPos(1, 1)
end

-- A missing block (buffer included) does not block the start: it is reported
local function startApp()
  local state = network.check()
  local lost = {}
  for n in pairs(state.missingSet) do lost[#lost + 1] = n end
  table.sort(lost)
  if lost[1] then crafter.log(nil, "Block missing at startup: " .. table.concat(lost, ", ")) end
  local err = storage.ready()
  app:show("list")
  -- Buffer error that is not a missing block (not a Crafty Turtle...): shown as is
  ctx.pages.list.onNetwork(lost, not state.missingSet[config.buffer] and err or nil)
end

if config.scanned then
  startApp()
else
  app:show("detector")
end
-- The UI, the crafts and listening to the workers run at the same time; quitting
-- the UI stops everything
local ok, err = pcall(parallel.waitForAny, function() app:run() end, crafter.worker, remote.listen,
  screens.run)

local outs = { term.current(), mon }
for _, s in pairs(screens.screens()) do outs[#outs + 1] = s.mon end
for _, t in ipairs(outs) do
  pcall(function() -- a monitor unplugged in the meantime
    t.setBackgroundColor(colors.black)
    t.setTextColor(colors.white)
    t.clear()
    t.setCursorPos(1, 1)
  end)
end
if not ok and err ~= "Terminated" then error(err, 0) end
