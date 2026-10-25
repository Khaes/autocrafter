-- remote.lua : ordres aux turtles ouvrières par rednet (réseau filaire)
--
-- send() envoie un ordre et renvoie son numéro ; la réponse de l'ouvrière est gardée
-- par listen(), qui tourne en parallèle de l'interface et des crafts (le sleep de
-- l'ordonnanceur jetterait les messages reçus pendant qu'il attend) ; take() la rend.
-- Ordre : { kind = "craft", job, cells = { cases de la grille }, count }
-- Réponse : { job, ok, err }

local remote = { PROTOCOL = "autocrafter" }

local replies = {} -- numéro d'ordre -> réponse
local counter = 0

-- Ouvre tous les modems ; false s'il n'y en a aucun
function remote.open()
  peripheral.find("modem", rednet.open)
  return rednet.isOpen()
end

function remote.isOpen() return rednet.isOpen() end

-- Numéros uniques même après un redémarrage : une réponse en retard d'avant le
-- redémarrage ne peut pas être prise pour celle d'un nouvel ordre
function remote.send(computerId, msg)
  counter = counter + 1
  msg.job = ("%d-%d"):format(os.epoch("utc"), counter)
  rednet.send(computerId, msg, remote.PROTOCOL)
  return msg.job
end

-- Réponse à l'ordre `job` venue de `computerId`, ou nil si elle n'est pas arrivée
function remote.take(job, computerId)
  local r = replies[job]
  if r and r.from == computerId then
    replies[job] = nil
    return r
  end
end

function remote.listen()
  while true do
    local from, msg = rednet.receive(remote.PROTOCOL)
    if type(msg) == "table" and msg.job then
      msg.from = from
      replies[msg.job] = msg
    end
  end
end

return remote
