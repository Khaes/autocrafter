-- worker.lua : turtle ouvrière de l'auto-crafteur (étape 7), lancée par startup.lua
--
-- Montage : Crafty Turtle, coffre tampon collé à la turtle (BUFFER_DIR) avec un
-- modem activé, et un modem filaire sur la turtle, sur le même réseau que la turtle
-- principale. Déclarée dans config.stations.turtle de la principale
-- ({ worker = ID de cette turtle, buffer = nom réseau du coffre }), que sa détection
-- remplit en interrogeant les ouvrières (ordre « probe »).
--
-- Attend un ordre rednet { kind = "craft", job, cells, count } : la turtle principale
-- a mis `count` items de la case i de la grille dans la case i du tampon, pour chaque
-- case de `cells` (dans l'ordre). L'ouvrière les aspire, crafte, rend tout au tampon
-- (résultat, restes) et répond { job, ok, err }. Elle ne connaît pas le stockage.
--
-- Ordre { kind = "probe", job } (détection de la principale) : elle répond
-- { job, ok, items = contenu du tampon, ou nil s'il n'y a pas de coffre }.

local PROTOCOL = "autocrafter"
local BUFFER_DIR = "down" -- côté du tampon : "up" | "down" | "front"
local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local BUFFER_SIDE = ({ up = "top", down = "bottom", front = "front" })[BUFFER_DIR]

local suck = ({ up = turtle.suckUp, down = turtle.suckDown, front = turtle.suck })[BUFFER_DIR]
local drop = ({ up = turtle.dropUp, down = turtle.dropDown, front = turtle.drop })[BUFFER_DIR]

local worker = {}

-- Rend tout l'inventaire au tampon ; false s'il en reste (tampon plein)
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

-- Contenu du tampon (liste des cases) ; nil s'il n'y a pas d'inventaire de ce côté
function worker.probe()
  if peripheral.hasType(BUFFER_SIDE, "inventory") then return peripheral.call(BUFFER_SIDE, "list") end
end

-- Crafte `count` fois avec les cases `cells` du tampon ; nil ou message d'erreur.
-- turtle.suck prend la première case non vide du coffre : les cases du tampon
-- arrivent donc dans l'ordre de `cells`.
function worker.craft(cells, count)
  -- Des restes (craft interrompu) se mêleraient aux ingrédients : on les rend au
  -- tampon, que la turtle principale vide après la réponse, et on refuse ce lot
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      worker.dropAll()
      return "Ouvriere pas vide : restes rendus au tampon"
    end
  end
  local err
  for _, cell in ipairs(cells) do
    turtle.select(GRID[cell])
    suck(count)
    if turtle.getItemCount(GRID[cell]) ~= count then
      err = ("Ingredients incomplets (case %d)"):format(cell)
      break
    end
  end
  if not err then
    turtle.select(16)
    local ok, craftErr = turtle.craft(count)
    if not ok then err = "Craft refuse : " .. tostring(craftErr) end
  end
  if not worker.dropAll() then err = err or "Tampon de l'ouvriere plein" end
  return err
end

function worker.run()
  peripheral.find("modem", rednet.open)
  if not rednet.isOpen() then error("Pas de modem : l'ouvriere doit etre sur le reseau filaire", 0) end
  print(("Ouvriere %d prete (tampon : %s)"):format(os.getComputerID(), BUFFER_DIR))
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

-- require("worker") (tests) : le module seul ; lancé comme programme : la boucle
if ... == "worker" then return worker end
worker.run()
