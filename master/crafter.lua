-- crafter.lua: crafts recipes by handing the batches to the machine stations
--
-- 1. plan()   : full tree of the crafts to make, computed on a virtual stock
--               (sub-crafts reserve their ingredients, surpluses serve the next ones).
--               An item with several recipes: first try those whose ingredients are
--               in stock, then the others. Nothing starts until the whole tree is
--               possible; otherwise, full list of what is missing.
-- 2. tick()   : starts each task as soon as its sub-tasks are done, one batch per
--               free station; the stations of one machine share the work
-- 3. worker() : order queue, several running at once (shared stations).
--               An order reserves the stock it will take; the next ones are planned
--               on the free stock (reserved)

local config = require("config")
local storage = require("storage")
local recipes = require("recipes")
local stations = require("stations")
local burner = require("machines.burner")

local crafter = {}
local name = recipes.displayName

-- Available drivers, per value of the recipes' `machine` field
local machines = {
  turtle = require("machines.turtle"),
  pressing = require("machines.depot"),
  mixing = require("machines.basin"),
  compacting = require("machines.basin"),
  filling = require("machines.depot"),    -- depot under a spout (station: spout = ...)
  emptying = require("machines.drain"),
  deploying = require("machines.depot"),  -- depot under a deployer (station: deployer = ...)
}
-- Stations where items flow: inlet chest -> machine -> output chest
for _, m in ipairs({ "washing", "smoking", "blasting", "haunting", "crushing", "milling", "sawing" }) do
  machines[m] = require("machines.flow")
end
crafter.machines = machines

-- Layered virtual stock: a try writes into its layer, which is kept (commit) if it
-- succeeds or dropped if it fails
local function layer(parent) return setmetatable({}, { __index = parent }) end
local function commit(child, parent)
  for k, v in pairs(child) do parent[k] = v end
end

-- Problem of an impossible plan: missing = { [item] = count }, err = other cause
local function addMissing(into, from)
  for item, n in pairs(from or {}) do into[item] = (into[item] or 0) + n end
end

local plan

-- Recipes of `item`, those whose ingredients are in stock first
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

-- Produces `n` items (or mB) of `item` with the first possible recipe;
-- returns the task, or nil + problem (the one of the preferred recipe)
local function provide(item, n, stock, tasks, visiting)
  if visiting[item] then return nil, { err = "Circular recipe: " .. name(item) } end
  local list = candidates(item, n, stock)
  if not list[1] then return nil, { missing = { [item] = n } } end
  local best
  for _, r in ipairs(list) do
    local task, problem = plan(r, math.ceil(n / r.output.count), stock, tasks, visiting)
    if task then return task end
    -- Missing ingredients say more than a circular recipe or a missing station
    if not best or (problem.missing and not best.missing) then best = problem end
  end
  return nil, best
end

-- Reserves the fuel of a heated recipe: 1 per batch, sub-crafted if missing
local function planFuel(recipe, times, task, stock, tasks, visiting)
  local station = task.pool[1]
  local need = math.ceil(times / task.machine.batchSize(station, recipe))
  local fuels = burner.fuels(station, recipe.heat)
  if not fuels[1] then
    return { err = ("No %s fuel in config.json"):format(recipe.heat) }
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

-- Adds to `tasks` the task of `recipe` x`times` after those of its sub-crafts;
-- returns the task, or nil + problem. On failure, `stock` and `tasks` do not change.
function plan(recipe, times, stock, tasks, visiting)
  local output = recipe.output.name
  local machineName = recipes.machine(recipe)
  local machine = machines[machineName]
  if not machine then return nil, { err = "Unknown machine: " .. machineName } end
  local pool = stations.pool(machineName, recipe.heat)
  if not pool[1] then
    if not recipe.heat then return nil, { err = "No station for " .. machineName .. " in config.json" } end
    return nil, { err = ("No %s %s station in config.json for %s"):format(recipe.heat, machineName, name(output)) }
  end

  local mine, myTasks = layer(stock), {}
  local task = { recipe = recipe, times = times, machine = machine, pool = pool, deps = {} }
  local missing, err = {}, nil
  visiting[output] = true
  -- Every ingredient is checked, even after one is missing: full list
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

