-- crafter.lua : crafte des recettes en confiant les lots aux postes des machines
--
-- 1. plan()   : arbre complet des crafts à faire, calculé sur un stock virtuel
--               (les sous-crafts réservent leurs ingrédients, les surplus servent aux suivants).
--               Un item qui a plusieurs recettes : on essaie d'abord celles dont les
--               ingrédients sont en stock, puis les autres. Rien n'est lancé tant que
--               tout l'arbre n'est pas possible ; sinon, liste complète des manques.
-- 2. tick()   : lance chaque tâche dès que ses sous-tâches sont finies, un lot par
--               poste libre ; les postes d'une même machine se partagent le travail
-- 3. worker() : file de commandes, plusieurs en cours à la fois (postes partagés).
--               Une commande réserve le stock qu'elle va prendre ; les suivantes
--               sont planifiées sur le stock libre (reserved)

local config = require("config")
local storage = require("storage")
local recipes = require("recipes")
local stations = require("stations")
local burner = require("machines.burner")

local crafter = {}
local name = recipes.displayName

-- Pilotes disponibles, par valeur du champ `machine` des recettes
local machines = {
  turtle = require("machines.turtle"),
  pressing = require("machines.depot"),
  mixing = require("machines.basin"),
  compacting = require("machines.basin"),
  filling = require("machines.depot"),    -- depot sous un spout (poste : spout = ...)
  emptying = require("machines.drain"),
  deploying = require("machines.depot"),  -- depot sous un deployer (poste : deployer = ...)
}
-- Postes où les items défilent : coffre d'entrée -> machine -> coffre de sortie
for _, m in ipairs({ "washing", "smoking", "blasting", "haunting", "crushing", "milling", "sawing" }) do
  machines[m] = require("machines.flow")
end
crafter.machines = machines

-- Stock virtuel en couches : un essai écrit dans sa couche, qu'on garde (commit)
-- s'il réussit ou qu'on jette s'il échoue
local function layer(parent) return setmetatable({}, { __index = parent }) end
local function commit(child, parent)
  for k, v in pairs(child) do parent[k] = v end
end

-- Problème d'un plan impossible : missing = { [item] = quantité }, err = autre cause
local function addMissing(into, from)
  for item, n in pairs(from or {}) do into[item] = (into[item] or 0) + n end
end

local plan

