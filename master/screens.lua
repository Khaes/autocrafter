-- screens.lua : moniteurs en plus de l'écran principal, en lecture seule
--
--   logs   : journal de toutes les commandes, en direct
--   crafts : commandes en cours, en file, puis finies
--   status : son, commandes, blocs absents, et ce que fait chaque poste
--
-- Un moniteur pas encore choisi affiche ses choix : le toucher l'attribue, et le choix
-- est retenu dans config.json (clé screens : { [nom du moniteur] = "logs" | "crafts" |
-- "status" | "none" }). Toucher la ligne du titre redonne le choix. Ailleurs, la
-- moitié haute remonte d'une page, la moitié basse descend.
-- Les moniteurs collés du même type fusionnent : les espacer d'un bloc.
-- L'écran principal : config.monitor, sinon le plus grand moniteur libre (retenu).

local ui = require("ui")
local config = require("config")
local crafter = require("crafter")
local network = require("network")
local recipes = require("recipes")
local sound = require("sound")
local journal = require("journal")

local screens = {}

local KINDS = { "logs", "crafts", "status", "none" }
local LABELS = { logs = "Logs", crafts = "Crafts", status = "Statut", none = "Rien" }
local TITLES = { logs = "LOGS", crafts = "CRAFTS", status = "STATUT" }
local TITLE_BG = { logs = colors.cyan, crafts = colors.yellow, status = colors.lightBlue }
local CRAFT_COLORS = { running = colors.yellow, queued = colors.lightGray, done = colors.lime,
                       error = colors.red, cancelled = colors.orange }

local mainName -- moniteur de l'écran principal, jamais utilisé ici
local list = {} -- [nom] = écran : { name, mon, win, w, h, offset, follow, choosing }

local function assigned() return config.screens or {} end

local function monitors()
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") then t[#t + 1] = n end
  end
  table.sort(t)
  return t
end

-- Moniteur de l'écran principal : config.monitor s'il est là, sinon le plus grand
-- de ceux qui ne sont pas des écrans secondaires. Renvoie le moniteur et son nom, ou nil
function screens.main()
  if config.monitor and peripheral.isPresent(config.monitor) then
    return peripheral.wrap(config.monitor), config.monitor
  end
  local best, bestName, bestArea
  for _, n in ipairs(monitors()) do
    local kind = assigned()[n]
    if not kind or kind == "none" then
      local m = peripheral.wrap(n)
      local w, h = m.getSize()
      if not bestArea or w * h > bestArea then best, bestName, bestArea = m, n, w * h end
    end
  end
  -- Retenu, pour qu'un moniteur ajouté plus tard ne prenne pas sa place. Pas avant la
  -- détection : config.json n'existe pas encore
  if bestName and config.scanned and assigned()[bestName] == nil then
    config.monitor = bestName
    config.edit(function(data) data.monitor = bestName end)
  end
  return best, bestName
end

local function save(name, kind)
  config.screens = config.screens or {}
  config.screens[name] = kind
  config.edit(function(data)
    data.screens = data.screens or {}
    data.screens[name] = kind
  end)
end

---------------------------------------------------------------- Contenu
local function title(page, s, text, bg)
  page:add(ui.Label{ x = 1, y = 1, w = s.w, text = text, align = "center", fg = colors.black, bg = bg })
end

-- Liste qui défile avec s.offset ; s.follow : collée à la fin (journal en direct)
local function body(page, s, items, emptyText, altBg)
  local l = ui.List{ x = 1, y = 2, w = s.w, h = s.h - 1, altBg = altBg, emptyText = emptyText }
  l:setItems(items)
  if s.follow then s.offset = l:maxOffset() end
  s.offset = math.max(0, math.min(s.offset, l:maxOffset()))
  l.offset = s.offset
  s.list = l
  page:add(l)
end

local function chooser(page, s)
  title(page, s, network.short(s.name), colors.white)
  local y = 2
  for _, kind in ipairs(KINDS) do
    if y <= s.h then
      page:add(ui.Button{
        x = 1, y = y, w = s.w, h = 1, text = LABELS[kind],
        bg = assigned()[s.name] == kind and colors.green or colors.blue,
        onClick = function()
          save(s.name, kind)
          s.choosing, s.offset, s.follow = false, 0, kind == "logs"
        end,
      })
    end
    y = y + 2 <= s.h and y + 2 or y + 1
  end
end

local function logsView(page, s)
  title(page, s, TITLES.logs, TITLE_BG.logs)
  body(page, s, journal.lines(crafter.journal, s.w), "Rien pour l'instant")
end

local function craftsView(page, s)
  title(page, s, TITLES.crafts, TITLE_BG.crafts)
  local items = {}
  for _, e in ipairs(crafter.summary()) do
    local o, fg = e.order, CRAFT_COLORS[e.kind]
    items[#items + 1] = { text = recipes.displayName(o.recipe.output.name), fg = fg, rightFg = fg,
                          right = o.times * o.recipe.output.count .. " " .. e.state }
  end
  body(page, s, items, "Aucun craft", colors.gray)
