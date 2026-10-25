-- ui.lua : mini framework d'interface (terminal ou moniteur)
--
-- Widgets : Label, Button, TextInput, List, Grid, CraftGrid, regroupés dans une Page
-- (`hidden = true` pour en masquer un).
-- App gère l'affichage, les pages, les clics/touches et le rafraîchissement.

local ui = {}

-- Écrit `text` en (x, y) sur une largeur w, tronqué et aligné
local function draw(t, x, y, w, text, fg, bg, align)
  text = tostring(text or "")
  if #text > w then text = text:sub(1, w) end
  local pad = w - #text
  local left = align == "center" and math.floor(pad / 2) or align == "right" and pad or 0
  t.setCursorPos(x, y)
  t.setTextColor(fg)
  t.setBackgroundColor(bg)
  t.write((" "):rep(left) .. text .. (" "):rep(pad - left))
end

-- Base commune des widgets
local Widget = {}
Widget.__index = Widget

function Widget:set(k, v) self[k] = v end

function Widget:contains(x, y)
  return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h
end

local function class(defaults)
  local c = setmetatable({}, { __index = Widget })
  c.__index = c
  local function new(opts)
    local o = setmetatable({}, c)
    for k, v in pairs(defaults) do o[k] = v end
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.init then o:init() end
    return o
  end
  return c, new
end

---------------------------------------------------------------- Label
local Label
Label, ui.Label = class{ x = 1, y = 1, h = 1, text = "", fg = colors.white, bg = colors.black }

function Label:init() self.w = self.w or #self.text end

function Label:draw(t)
  draw(t, self.x, self.y, self.w, self.text, self.fg, self.bg, self.align)
end

---------------------------------------------------------------- Button
local Button
Button, ui.Button = class{ x = 1, y = 1, h = 1, text = "", fg = colors.white, bg = colors.blue,
  back = colors.black } -- back : fond autour d'un bouton de 3 lignes

function Button:init() self.w = self.w or #self.text + 2 end

-- Caractères de dessin de CC (case = 2 x 3 pixels) : le tiers bas s'obtient en inversant
-- les couleurs du caractère « deux tiers haut »
local THIRD_BOTTOM, THIRD_TOP = "\143", "\131"

function Button:draw(t)
  local bg = self.pressed and colors.lightGray or self.bg
  local fg = self.pressed and colors.black or self.fg
  if self.h == 3 then
    -- Bouton fin : un tiers de ligne au-dessus et au-dessous du texte, centré
    draw(t, self.x, self.y, self.w, THIRD_BOTTOM:rep(self.w), self.back, bg)
    draw(t, self.x, self.y + 1, self.w, self.text, fg, bg, "center")
    draw(t, self.x, self.y + 2, self.w, THIRD_TOP:rep(self.w), bg, self.back)
    return
  end
  local mid = self.y + math.floor((self.h - 1) / 2)
  for y = self.y, self.y + self.h - 1 do
    draw(t, self.x, y, self.w, y == mid and self.text or "", fg, bg, "center")
  end
end

function Button:click(app)
  if not self.onClick then return end
  self.pressed = true
  app:render()
  self.onClick(self)
  self.pressed = false
end

---------------------------------------------------------------- TextInput
local TextInput
TextInput, ui.TextInput = class{
  x = 1, y = 1, w = 10, h = 1, value = "", placeholder = "",
  fg = colors.black, bg = colors.white,
}

function TextInput:draw(t, focused)
  if self.value == "" and not focused then
    draw(t, self.x, self.y, self.w, self.placeholder, colors.gray, self.bg)
  else
    local s = self.value .. (focused and "_" or "")
    if #s > self.w then s = s:sub(-self.w) end
    draw(t, self.x, self.y, self.w, s, self.fg, self.bg)
  end
end

function TextInput:setValue(v)
  self.value = v
  if self.onChange then self.onChange(self, v) end
end

function TextInput:click(app)
  app.page.focus = self