-- Recettes de `item`, celles dont les ingrédients sont en stock d'abord
local function candidates(item, n, stock)
  local direct, other = {}, {}
  for _, r in ipairs(recipes.findAll(item, stock)) do
    local ok = true
    for input, want in pairs(recipes.expected(r, math.ceil(n / r.output.count))) do
      if stock[input] < want then ok = false; break end
    end
    table.insert(ok and direct or other, r)
  end
  for _, r in ipairs(other) do direct[#direct + 1] = r end
  return direct
end

-- Produit `n` items (ou mB) `item` avec la première recette possible ;
-- renvoie la tâche, ou nil + problème (celui de la recette préférée)
local function provide(item, n, stock, tasks, visiting)
  if visiting[item] then return nil, { err = "Recette circulaire : " .. name(item) } end
  local list = candidates(item, n, stock)
  if not list[1] then return nil, { missing = { [item] = n } } end
  local best
  for _, r in ipairs(list) do
    local task, problem = plan(r, math.ceil(n / r.output.count), stock, tasks, visiting)
    if task then return task end
    -- Un manque d'ingrédients dit plus qu'une recette circulaire ou un poste absent
    if not best or (problem.missing and not best.missing) then best = problem end
  end
  return nil, best
end

-- Réserve le combustible d'une recette chauffée : 1 par lot, sous-crafté s'il manque
local function planFuel(recipe, times, task, stock, tasks, visiting)
  local station = task.pool[1]
  local need = math.ceil(times / task.machine.batchSize(station, recipe))
  local fuels = burner.fuels(station, recipe.heat)
  if not fuels[1] then
    return { err = ("Aucun combustible %s dans config.lua"):format(recipe.heat) }
  end
  for _, f in ipairs(fuels) do
    if stock[f] >= need then
      stock[f] = stock[f] - need
      task.fuel = f
      return
    end
  end
  local problem
  for _, f in ipairs(fuels) do
    local sub, p = provide(f, need - math.max(0, stock[f]), stock, tasks, visiting)
    if sub then
      task.deps[#task.deps + 1] = sub
      stock[f] = stock[f] - need
      task.fuel = f
      return
    end
    problem = problem or p
  end
  return problem
end

-- Ajoute à `tasks` la tâche de `recipe` x`times` après celles de ses sous-crafts ;
-- renvoie la tâche, ou nil + problème. Sur échec, `stock` et `tasks` ne changent pas.
function plan(recipe, times, stock, tasks, visiting)
  local output = recipe.output.name
  local machineName = recipes.machine(recipe)
  local machine = machines[machineName]
  if not machine then return nil, { err = "Machine inconnue : " .. machineName } end
  local pool = stations.pool(machineName, recipe.heat)
  if not pool[1] then
    if not recipe.heat then return nil, { err = "Aucun poste pour " .. machineName .. " dans config.lua" } end
    return nil, { err = ("Aucun poste %s %s dans config.lua pour %s"):format(machineName, recipe.heat, name(output)) }
  end

  local mine, myTasks = layer(stock), {}
  local task = { recipe = recipe, times = times, machine = machine, pool = pool, deps = {} }
  local missing, err = {}, nil
  visiting[output] = true
  -- Tous les ingrédients sont examinés, même après un manque : liste complète
  for item, want in pairs(recipes.expected(recipe, times)) do
    local short = want - math.max(0, mine[item])
    if short > 0 then
      local sub, problem = provide(item, short, mine, myTasks, visiting)
      if sub then
        task.deps[#task.deps + 1] = sub
      else
        addMissing(missing, problem.missing)
        err = err or problem.err
      end
    end
    mine[item] = mine[item] - want
  end
  if recipe.heat and not next(missing) and not err then
    local problem = planFuel(recipe, times, task, mine, myTasks, visiting)
    if problem then
      addMissing(missing, problem.missing)
      err = err or problem.err
    end
  end
  visiting[output] = nil
  if next(missing) then return nil, { missing = missing } end
  if err then return nil, { err = err } end

  mine[output] = mine[output] + recipe.output.count * times
  commit(mine, stock)
  for _, t in ipairs(myTasks) do tasks[#tasks + 1] = t end
  tasks[#tasks + 1] = task
  return task
end

-- Message d'un problème : « Manque 1 Wheat Flour, 300 mB Water » ou la cause
local function describe(problem)
  if not problem.missing then return problem.err end
  local items = {}
  for item in pairs(problem.missing) do items[#items + 1] = item end
  table.sort(items)
  local parts = {}
  for _, item in ipairs(items) do parts[#parts + 1] = recipes.amount(problem.missing[item], item) end
  return "Manque " .. table.concat(parts, ", ")
end

local function finished(task) return task.left == 0 and task.running == 0 end

local function ready(task)
  for _, dep in ipairs(task.deps) do
    if not finished(dep) then return false end
  end
  return true
end

-- « 8 Shaft » / « 500 mB Water » : ce que produisent `crafts` crafts de `recipe`
local function produced(recipe, crafts)
  return recipes.amount(crafts * recipe.output.count, recipe.output.name)
end

local function stationLabel(station)
  if station.worker then return "ouvriere " .. station.worker end
  return ((station.name or station.inlet or "?"):gsub("^.-:", ""))
end

-- Commandes en cours d'exécution, les plus anciennes d'abord. Un job :
-- { recipe, tasks, done, total, report, log, err, export, order }.
-- Les postes sont partagés entre les jobs : busy[poste] = { job, task, count }.
local jobs, busy = {}, {}

-- Ce que les jobs vont encore prendre au stockage : ingrédients et combustible des
-- lots pas encore lancés, produit final à envoyer à la sortie. Ce qu'ils vont produire
-- n'est pas compté : une nouvelle commande ne compte que sur ce qui est déjà là.
local function reserved()
  local r = {}
  local function add(item, n) r[item] = (r[item] or 0) + n end
  for _, job in ipairs(jobs) do
    if not job.err then
      for _, t in ipairs(job.tasks) do
        if t.left > 0 then
          for item, n in pairs(recipes.expected(t.recipe, t.left)) do add(item, n) end
          if t.fuel then add(t.fuel, math.ceil(t.left / t.machine.batchSize(t.pool[1], t.recipe))) end
        end
      end
      if job.export then add(job.recipe.output.name, job.export) end
    end
  end
  return r
end

-- Stock relevé par storage.scan ; `free` : moins ce que les jobs ont réservé
local function stockView(free)
  local r = free and reserved() or {}
  return setmetatable({}, { __index = function(_, item)
    return storage.count(item) - (r[item] or 0)
  end })
end

-- Prépare une commande sur le stock libre : alternatives rechoisies, arbre des crafts.
-- `output` : inventaire qui reçoit le produit final (nil = il reste dans le stockage).
-- Renvoie le job, ou nil + message. Rien n'est lancé.
local function prepare(recipe, times, report, log, output)
  recipe = recipes.refresh(recipe, stockView(true))
  local tasks = {}
  local _, problem = plan(recipe, times, stockView(true), tasks, {})
  if problem then return nil, describe(problem) end
  local job = { recipe = recipe, tasks = tasks, done = 0, total = 0,
                report = report or function() end, log = log or function() end }
  for _, t in ipairs(tasks) do
    t.left, t.running = t.times, 0
    job.total = job.total + t.times
  end
  if output and not recipe.output.fluid then
    job.export, job.output = times * recipe.output.count, output
  end
  job.report(0, job.total)
  return job
end

-- Lance les lots prêts du job sur les postes libres. Après une erreur, plus rien ne
-- démarre mais on attend les lots en cours, pour que leurs items reviennent au stockage.
local function startLots(job)
  for _, t in ipairs(job.tasks) do
    if job.err then return end
    if t.left > 0 and ready(t) then
      for _, station in ipairs(t.pool) do
        if t.left == 0 then break end
        if not busy[station] then
          local count = math.min(t.machine.batchSize(station, t.recipe), t.left)
          -- Un bloc disparu (cassé, modem coupé) fait une erreur de commande, pas un plantage
          local ok, err = pcall(t.machine.start, station, t.recipe, count)
          if not ok then err = "Poste " .. stationLabel(station) .. " : " .. tostring(err) end
          if err then job.err = err; return end
          busy[station] = { job = job, task = t, count = count }
          t.left, t.running = t.left - count, t.running + count
        end
      end
    end
  end
end

-- Suivi des postes occupés ; true si l'un d'eux travaille encore
local function pollStations()
  local working = false
  for station, lot in pairs(busy) do
    local job, t = lot.job, lot.task
    local ok, status, err = pcall(t.machine.poll, station)
    if not ok then status, err = nil, tostring(status) end
    if status == "running" then
      working = true
    else
      busy[station] = nil
      t.running = t.running - lot.count
      if status == "done" then
        job.done = job.done + lot.count
        job.report(job.done, job.total)
        -- La dernière tâche est la commande elle-même : « Termine » suffit
        if finished(t) and t ~= job.tasks[#job.tasks] then
          local label = recipes.machineLabel(t.recipe)
          job.log(("Crafte : %s%s"):format(produced(t.recipe, t.times), label and (" [" .. label .. "]") or ""))
        end
      else
        err = err or "Erreur de la machine"
        job.log(("Echec sur %s : %s"):format(stationLabel(station), err))
        job.err = job.err or err
      end
    end
  end
  return working
end

-- Un tour de l'ordonnanceur : lots sur les postes libres (les jobs les plus anciens
-- d'abord), puis suivi des postes ; true si un poste travaille encore
local function tick()
  for _, job in ipairs(jobs) do startLots(job) end
  return pollStations()
end

-- Fin d'un job : nil s'il n'est pas fini, sinon true, ou false + message.
-- Le produit final part vers la sortie du job (les intermédiaires restent stockés).
local function over(job)
  for _, lot in pairs(busy) do
    if lot.job == job then return nil end
  end
  if job.err then return false, job.err end
  if job.done < job.total then return nil end
  if not job.export then return true end
  local output = job.recipe.output.name
  if not peripheral.isPresent(job.output) then
    return false, "Sortie introuvable : " .. job.output .. " (produit reste au stockage)"
  end
  local sent = storage.export(output, job.export, job.output)
  if sent < job.export then
    return false, ("Sortie pleine : %d/%d %s envoyes"):format(sent, job.export, name(output))
  end
  return true
end

local function remove(list, value)
  for i, v in ipairs(list) do
    if v == value then return table.remove(list, i) end
  end
end

-- Crafte `times` fois la recette, sous-crafts compris, et attend la fin.
-- report(crafts finis, crafts au total), log(texte). Renvoie true, ou false + message.
function crafter.craft(recipe, times, report, log)
  storage.scan()
  local job, err = prepare(recipe, times, report, log, stations.defaultOutput())
  if not job then return false, err end
  jobs[#jobs + 1] = job
  local ok
  while true do
    local working = tick()
    ok, err = over(job)
    if ok ~= nil then break end
    if working then sleep(0.5) end
  end
  remove(jobs, job)
  return ok, err
end

-- Possible avec le stock libre (relevé par storage.scan), sous-crafts compris ?
-- Rien n'est réservé ni lancé.
function crafter.feasible(recipe, times)
  return plan(recipe, times or 1, stockView(true), {}, {}) ~= nil
end

-- File de commandes. Une commande : { recipe, times, done, total, log, ok, text }.
-- status.running = commandes en cours, status.history = commandes finies (la plus
-- récente en premier). Chaque changement envoie l'événement "crafter" pour que
-- l'interface se redessine.
local HISTORY, ORDER_LOG, JOURNAL = 20, 100, 200
local queue, running = {}, {}
crafter.status = { queue = queue, running = running, history = {} }
crafter.journal = {} -- dernières lignes, toutes commandes (aussi dans config.logFile)
local changed = false -- file ou commandes en cours modifiées : on réessaie la file

local function notify() os.queueEvent("crafter") end

local function push(list, value, max)
  list[#list + 1] = value
  if #list > max then table.remove(list, 1) end
end

-- Journal sur disque : on ajoute à la fin, et on réécrit les JOURNAL dernières
-- lignes quand le fichier en a deux fois trop
local fileLines
local function writeFile(line)
  local path = config.logFile
  if not path then return end
  if not fileLines then
    fileLines = 0
    if fs.exists(path) then
      local f = fs.open(path, "r")
      for l in f.readLine do
        push(crafter.journal, l, JOURNAL)
        fileLines = fileLines + 1
      end
      f.close()
    end
  end
  fileLines = fileLines + 1
  local f
  if fileLines > JOURNAL * 2 then
    f = fs.open(path, "w")
    for _, l in ipairs(crafter.journal) do f.writeLine(l) end
    fileLines = #crafter.journal + 1
  else
    f = fs.open(path, "a")
  end
  f.writeLine(line)
  f.close()
end

function crafter.log(order, text)
  local line = os.date("%H:%M:%S ") .. text
  writeFile(line)
  push(crafter.journal, line, JOURNAL)
  if order then push(order.log, line, ORDER_LOG) end
  notify() -- écrans des logs (screens.lua)
end

-- « 8 Shaft » : ce que demande la commande
function crafter.orderText(order)
  return produced(order.recipe, order.times)
end

-- `output` : inventaire qui reçoit le produit final ; nil = la sortie par défaut
-- (stations.defaultOutput), false = il reste dans le stockage
function crafter.order(recipe, times, output)
  if output == nil then output = stations.defaultOutput() end
  queue[#queue + 1] = { recipe = recipe, times = times, done = 0, total = 0, log = {},
                        output = output or nil }
  changed = true
  notify()
end

local CANCELLED = "Annulee"

-- Demande l'annulation d'une commande en file ou en cours ; false si elle est déjà
-- finie. C'est crafter.worker qui annule : l'interface tourne dans une autre coroutine,
-- qui peut l'interrompre au milieu d'un transfert (un appel de périphérique rend la main)
function crafter.cancel(order)
  if order.ok ~= nil or order.cancel then return false end
  order.cancel = true
  changed = true
  notify()
  return true
end

function crafter.clearHistory()
  local h = crafter.status.history
  for i = #h, 1, -1 do h[i] = nil end
  notify()
end

local function finish(order, ok, err)
  order.ok = ok
  order.text = ok and ("Termine : +" .. crafter.orderText(order)) or err
  crafter.log(order, (ok or err == CANCELLED) and order.text or ("Erreur : " .. err))
  remove(running, order)
  local history = crafter.status.history
  table.insert(history, 1, order)
  if #history > HISTORY then table.remove(history) end
  notify()
  -- Son de fin (sound.lua, branché par main.lua) ; un haut-parleur qui plante ne
  -- doit pas arrêter l'ordonnanceur
  if crafter.onFinish then pcall(crafter.onFinish, order) end
end

-- Commandes à afficher : en cours, en file, puis finies (la plus récente d'abord).
-- Liste de { order, kind, state } ; kind : "running" | "queued" | "done" | "error" | "cancelled"
function crafter.summary()
  local t = {}
  for _, o in ipairs(running) do
    t[#t + 1] = { order = o, kind = "running",
                  state = o.cancel and "annulation" or ("en cours " .. o.done .. "/" .. o.total) }
  end
  for _, o in ipairs(queue) do
    t[#t + 1] = { order = o, kind = "queued", state = o.waiting and "attente" or "en file" }
  end
  for _, o in ipairs(crafter.status.history) do
    if o.ok then t[#t + 1] = { order = o, kind = "done", state = "fini" }
    elseif o.cancel then t[#t + 1] = { order = o, kind = "cancelled", state = "annulee" }
    else t[#t + 1] = { order = o, kind = "error", state = "erreur" } end
  end
  return t
end

-- Postes, machine par machine (la turtle d'abord) : liste de { machine, label, station,
-- item, count } ; item = ce que le poste fabrique, nil s'il est libre
function crafter.stationStates()
  local names = {}
  for m in pairs(config.stations or {}) do
    if m ~= "turtle" then names[#names + 1] = m end
  end
  table.sort(names)
  table.insert(names, 1, "turtle")
  local t = {}
  for _, m in ipairs(names) do
    for _, s in ipairs(stations.pool(m)) do
      local lot = busy[s]
      t[#t + 1] = { machine = m, label = s == stations.pool("turtle")[1] and "principale" or stationLabel(s),
                    station = s, item = lot and lot.task.recipe.output.name, count = lot and lot.count }
    end
  end
  return t
end

-- Lance les commandes de la file dont l'arbre passe avec le stock libre. Une commande
-- possible avec tout le stock mais pas avec le stock libre attend la fin d'une
-- commande en cours (qui tient ses ingrédients) ; impossible même avec tout le stock,
-- elle est en erreur tout de suite.
local function startQueued()
  storage.scan()
  local i = 1
  while queue[i] do
    local order = queue[i]
    if not order.seen then
      order.seen = true
      local to = order.output and order.output ~= stations.defaultOutput() and (" -> " .. order.output) or ""
      crafter.log(order, "Commande : " .. crafter.orderText(order) .. to)
    end
    local job, err = prepare(order.recipe, order.times, function(done, total)
      order.done, order.total = done, total
      notify()
    end, function(text) crafter.log(order, text) end, order.output)
    if job then
      table.remove(queue, i)
      order.waiting = nil
      job.order = order
      jobs[#jobs + 1] = job
      running[#running + 1] = order
    elseif jobs[1] and plan(recipes.refresh(order.recipe, stockView(false)), order.times,
                            stockView(false), {}, {}) then
      if not order.waiting then crafter.log(order, "En attente : " .. err) end
      order.waiting = true
      i = i + 1
    else
      table.remove(queue, i)
      finish(order, false, err)
    end
  end
  notify()
end

-- Annulations demandées par crafter.cancel. En file : retirée tout de suite. En cours :
-- plus rien ne démarre ; les postes qui savent s'arrêter (machine.cancel) rendent
-- leurs items au stockage, les autres (ouvrières) finissent leur lot
local function applyCancels()
  local i = 1
  while queue[i] do
    if queue[i].cancel then finish(table.remove(queue, i), false, CANCELLED) else i = i + 1 end
  end
  for _, job in ipairs(jobs) do
    if job.order and job.order.cancel and not job.cancelled then
      job.cancelled = true
      job.err = CANCELLED
      crafter.log(job.order, "Annulation demandee")
      for station, lot in pairs(busy) do
        if lot.job == job and lot.task.machine.cancel then
          pcall(lot.task.machine.cancel, station)
          busy[station] = nil
          lot.task.running = lot.task.running - lot.count
        end
      end
    end
  end
end

-- Exécute les commandes de la file, plusieurs à la fois ; tourne en parallèle de
-- l'interface. sleep() perd les événements "crafter" : crafter.order lève `changed`.
function crafter.worker()
  while true do
    if changed then
      changed = false
      applyCancels()
      startQueued()
    end
    local working = tick()
    local i = 1
    while jobs[i] do
      local ok, err = over(jobs[i])
      if ok == nil then
        i = i + 1
      else
        finish(table.remove(jobs, i).order, ok, err)
        changed = true
      end
    end
    if working then
      sleep(0.5)
    elseif not jobs[1] and not changed then
      os.pullEvent("crafter")
    end
  end
end

return crafter
