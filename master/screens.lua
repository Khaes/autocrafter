-- screens.lua: monitors besides the main screen, read only
--
--   logs   : log of every order, live
--   crafts : running orders, queued, then finished
--   status : sound, orders, missing blocks, and what each station is doing
--
-- A monitor not chosen yet shows its choices: touching one assigns it, and the choice
-- is remembered in config.json (screens key: { [monitor name] = "logs" | "crafts" |
-- "status" | "none" }). Touching the title line gives the choice again. Elsewhere,
-- the top half goes back one page, the bottom half goes forward.
-- Monitors of the same type placed next to each other merge: keep one block between them.
-- The main screen: config.monitor, else the largest free monitor (remembered).

local ui = require("ui")
local config = require("config")
local crafter = require("crafter")
local network = require("network")
local recipes = require("recipes")
local sound = require("sound")
local journal = require("journal")

local screens = {}

local KINDS = { "logs", "crafts", "status", "none" }
local LABELS = { logs = "Logs", crafts = "Crafts", status = "Status", none = "None" }
local TITLES = { logs = "LOGS", crafts = "CRAFTS", status = "STATUS" }
local TITLE_BG = { logs = colors.cyan, crafts = colors.yellow, status = colors.lightBlue }
local CRAFT_COLORS = { running = colors.yellow, queued = colors.lightGray, done = colors.lime,
                       error = colors.red, cancelled = colors.orange }

local mainName -- monitor of the main screen, never used here
local list = {} -- [name] = screen: { name, mon, win, w, h, offset, follow, choosing }

local function assigned() return config.screens or {} end

local function monitors()
  local t = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") then t[#t + 1] = n end
  end
  table.sort(t)
  return t
end

-- Monitor of the main screen: config.monitor if present, else the largest of those
-- that are not secondary screens. Returns the monitor and its name, or nil
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
  -- Remembered, so that a monitor added later does not take its place. Not before the
  -- detection: config.json does not exist yet
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

---------------------------------------------------------------- Content
local function title(page, s, text, bg)
  page:add(ui.Label{ x = 1, y = 1, w = s.w, text = text, align = "center", fg = colors.black, bg = bg })
end

-- List that scrolls with s.offset; s.follow: stuck to the end (live log)
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
  body(page, s, journal.lines(crafter.journal, s.w), "Nothing yet")
end

local function craftsView(page, s)
  title(page, s, TITLES.crafts, TITLE_BG.crafts)
  local items = {}
  for _, e in ipairs(crafter.summary()) do
    local o, fg = e.order, CRAFT_COLORS[e.kind]
    items[#items + 1] = { text = recipes.displayName(o.recipe.output.name), fg = fg, rightFg = fg,
                          right = o.times * o.recipe.output.count .. " " .. e.state }
  end
  body(page, s, items, "No craft", colors.gray)
end

local function statusView(page, s)
  title(page, s, TITLES.status, TITLE_BG.status)
  local items = {}
  local function add(text, right, fg, rightFg)
    items[#items + 1] = { text = text, right = right, fg = fg, rightFg = rightFg or fg }
  end
  -- Header lines on the full width: the secondary screens are narrow
  local speaker = sound.speaker()
  add(not speaker and "Sound: no speaker" or sound.enabled and "Sound: on" or "Sound: off",
      nil, speaker and sound.enabled and colors.lime or colors.lightGray)
  local st = crafter.status
  add("Active " .. #st.running .. ", queued " .. #st.queue, nil,
      st.running[1] and colors.yellow or colors.lightGray)
  local missing = network.state and network.state.missing or 0
  add(missing > 0 and ("Missing blocks: " .. missing) or "Network: ok", nil,
      missing > 0 and colors.red or colors.lime)
  add("", nil)
  local missingSet = network.state and network.state.missingSet or {}
  for _, p in ipairs(crafter.stationStates()) do
    local block = p.station.name or p.station.inlet
    local label = p.machine == "turtle" and ("turtle " .. p.label) or (p.machine .. " " .. p.label)
    if block and block ~= "turtle" and missingSet[block] then
      add(label, "missing", colors.white, colors.red)
    elseif p.item then
      add(label, recipes.displayName(p.item) .. " x" .. p.count, colors.white, colors.yellow)
    else
      add(label, "free", colors.white, colors.lightGray)
    end
  end
  body(page, s, items, "", colors.gray)
end

local VIEWS = { logs = logsView, crafts = craftsView, status = statusView }

---------------------------------------------------------------- Screens
local Screen = {}
Screen.__index = Screen

-- Redraws the screen; a monitor unplugged in the meantime does not crash anything
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
      -- No config.json before the end of the detection: nothing to remember yet
      title(page, self, "AUTO-CRAFTER", colors.cyan)
      page:add(ui.Label{ x = 1, y = 3, w = self.w, text = "Detecting...", align = "center" })
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

-- Plugged monitors, except the main screen; new screens created, unplugged ones removed
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

-- `main`: name of the main screen's monitor (nil = terminal)
function screens.init(main)
  mainName = main
  list = {}
  refresh()
end

screens.screens = function() return list end

-- Coroutine started with the UI (main.lua)
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