-- Message of a problem: "Missing 1 Wheat Flour, 300 mB Water" or the cause
local function describe(problem)
  if not problem.missing then return problem.err end
  local items = {}
  for item in pairs(problem.missing) do items[#items + 1] = item end
  table.sort(items)
  local parts = {}
  for _, item in ipairs(items) do parts[#parts + 1] = recipes.amount(problem.missing[item], item) end
  return "Missing " .. table.concat(parts, ", ")
end

local function finished(task) return task.left == 0 and task.running == 0 end

local function ready(task)
  for _, dep in ipairs(task.deps) do
    if not finished(dep) then return false end
  end
  return true
end

-- "8 Shaft" / "500 mB Water": what `crafts` crafts of `recipe` produce
local function produced(recipe, crafts)
  return recipes.amount(crafts * recipe.output.count, recipe.output.name)
end

local function stationLabel(station)
  if station.worker then return "worker " .. station.worker end
  return ((station.name or station.inlet or "?"):gsub("^.-:", ""))
end

-- Orders being executed, oldest first. A job:
-- { recipe, tasks, done, total, report, log, err, export, order }.
-- Stations are shared between jobs: busy[station] = { job, task, count }.
local jobs, busy = {}, {}

-- What the jobs will still take from storage: ingredients and fuel of the batches not
-- started yet, final product to send to the output. What they will produce is not
-- counted: a new order only relies on what is already there.
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

-- Stock read by storage.scan; `free`: minus what the jobs have reserved
local function stockView(free)
  local r = free and reserved() or {}
  return setmetatable({}, { __index = function(_, item)
    return storage.count(item) - (r[item] or 0)
  end })
end

-- Prepares an order on the free stock: alternatives chosen again, craft tree.
-- `output`: inventory that receives the final product (nil = it stays in storage).
-- Returns the job, or nil + message. Nothing is started.
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

-- Starts the job's ready batches on the free stations. After an error nothing else
-- starts, but the running batches are awaited so that their items go back to storage.
local function startLots(job)
  for _, t in ipairs(job.tasks) do
    if job.err then return end
    if t.left > 0 and ready(t) then
      for _, station in ipairs(t.pool) do
        if t.left == 0 then break end
        if not busy[station] then
          local count = math.min(t.machine.batchSize(station, t.recipe), t.left)
          -- A missing block (broken, modem off) is an order error, not a crash
          local ok, err = pcall(t.machine.start, station, t.recipe, count)
          if not ok then err = "Station " .. stationLabel(station) .. ": " .. tostring(err) end
          if err then job.err = err; return end
          busy[station] = { job = job, task = t, count = count }
          t.left, t.running = t.left - count, t.running + count
        end
      end
    end
  end
end

-- Follows the busy stations; true if one of them is still working
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
        -- The last task is the order itself: "Done" is enough
        if finished(t) and t ~= job.tasks[#job.tasks] then
          local label = recipes.machineLabel(t.recipe)
          job.log(("Crafted: %s%s"):format(produced(t.recipe, t.times), label and (" [" .. label .. "]") or ""))
        end
      else
        err = err or "Machine error"
        job.log(("Failed on %s: %s"):format(stationLabel(station), err))
        job.err = job.err or err
      end
    end
  end
  return working
end

-- One scheduler round: batches on the free stations (oldest jobs first), then
-- follow-up of the stations; true if a station is still working
local function tick()
  for _, job in ipairs(jobs) do startLots(job) end
  return pollStations()
end

-- End of a job: nil if it is not over, else true, or false + message.
-- The final product goes to the job's output (intermediates stay in storage).
local function over(job)
  for _, lot in pairs(busy) do
    if lot.job == job then return nil end
  end
  if job.err then return false, job.err end
  if job.done < job.total then return nil end
  if not job.export then return true end
  local output = job.recipe.output.name
  if not peripheral.isPresent(job.output) then
    return false, "Output not found: " .. job.output .. " (product left in storage)"
  end
  local sent = storage.export(output, job.export, job.output)
  if sent < job.export then
    return false, ("Output full: %d/%d %s sent"):format(sent, job.export, name(output))
  end
  return true
end

local function remove(list, value)
  for i, v in ipairs(list) do
    if v == value then return table.remove(list, i) end
  end
end

-- Crafts the recipe `times` times, sub-crafts included, and waits for the end.
-- report(crafts done, total crafts), log(text). Returns true, or false + message.
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

-- Possible with the free stock (read by storage.scan), sub-crafts included?
-- Nothing is reserved or started.
function crafter.feasible(recipe, times)
  return plan(recipe, times or 1, stockView(true), {}, {}) ~= nil
end

-- Order queue. An order: { recipe, times, done, total, log, ok, text }.
-- status.running = running orders, status.history = finished orders (most recent
-- first). Each change sends the "crafter" event so that the UI redraws.
local HISTORY, ORDER_LOG, JOURNAL = 20, 100, 200
local queue, running = {}, {}
crafter.status = { queue = queue, running = running, history = {} }
crafter.journal = {} -- last lines, all orders (also in config.logFile)
local changed = false -- queue or running orders changed: try the queue again

local function notify() os.queueEvent("crafter") end

local function push(list, value, max)
  list[#list + 1] = value
  if #list > max then table.remove(list, 1) end
end

-- Log on disk: lines are appended, and the last JOURNAL lines are written back when
-- the file has twice too many
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
  notify() -- log screens (screens.lua)
end

-- "8 Shaft": what the order asks for
function crafter.orderText(order)
  return produced(order.recipe, order.times)
end

-- `output`: inventory that receives the final product; nil = the default output
-- (stations.defaultOutput), false = it stays in storage
function crafter.order(recipe, times, output)
  if output == nil then output = stations.defaultOutput() end
  queue[#queue + 1] = { recipe = recipe, times = times, done = 0, total = 0, log = {},
                        output = output or nil }
  changed = true
  notify()
end

local CANCELLED = "Cancelled"

-- Asks to cancel a queued or running order; false if it is already finished.
-- crafter.worker does the cancelling: the UI runs in another coroutine, which could
-- interrupt it in the middle of a transfer (a peripheral call yields)
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
  order.text = ok and ("Done: +" .. crafter.orderText(order)) or err
  crafter.log(order, (ok or err == CANCELLED) and order.text or ("Error: " .. err))
  remove(running, order)
  local history = crafter.status.history
  table.insert(history, 1, order)
  if #history > HISTORY then table.remove(history) end
  notify()
  -- End sound (sound.lua, hooked up by main.lua); a failing speaker must not stop
  -- the scheduler
  if crafter.onFinish then pcall(crafter.onFinish, order) end
end

-- Orders to display: running, queued, then finished (most recent first).
-- List of { order, kind, state }; kind: "running" | "queued" | "done" | "error" | "cancelled"
function crafter.summary()
  local t = {}
  for _, o in ipairs(running) do
    t[#t + 1] = { order = o, kind = "running",
                  state = o.cancel and "cancelling" or ("running " .. o.done .. "/" .. o.total) }
  end
  for _, o in ipairs(queue) do
    t[#t + 1] = { order = o, kind = "queued", state = o.waiting and "waiting" or "queued" }
  end
  for _, o in ipairs(crafter.status.history) do
    if o.ok then t[#t + 1] = { order = o, kind = "done", state = "done" }
    elseif o.cancel then t[#t + 1] = { order = o, kind = "cancelled", state = "cancelled" }
    else t[#t + 1] = { order = o, kind = "error", state = "error" } end
  end
  return t
end

-- Stations, machine by machine (the turtle first): list of { machine, label, station,
-- item, count }; item = what the station is making, nil if it is free
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
      t[#t + 1] = { machine = m, label = s == stations.pool("turtle")[1] and "main" or stationLabel(s),
                    station = s, item = lot and lot.task.recipe.output.name, count = lot and lot.count }
    end
  end
  return t
end

-- Starts the queued orders whose tree fits the free stock. An order that is possible
-- with the whole stock but not with the free stock waits for a running order to end
-- (it holds its ingredients); impossible even with the whole stock, it fails right away.
local function startQueued()
  storage.scan()
  local i = 1
  while queue[i] do
    local order = queue[i]
    if not order.seen then
      order.seen = true
      local to = order.output and order.output ~= stations.defaultOutput() and (" -> " .. order.output) or ""
      crafter.log(order, "Order: " .. crafter.orderText(order) .. to)
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
      if not order.waiting then crafter.log(order, "Waiting: " .. err) end
      order.waiting = true
      i = i + 1
    else
      table.remove(queue, i)
      finish(order, false, err)
    end
  end
  notify()
end

-- Cancellations asked by crafter.cancel. Queued: removed right away. Running: nothing
-- else starts; the stations that can stop (machine.cancel) give their items back to
-- storage, the others (workers) finish their batch
local function applyCancels()
  local i = 1
  while queue[i] do
    if queue[i].cancel then finish(table.remove(queue, i), false, CANCELLED) else i = i + 1 end
  end
  for _, job in ipairs(jobs) do
    if job.order and job.order.cancel and not job.cancelled then
      job.cancelled = true
      job.err = CANCELLED
      crafter.log(job.order, "Cancel requested")
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

-- Runs the queued orders, several at once; runs alongside the UI.
-- sleep() drops "crafter" events: crafter.order sets `changed`.
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
