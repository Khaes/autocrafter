-- main.lua : auto-crafteur pour Crafty Turtle (lancé par startup.lua)

local config = require("config")
local storage = require("storage")
local ui = require("ui")
local crafter = require("crafter")
local remote = require("remote")
local network = require("network")
local screens = require("screens")
local sound = require("sound")

fs.makeDir(config.dataDir)
remote.open() -- ordres aux turtles ouvrières (étape 7), par le modem filaire

-- Affichage sur le moniteur principal s'il y en a un, sinon sur le terminal ; les autres
-- moniteurs montrent les logs, les crafts ou le statut (screens.lua)
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
for _, name in ipairs({ "list", "recipe", "crafts", "logs", "detector", "postes" }) do
  ctx.pages[name] = require("pages." .. name)(ctx)
  app:addPage(name, ctx.pages[name])
end

-- Un bloc ajouté ou retiré du réseau : configuration revérifiée, l'écran principal
-- signale les blocs qui viennent de disparaître (étape 9)
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
  if lost[1] then crafter.log(nil, "Bloc absent : " .. table.concat(lost, ", ")) end
  if back[1] then crafter.log(nil, "Bloc reconnecte : " .. table.concat(back, ", ")) end
  storage.ready() -- tampon revenu : la turtle peut de nouveau crafter
  ctx.pages.list.onNetwork(lost)
  if app.current == "postes" then ctx.pages.postes.update() end
  os.queueEvent("network") -- écran de statut
end

app.onEvent = function(ev)
  -- Bouton « + » de JEI avec la tablette liée à ce computer : la recette va dans la commande
  if ev[1] == "jei_recipe" then ctx.pages.list.order.fromJei(ev[2], ev[4]) end
  if ev[1] == "peripheral" or ev[1] == "peripheral_detach" then networkChanged() end
end

if mon then
  term.clear()
  term.setCursorPos(1, 1)
  --print("Ajouter un nom de craft et appuyer sur entree")
end

-- Un bloc absent (tampon compris) ne bloque pas le démarrage : il est signalé
local function startApp()
  local state = network.check()
  local lost = {}
  for n in pairs(state.missingSet) do lost[#lost + 1] = n end
  table.sort(lost)
  if lost[1] then crafter.log(nil, "Bloc absent au demarrage : " .. table.concat(lost, ", ")) end
  local err = storage.ready()
  app:show("list")
  -- Erreur du tampon qui n'est pas un bloc absent (pas une Crafty Turtle...) : affichée telle quelle
  ctx.pages.list.onNetwork(lost, not state.missingSet[config.buffer] and err or nil)
end

if config.scanned then
  startApp()
else
  app:show("detector")
end
-- L'interface, les crafts et l'écoute des ouvrières tournent en même temps ; quitter
-- l'interface arrête tout
local ok, err = pcall(parallel.waitForAny, function() app:run() end, crafter.worker, remote.listen,
  screens.run)

local outs = { term.current(), mon }
for _, s in pairs(screens.screens()) do outs[#outs + 1] = s.mon end
for _, t in ipairs(outs) do
  pcall(function() -- un moniteur débranché entre-temps
    t.setBackgroundColor(colors.black)
    t.setTextColor(colors.white)
    t.clear()
    t.setCursorPos(1, 1)
  end)
end
if not ok and err ~= "Terminated" then error(err, 0) end