end

function TextInput:char(c) self:setValue(self.value .. c) end

function TextInput:key(k)
  if k == keys.backspace and #self.value > 0 then
    self:setValue(self.value:sub(1, -2))
  end
end

---------------------------------------------------------------- List
-- Avec le focus : ↑ ↓ déplacent la sélection (sel), Entrée appelle onSelect.
-- onLeave(list, touche) : flèche qui sort des lignes ; onKey / onChar : autres touches.
local List
List, ui.List = class{
  x = 1, y = 1, w = 10, h = 5, offset = 0, emptyText = "",
  fg = colors.white, bg = colors.black, selFg = colors.black, selBg = colors.lightBlue,
}

function List:init() self.items = self.items or {} end

function List:maxOffset() return math.max(0, #self.items - self.h) end

function List:setItems(items)
  self.items = items
  self.offset = math.max(0, math.min(self.offset, self:maxOffset()))
  if self.sel then self.sel = math.max(1, math.min(self.sel, #items)) end
end

-- Sélectionne la ligne i et fait défiler pour qu'elle soit visible
function List:select(i)
  self.sel = i
  if i <= self.offset then self.offset = i - 1
  elseif i > self.offset + self.h then self.offset = i - self.h end
end

function List:scroll(n)
  self.offset = math.max(0, math.min(self.offset + n, self:maxOffset()))
  if self.onScroll then self.onScroll(self) end
end

-- Page courante et nombre de pages
function List:pageInfo()
  local total = math.max(1, math.ceil(#self.items / self.h))
  local cur = math.floor(self.offset / self.h) + 1
  if self.offset >= self:maxOffset() then cur = total end
  return cur, total
end

function List:draw(t, focused)
  if #self.items == 0 then
    for row = 0, self.h - 1 do
      draw(t, self.x, self.y + row, self.w, row == 0 and self.emptyText or "",
           colors.lightGray, self.bg)
    end
    return
  end
  for row = 1, self.h do
    local item = self.items[self.offset + row]
    local selected = focused and self.offset + row == self.sel
    local bg = selected and self.selBg or (row % 2 == 0 and self.altBg) or self.bg
    local y = self.y + row - 1
    if item then
      local right = item.right or ""
      local tw = self.w - #right - (#right > 0 and 1 or 0)
      draw(t, self.x, y, tw, item.text, selected and self.selFg or item.fg or self.fg, bg)
      if #right > 0 then
        draw(t, self.x + tw, y, self.w - tw, right, selected and self.selFg or item.rightFg or self.fg, bg, "right")
      end
    else
      draw(t, self.x, y, self.w, "", self.fg, self.bg)
    end
  end
end

function List:click(app, x, y)
  local item = self.items[self.offset + y - self.y + 1]
  if item and self.onSelect then self.onSelect(self, item) end
end

function List:key(k)
  local i = self.sel or 1
  local j
  if k == keys.up then j = i - 1
  elseif k == keys.down then j = i + 1
  elseif k == keys.enter then
    local item = self.items[i]
    if item and self.onSelect then self.onSelect(self, item) end
    return
  else
    if self.onKey then self.onKey(self, k) end
    return
  end
  if j >= 1 and j <= #self.items then self:select(j)
  elseif self.onLeave then self.onLeave(self, k) end
end

function List:char(c)
  if self.onChar then self.onChar(self, c) end
end

---------------------------------------------------------------- Grid
-- Tuiles sur plusieurs colonnes, défilement par ligne ; items[i] = { text, fg }
-- Le nombre de colonnes dépend de la largeur : tuiles d'au moins tileW caractères.
-- Avec le focus : flèches pour déplacer la sélection (sel), Entrée pour onSelect.
-- onLeave(grid, touche) : flèche qui sort des tuiles ; onKey / onChar : autres touches.
local Grid
Grid, ui.Grid = class{
  x = 1, y = 1, w = 20, h = 5, tileW = 12, offset = 0, emptyText = "",
  fg = colors.white, bg = colors.black, tileBg = colors.gray,
  selFg = colors.black, selBg = colors.lightBlue,
}

function Grid:init()
  self.items = self.items or {}
  self.cols = math.max(1, math.floor((self.w + 1) / (self.tileW + 1)))
  self.tileW = math.floor((self.w + 1) / self.cols) - 1
end

function Grid:rows() return math.ceil(#self.items / self.cols) end

function Grid:maxOffset() return math.max(0, self:rows() - self.h) end

function Grid:setItems(items)
  self.items = items
  self.offset = math.max(0, math.min(self.offset, self:maxOffset()))
  if self.sel then self.sel = math.max(1, math.min(self.sel, #items)) end
end

-- Sélectionne la tuile i et fait défiler pour qu'elle soit visible
function Grid:select(i)
  self.sel = i
  local row = math.ceil(i / self.cols)
  if row <= self.offset then self.offset = row - 1
  elseif row > self.offset + self.h then self.offset = row - self.h end
end

function Grid:scroll(n)
  self.offset = math.max(0, math.min(self.offset + n, self:maxOffset()))
  if self.onScroll then self.onScroll(self) end
end

function Grid:pageInfo()
  local total = math.max(1, math.ceil(self:rows() / self.h))
  local cur = math.floor(self.offset / self.h) + 1
  if self.offset >= self:maxOffset() then cur = total end
  return cur, total
end

function Grid:tileX(col) return self.x + (col - 1) * (self.tileW + 1) end

function Grid:draw(t, focused)
  for row = 1, self.h do
    local y = self.y + row - 1
    draw(t, self.x, y, self.w, "", self.fg, self.bg)
    if #self.items == 0 and row == 1 then
      draw(t, self.x, y, self.w, self.emptyText, colors.lightGray, self.bg)
    end
    -- Une ligne sur deux plus sombre pour séparer les tuiles d'une même colonne
    local bg = (row % 2 == 0 and self.altBg) or self.tileBg
    for col = 1, self.cols do
      local i = (self.offset + row - 1) * self.cols + col
      local item = self.items[i]
      if item and focused and i == self.sel then
        draw(t, self:tileX(col), y, self.tileW, item.text, self.selFg, self.selBg)
      elseif item then
        draw(t, self:tileX(col), y, self.tileW, item.text, item.fg or self.fg, bg)
      end
    end
  end
end

function Grid:click(app, x, y)
  local col = math.floor((x - self.x) / (self.tileW + 1)) + 1
  if col > self.cols or x >= self:tileX(col) + self.tileW then return end -- espace entre tuiles
  local item = self.items[(self.offset + y - self.y) * self.cols + col]
  if item and self.onSelect then self.onSelect(self, item) end
end

function Grid:key(k)
  local n, i = #self.items, self.sel or 1
  local j
  if k == keys.left then j = i - 1
  elseif k == keys.right then j = i + 1
  elseif k == keys.up then j = i - self.cols
  elseif k == keys.down then
    j = i + self.cols
    -- Dernière ligne incomplète : on va sur la dernière tuile
    if j > n and math.ceil(i / self.cols) < self:rows() then j = n end
  elseif k == keys.enter then
    local item = self.items[i]
    if item and self.onSelect then self.onSelect(self, item) end
    return
  else
    if self.onKey then self.onKey(self, k) end
    return
  end
  if j >= 1 and j <= n then self:select(j)
  elseif self.onLeave then self.onLeave(self, k) end
end

function Grid:char(c)
  if self.onChar then self.onChar(self, c) end
end

---------------------------------------------------------------- CraftGrid
-- Grille 3x3 ; cells[i] = { text, fg, bg } ou nil (case vide)
local CraftGrid
CraftGrid, ui.CraftGrid = class{ x = 1, y = 1, cellW = 4, rowGap = 0 }

function CraftGrid:init()
  self.cells = self.cells or {}
  self.w = self.cellW * 3 + 2
  self.h = 3 + self.rowGap * 2
end

function CraftGrid:setCells(cells) self.cells = cells end

function CraftGrid:cellPos(i)
  local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
  return self.x + col * (self.cellW + 1), self.y + row * (1 + self.rowGap)
end

function CraftGrid:draw(t)
  for i = 1, 9 do
    local cx, cy = self:cellPos(i)
    local c = self.cells[i]
    if c then
      draw(t, cx, cy, self.cellW, c.text, c.fg or colors.white, c.bg or colors.gray, "center")
    else
      draw(t, cx, cy, self.cellW, "", colors.white, colors.gray)
    end
  end
end

function CraftGrid:click(app, x, y)
  for i = 1, 9 do
    local cx, cy = self:cellPos(i)
    if x >= cx and x < cx + self.cellW and y == cy then
      if self.onClick then self.onClick(self, i, self.cells[i]) end
      return
    end
  end
end

---------------------------------------------------------------- Page
local Page = {}
Page.__index = Page

function ui.Page() return setmetatable({ widgets = {} }, Page) end

function Page:add(w)
  self.widgets[#self.widgets + 1] = w
  return w
end

-- Un widget avec `hidden = true` n'est ni dessiné ni cliquable
function Page:draw(t)
  for _, w in ipairs(self.widgets) do
    if not w.hidden then w:draw(t, w == self.focus) end
  end
end

function Page:widgetAt(x, y)
  for i = #self.widgets, 1, -1 do
    local w = self.widgets[i]
    if w.click and not w.hidden and w:contains(x, y) then return w end
  end
end

---------------------------------------------------------------- App
-- opts.target : terminal ou moniteur ; opts.monitor : nom du moniteur
-- opts.refreshRate : secondes entre deux appels à tick() de la page affichée
-- app.onEvent(ev) : appelé pour les autres événements (ev = { nom, ... })
local App = {}
App.__index = App

function ui.App(opts)
  local target = opts.target or term.current()
  local w, h = target.getSize()
  return setmetatable({
    target = target,
    monitor = opts.monitor,
    refreshRate = opts.refreshRate or 10,
    win = window.create(target, 1, 1, w, h, true),
    w = w, h = h,
    pages = {},
  }, App)
end

function App:addPage(name, p)
  self.pages[name] = p
end

function App:show(name)
  self.current = name
  self.page = self.pages[name].page
  if self.page.onShow then self.page.onShow() end
  self:render()
end

function App:render()
  local t = self.win
  t.setVisible(false)
  t.setBackgroundColor(colors.black)
  t.clear()
  self.page:draw(t)
  t.setVisible(true)
end

function App:stop() self.running = false end

function App:click(x, y)
  local w = self.page:widgetAt(x, y)
  if w then w:click(self, x, y) end
end

function App:run()
  self.running = true
  self:render()
  local timer = os.startTimer(self.refreshRate)
  while self.running do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" and self.monitor and ev[2] == self.monitor then
      self:click(ev[3], ev[4])
    elseif e == "mouse_click" and not self.monitor then
      self:click(ev[3], ev[4])
    elseif e == "mouse_scroll" and not self.monitor then
      local w = self.page:widgetAt(ev[3], ev[4])
      if w and w.scroll then w:scroll(ev[2]) end
    elseif e == "char" and self.page.focus then
      self.page.focus:char(ev[2])
    elseif e == "key" and self.page.focus then
      self.page.focus:key(ev[2])
    elseif e == "crafter" then
      local p = self.pages[self.current]
      if p.onCraft then p.onCraft() end
    elseif e == "timer" and ev[2] == timer then
      local p = self.pages[self.current]
      if p.tick then p.tick() end
      timer = os.startTimer(self.refreshRate)
    elseif self.onEvent then
      self.onEvent(ev)
    end
    if self.running then self:render() end
  end
end

return ui
