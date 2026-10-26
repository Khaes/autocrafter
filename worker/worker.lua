-- worker.lua: worker turtle of the auto-crafter (step 7), started by startup.lua
--
-- Setup: Crafty Turtle, buffer chest next to the turtle (BUFFER_DIR) with an
-- activated modem, and a wired modem on the turtle, on the same network as the main
-- turtle. Declared in the main turtle's config.stations.turtle
-- ({ worker = ID of this turtle, buffer = network name of the chest }), which its
-- detection fills by querying the workers ("probe" order).
--
-- Waits for a rednet order { kind = "craft", job, cells, count }: the main turtle has
-- put `count` items of grid slot i into buffer slot i, for each slot of `cells`
-- (in order). The worker sucks them in, crafts, gives everything back to the buffer
-- (result, leftovers) and replies { job, ok, err }. It knows nothing of the storage.
--
-- Order { kind = "probe", job } (detection on the main turtle): it replies
-- { job, ok, items = contents of the buffer, or nil if there is no chest }.

local PROTOCOL = "autocrafter"
local BUFFER_DIR = "down" -- side of the buffer: "up" | "down" | "front"
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local BUFFER_SIDE = ({ up = "top", down = "bottom", front = "front" })[BUFFER_DIR]

local suck = ({ up = turtle.suckUp, down = turtle.suckDown, front = turtle.suck })[BUFFER_DIR]
local drop = ({ up = turtle.dropUp, down = turtle.dropDown, front = turtle.drop })[BUFFER_DIR]

local worker = {}

-- Gives the whole inventory back to the buffer; false if something is left (buffer full)
function worker.dropAll()
  local ok = true
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      drop()
      if turtle.getItemCount(s) > 0 then ok = false end
    end
  end
  turtle.select(1)
  return ok
end

-- Contents of the buffer (list of slots); nil if there is no inventory on that side
function worker.probe()
  if peripheral.hasType(BUFFER_SIDE, "inventory") then return peripheral.call(BUFFER_SIDE, "list") end
end

-- Crafts `count` times with the buffer slots `cells`; nil or an error message.
-- turtle.suck takes the first non-empty slot of the chest: the buffer slots
-- therefore arrive in the order of `cells`.
function worker.craft(cells, count)
  -- Leftovers (interrupted craft) would mix with the ingredients: give them back to
  -- the buffer, which the main turtle empties after the reply, and refuse this batch
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      worker.dropAll()
      return "Worker not empty: leftovers given back to the buffer"
    end
  end
  local err
  for _, cell in ipairs(cells) do
    turtle.select(GRID[cell])
    suck(count)
    if turtle.getItemCount(GRID[cell]) ~= count then
      err = ("Missing ingredients (slot %d)"):format(cell)
      break
    end
  end
  if not err then
    turtle.select(16)
    local ok, craftErr = turtle.craft(count)
    if not ok then err = "Craft refused: " .. tostring(craftErr) end
  end
  if not worker.dropAll() then err = err or "Worker buffer full" end
  return err
end

function worker.run()
  peripheral.find("modem", rednet.open)
  if not rednet.isOpen() then error("No modem: the worker must be on the wired network", 0) end
  print(("Worker %d ready (buffer: %s)"):format(os.getComputerID(), BUFFER_DIR))
  while true do
    local from, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and msg.kind == "craft" then
      local err = worker.craft(msg.cells, msg.count)
      rednet.send(from, { job = msg.job, ok = err == nil, err = err }, PROTOCOL)
      print(os.date("%H:%M:%S ") .. (err or ("Craft x" .. msg.count .. " OK")))
    elseif type(msg) == "table" and msg.kind == "probe" then
      rednet.send(from, { job = msg.job, ok = true, items = worker.probe() }, PROTOCOL)
    end
  end
end

-- require("worker") (tests): the module only; run as a program: the loop
if ... == "worker" then return worker end
worker.run()
