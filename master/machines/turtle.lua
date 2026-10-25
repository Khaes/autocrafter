-- machines/turtle.lua : poste « turtle », craft 3x3 avec la table de craft
--
-- Interface commune à tous les pilotes de machines :
--   batchSize(station, recipe)    -> nombre max de crafts par lot
--   start(station, recipe, count) -> lance un lot ; nil ou message d'erreur
--   poll(station)                 -> "running" | "done", ou nil + message d'erreur
--
-- Deux sortes de postes :
--   * la turtle principale ({ name = "turtle" }) : craft immédiat dans start() ;
--   * une ouvrière ({ worker = ID, buffer = coffre }, étape 7) : les ingrédients vont
--     dans son coffre tampon, case i du coffre = case i de la grille, puis un ordre
--     rednet (remote.lua) ; elle crafte et rend tout dans le tampon, que poll() ramène
--     au stockage quand elle a répondu. Programme de l'ouvrière : worker/worker.lua.

local storage = require("storage")
local recipes = require("recipes")
local remote = require("remote")

local machine = {}
local GRID = storage.GRID
local TIMEOUT = 30 -- secondes sans réponse de l'ouvrière (station.timeout sinon)

-- Chaque case de la grille tient une seule pile,
-- et la sortie doit tenir dans la turtle (256 items max).
function machine.batchSize(station, recipe)
  local batch = math.floor(256 / recipe.output.count)
  for item in pairs(recipes.needs(recipe)) do
    batch = math.min(batch, storage.maxStack(item))
  end
  return math.max(1, math.min(batch, 64))
end

-- Ramène le tampon de l'ouvrière au stockage ; false s'il en reste
local function giveBack(station)
  return storage.empty(station.buffer)
end

local function startWorker(station, recipe, count)
  if not remote.isOpen() then return "Pas de modem pour parler aux ouvrieres" end
  if not peripheral.isPresent(station.buffer) then return "Tampon introuvable : " .. station.buffer end
  if not giveBack(station) then return "Tampon de l'ouvriere " .. station.worker .. " plein" end
  local cells = {}
  for slot = 1, 9 do
    local item = recipe.grid[slot]
    if item then
      if storage.export(item, count, station.buffer, slot) < count then
        giveBack(station)
        return "Impossible de recuperer " .. recipes.displayName(item)
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
    local err = "L'ouvriere " .. station.worker .. " ne repond pas"
    if not giveBack(station) then err = err .. " (tampon pas vide, stockage plein ?)" end
    return nil, err
  end
  station.job = nil
  local back = giveBack(station)
  if not reply.ok then return nil, reply.err or "Erreur de l'ouvriere" end
  if not back then return nil, "Stockage plein" end
  return "done"
end

-- Remplit la grille et crafte `count` fois. Le craft est immédiat :
-- le résultat est déjà renvoyé au stockage quand start() se termine.
function machine.start(station, recipe, count)
  if station.worker then return startWorker(station, recipe, count) end
  local err = storage.ready()
  if err then return err end
  if not storage.clearTurtle() then return "Stockage ou tampon plein" end
  for slot = 1, 9 do
    local item = recipe.grid[slot]
    if item and storage.fetch(item, count, GRID[slot]) < count then
      err = "Impossible de recuperer " .. recipes.displayName(item)
      break
    end
  end
  if not err then
    turtle.select(16)
    local ok, craftErr = turtle.craft(count)
    if not ok then err = "Craft refuse : " .. tostring(craftErr) end
  end
  storage.clearTurtle()
  return err
end

function machine.poll(station)
  if station.worker then return pollWorker(station) end
  return "done"
end

return machine
