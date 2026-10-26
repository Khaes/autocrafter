-- storage.lua: access to the storage and item transfers to the turtle
-- Items go through the buffer chest: storage -> buffer -> turtle.

local config = require("config")

local storage = {
  stock = {},                            -- item name -> total count
  GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }, -- turtle slots of the 3x3 grid
  IS_GRID = {},
}
for _, s in ipairs(storage.GRID) do storage.IS_GRID[s] = true end

local SIDE_DIR = { top = "up", bottom = "down", front = "front" }
local buffer, suck, drop
local stackCache = {}

-- Checks the hardware; raises a readable error if the setup is incomplete
function storage.init()
  if not turtle or not turtle.craft then
    error("This program must run on a Crafty Turtle.", 0)
  end
  local dir = config.bufferDir or SIDE_DIR[config.buffer]
  if not dir then
    error("Set bufferDir in config.json for the buffer " .. config.buffer, 0)
  end
  buffer = peripheral.wrap(config.buffer)
  if not buffer or not buffer.list then
    error("Buffer chest not found: " .. config.buffer, 0)
  end
  suck = ({ up = turtle.suckUp, down = turtle.suckDown, front = turtle.suck })[dir]
  drop = ({ up = turtle.dropUp, down = turtle.dropDown, front = turtle.drop })[dir]
end

-- nil if the buffer is ready, else the error message. While it is missing (block
-- placed again, modem turned back on), each call tries again: a missing buffer does
-- not crash anything
function storage.ready()
  if buffer and peripheral.isPresent(config.buffer) then return end
  buffer = nil
  local ok, err = pcall(storage.init)
  if not ok then
    buffer = nil
    return tostring(err)
  end
end

