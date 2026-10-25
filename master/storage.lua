-- storage.lua : accès au stockage et transferts d'items vers la turtle
-- Les items passent par le coffre tampon : stockage -> tampon -> turtle.

local config = require("config")

local storage = {
  stock = {},                            -- nom d'item -> quantité totale
  GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }, -- cases turtle de la grille 3x3
  IS_GRID = {},
}
for _, s in ipairs(storage.GRID) do storage.IS_GRID[s] = true end

local SIDE_DIR = { top = "up", bottom = "down", front = "front" }
local buffer, suck, drop
local stackCache = {}

-- Vérifie le matériel ; lève une erreur lisible si le montage est incomplet
function storage.init()
  if not turtle or not turtle.craft then
    error("Ce programme doit tourner sur une Crafty Turtle.", 0)
  end
  local dir = config.bufferDir or SIDE_DIR[config.buffer]
  if not dir then
    error("Precise bufferDir dans config.lua pour le tampon " .. config.buffer, 0)
  end
  buffer = peripheral.wrap(config.buffer)
  if not buffer or not buffer.list then
    error("Coffre tampon introuvable : " .. config.buffer, 0)
  end
  suck = ({ up = turtle.suckUp, down = turtle.suckDown, front = turtle.suck })[dir]
  drop = ({ up = turtle.dropUp, down = turtle.dropDown, front = turtle.drop })[dir]
end

-- nil si le tampon est prêt, sinon le message d'erreur. Tant qu'il manque (bloc reposé,
-- modem réactivé), chaque appel réessaie : un tampon absent ne fait pas planter
function storage.ready()
  if buffer and peripheral.isPresent(config.buffer) then return end
  buffer = nil
  local ok, err = pcall(storage.init)
  if not ok then
    buffer = nil
    return tostring(err)
  end
end

-- Inventaires de stockage présents : config.storage, sinon tous sauf les tampons, les
-- sorties et la poubelle
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

-- Réservoirs de stockage des fluides ; nil dans config = tous les fluid tanks Create.
-- Un tank absent du réseau (modem coupé) est ignoré.
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

-- Relève le stock total de tous les inventaires, fluides compris (en mB)
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

-- Envoie `mB` du fluide `name` des réservoirs vers `target` ; renvoie la quantité envoyée
function storage.exportFluid(name, mB, target)
  local sent = 0
  for _, n in ipairs(storage.tankNames()) do
    sent = sent + peripheral.wrap(n).pushFluid(target, mB - sent, name)
    if sent >= mB then break end
  end
  return sent
end

-- Ramène dans les réservoirs tous les fluides de `source` ; false s'il en reste
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

-- Taille de pile maximale d'un item (mise en cache)
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

-- Ramène dans le stockage le contenu de la case `slot` de l'inventaire `source` ;
-- renvoie le nombre d'items déplacés
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

-- Ramène tout le contenu de l'inventaire `source` dans le stockage ; false s'il en reste
function storage.empty(source)
  local inv = peripheral.wrap(source)
  for slot in pairs(inv.list()) do storage.import(source, slot) end
  return next(inv.list()) == nil
end

-- true si l'inventaire `inventory` (un seul, pas tout le stockage) contient l'item `name`
function storage.has(inventory, name)
  for _, it in pairs(peripheral.wrap(inventory).list()) do
    if it.name == name then return true end
  end
  return false
end

-- Vide l'inventaire de la turtle dans le stockage ; false si ça bloque
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

-- Amène n items `name` dans la case tslot de la turtle ; renvoie le nombre obtenu
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

-- Déplace tout le contenu de `source` vers `target` (sortie -> poubelle) ;
-- renvoie le nombre d'items déplacés et le nombre restés dans `source`
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

-- Envoie n items `name` du stockage vers l'inventaire `target` (dans sa case
-- `toSlot` si elle est donnée) ; renvoie le nombre envoyé.
-- pushItems déplace au plus une pile par appel : une case de drawer (des
-- centaines d'items) est donc vidée en plusieurs appels.
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