end

local function statusView(page, s)
  title(page, s, TITLES.status, TITLE_BG.status)
  local items = {}
  local function add(text, right, fg, rightFg)
    items[#items + 1] = { text = text, right = right, fg = fg, rightFg = rightFg or fg }
  end
  -- En-tête sur toute la largeur : les écrans secondaires sont étroits
  local speaker = sound.speaker()
  add(not speaker and "Son : sans speaker" or sound.enabled and "Son : actif" or "Son : coupe",
      nil, speaker and sound.enabled and colors.lime or colors.lightGray)
  local st = crafter.status
  add("En cours " .. #st.running .. ", file " .. #st.queue, nil,
      st.running[1] and colors.yellow or colors.lightGray)
  local missing = network.state and network.state.missing or 0
  add(missing > 0 and ("Blocs absents : " .. missing) or "Reseau : ok", nil,
      missing > 0 and colors.red or colors.lime)
  add("", nil)
  local missingSet = network.state and network.state.missingSet or {}
  for _, p in ipairs(crafter.stationStates()) do
    local block = p.station.name or p.station.inlet
    local label = p.machine == "turtle" and ("turtle " .. p.label) or (p.machine .. " " .. p.label)
    if block and block ~= "turtle" and missingSet[block] then
      add(label, "absent", colors.white, colors.red)
    elseif p.item then
      add(label, recipes.displayName(p.item) .. " x" .. p.count, colors.white, colors.yellow)
    else
      add(label, "libre", colors.white, colors.lightGray)
    end
  end
  body(page, s, items, "", colors.gray)
end

local VIEWS = { logs = logsView, crafts = craftsView, status = statusView }

---------------------------------------------------------------- Écrans
local Screen = {}
Screen.__index = Screen

-- Redessine l'écran ; un moniteur débranché entre-temps ne plante pas tout
function Screen:render()
  pcall(function()
    local w, h = self.mon.getSize()
    if w ~= self.w or h ~= self.h or not self.win then
      self.w, self.h = w, h
      self.win = window.create(self.mon, 1, 1, w, h, true)
    end
    local page = ui.Page()
    local kind = assigned()[self.name]
    self.page = page
    if not config.scanned then
      -- Pas de config.json avant la fin de la détection : rien à retenir encore
      title(page, self, "AUTO-CRAFTEUR", colors.cyan)
      page:add(ui.Label{ x = 1, y = 3, w = self.w, text = "Detection en cours", align = "center" })
    elseif self.choosing or not kind then
      chooser(page, self)
    elseif VIEWS[kind] then
      VIEWS[kind](page, self)
    end
    local t = self.win
    t.setVisible(false)
    t.setBackgroundColor(colors.black)
    t.clear()
    page:draw(t)
    t.setVisible(true)
  end)
end

function Screen:touch(x, y)
  if not config.scanned then return end
  local kind = assigned()[self.name]
  if self.choosing or not kind then
    local w = self.page and self.page:widgetAt(x, y)
    if w then w:click(self, x, y) end
  elseif y == 1 or kind == "none" then
    self.choosing = true
  elseif self.list then
    local l = self.list
    self.offset = l.offset + (y < 2 + l.h / 2 and -l.h or l.h)
    self.follow = self.offset >= l:maxOffset() and kind == "logs"
  end
  self:render()
end

-- Moniteurs branchés, sauf l'écran principal ; nouveaux écrans créés, débranchés retirés
local function refresh()
  local present = {}
  for _, n in ipairs(monitors()) do
    if n ~= mainName then
      present[n] = true
      if not list[n] then
        local mon = peripheral.wrap(n)
        pcall(mon.setTextScale, config.screenScale or 0.5)
        list[n] = setmetatable({ name = n, mon = mon, offset = 0, follow = assigned()[n] == "logs" }, Screen)
      end
    end
  end
  for n in pairs(list) do
    if not present[n] then list[n] = nil end
  end
end

local function renderAll()
  for _, s in pairs(list) do s:render() end
end

-- `main` : nom du moniteur de l'écran principal (nil = terminal)
function screens.init(main)
  mainName = main
  list = {}
  refresh()
end

screens.screens = function() return list end

-- Coroutine lancée avec l'interface (main.lua)
function screens.run()
  renderAll()
  local timer = os.startTimer(config.refreshRate)
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" and list[ev[2]] then
      list[ev[2]]:touch(ev[3], ev[4])
    elseif e == "crafter" or e == "network" or e == "monitor_resize" then
      renderAll()
    elseif e == "peripheral" or e == "peripheral_detach" then
      refresh()
      renderAll()
    elseif e == "timer" and ev[2] == timer then
      renderAll()
      timer = os.startTimer(config.refreshRate)
    end
  end
end

return screens