-- Storage inventories that are present: config.storage, else all except the buffers,
-- the outputs and the trash
function storage.names()
  if config.storage then
    local t = {}
    for _, n in ipairs(config.storage) do
      if peripheral.isPresent(n) then t[#t + 1] = n end
    end
    return t
  end
  local skip = { [config.buffer] = true }
  for _, o in ipairs(config.outputs or {}) do skip[type(o) == "table" and o.name or o] = true end
  if config.trash then skip[config.trash] = true end
  local workers = config.stations and config.stations.turtle or {}
  for _, w in ipairs(workers[1] and workers or { workers }) do
    if w.buffer then skip[w.buffer] = true end
  end
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if not skip[n] and peripheral.hasType(n, "inventory") then
      t[#t + 1] = n
    end
  end
  return t
end

-- Fluid storage tanks; nil in the config = every Create fluid tank.
-- A tank missing from the network (modem off) is skipped.
function storage.tankNames()
  local t = {}
  if config.fluidStorage then
    for _, n in ipairs(config.fluidStorage) do
      if peripheral.isPresent(n) then t[#t + 1] = n end
    end
    return t
  end
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "create:fluid_tank") then t[#t + 1] = n end
  end
  return t
end

-- Reads the total stock of every inventory, fluids included (in mB)
function storage.scan()
  local s = {}
  for _, n in ipairs(storage.names()) do
    local inv = peripheral.wrap(n)
    if inv then
      for _, it in pairs(inv.list()) do
        s[it.name] = (s[it.name] or 0) + it.count
      end
    end
  end
  for _, n in ipairs(storage.tankNames()) do
    local tank = peripheral.wrap(n)
    if tank then
      for _, f in pairs(tank.tanks()) do
        s[f.name] = (s[f.name] or 0) + f.amount
      end
    end
  end
  storage.stock = s
  return s
end

-- Sends `mB` of fluid `name` from the tanks to `target`; returns the amount sent
function storage.exportFluid(name, mB, target)
  local sent = 0
  for _, n in ipairs(storage.tankNames()) do
    sent = sent + peripheral.wrap(n).pushFluid(target, mB - sent, name)
    if sent >= mB then break end
  end
  return sent
end

-- Moves every fluid of `source` back to the tanks; false if some are left
function storage.importFluids(source)
  local inv = peripheral.wrap(source)
  for _, f in pairs(inv.tanks()) do
    local left = f.amount
    for _, n in ipairs(storage.tankNames()) do
      left = left - inv.pushFluid(n, left, f.name)
      if left <= 0 then break end
    end
  end
  for _, f in pairs(inv.tanks()) do
    if f.amount > 0 then return false end
  end
  return true
end

function storage.count(name)
  return storage.stock[name] or 0
end

-- Max stack size of an item (cached)
function storage.maxStack(name)
  if stackCache[name] then return stackCache[name] end
  for _, n in ipairs(storage.names()) do
    local inv = peripheral.wrap(n)
    for slot, it in pairs(inv.list()) do
      if it.name == name then
        local d = inv.getItemDetail(slot)
        stackCache[name] = d and d.maxCount or 64
        return stackCache[name]
      end
    end
  end
  return 64
end

-- Moves the contents of slot `slot` of inventory `source` back to storage;
-- returns the number of items moved
function storage.import(source, slot)
  local inv = peripheral.wrap(source)
  local it = inv.list()[slot]
  if not it then return 0 end
  local moved = 0
  for _, n in ipairs(storage.names()) do
    moved = moved + inv.pushItems(n, slot)
    if moved >= it.count then break end
  end
  return moved
end

-- Moves the whole contents of inventory `source` back to storage; false if some are left
function storage.empty(source)
  local inv = peripheral.wrap(source)
  for slot in pairs(inv.list()) do storage.import(source, slot) end
  return next(inv.list()) == nil
end

-- true if inventory `inventory` (a single one, not the whole storage) holds item `name`
function storage.has(inventory, name)
  for _, it in pairs(peripheral.wrap(inventory).list()) do
    if it.name == name then return true end
  end
  return false
end

-- Empties the turtle's inventory into storage; false if it gets stuck
function storage.clearTurtle()
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      drop()
    end
  end
  turtle.select(1)
  local emptied = storage.empty(config.buffer)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then return false end
  end
  return emptied
end

-- Brings n items `name` into turtle slot tslot; returns the number obtained
function storage.fetch(name, n, tslot)
  turtle.select(tslot)
  local got = turtle.getItemCount(tslot)
  for _, sn in ipairs(storage.names()) do
    local inv = peripheral.wrap(sn)
    for slot, it in pairs(inv.list()) do
      if it.name == name then
        local moved = inv.pushItems(config.buffer, slot, n - got, 1)
        if moved > 0 then
          suck(moved)
          got = turtle.getItemCount(tslot)
        end
        if got >= n then return got end
      end
    end
  end
  return got
end

-- Moves the whole contents of `source` to `target` (output -> trash);
-- returns the number of items moved and the number left in `source`
function storage.moveAll(source, target)
  local inv = peripheral.wrap(source)
  local moved = 0
  for slot in pairs(inv.list()) do
    repeat
      local n = inv.pushItems(target, slot)
      moved = moved + n
    until n == 0
  end
  local left = 0
  for _, it in pairs(inv.list()) do left = left + it.count end
  return moved, left
end

-- Sends n items `name` from storage to inventory `target` (into its slot `toSlot`
-- if given); returns the number sent.
-- pushItems moves at most one stack per call: a drawer slot (hundreds of items) is
-- therefore emptied in several calls.
function storage.export(name, n, target, toSlot)
  local sent = 0
  for _, sn in ipairs(storage.names()) do
    local inv = peripheral.wrap(sn)
    for slot, it in pairs(inv.list()) do
      if it.name == name then
        repeat
          local moved = inv.pushItems(target, slot, n - sent, toSlot)
          sent = sent + moved
        until moved == 0 or sent >= n
        if sent >= n then return sent end
      end
    end
  end
  return sent
end

return storage
