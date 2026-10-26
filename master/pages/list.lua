-- pages/list.lua: main screen. Without a search, the order being prepared (the
-- recipes added from the recipe page) and the CRAFT button that starts it; with a
-- search, the items found as tiles, one page at a time (like JEI). CRAFT opens the
-- craft tracking (pages/crafts.lua). The list and the total come from the AutoCrafter
-- Link mod; only the items the workshop can make (machine with a station)
-- are shown. The output of the order is chosen under the list; "Empty" sends that
-- output to the trash (config.trash). "Stations": pages/stations.lua.

local config = require("config")
local ui = require("ui")
local recipes = require("recipes")
local crafter = require("crafter")
local stations = require("stations")
local storage = require("storage")
local network = require("network")
local sound = require("sound")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local name = recipes.displayName
  local lines = {} -- order being prepared: { recipe, qty }
  local notice -- message on the title line of the order: { text, ok, lost, expires }
  local NOTICE_TIME = 60 -- seconds a missing block stays displayed

  -- Page of the network stations, red when a block of the configuration is missing
  local stationsBtn = page:add(ui.Button{
    x = 1, y = 1, w = 8, h = 1, text = "Stations",
    onClick = function() app:show("stations") end,
  })
  page:add(ui.Label{
    x = 9, y = 1, w = W - 12, text = "AUTO-CRAFTER",
    align = "center", fg = colors.black, bg = colors.cyan,
  })
  local function updateStations()
    local state = network.state
    stationsBtn:set("bg", state and state.missing > 0 and colors.red or colors.blue)
  end
  -- End-of-order sound (sound.lua): green = on; turned back on, it plays the end chord
  local soundBtn, updateOrder
  soundBtn = page:add(ui.Button{
    x = W - 3, y = 1, w = 3, h = 1, text = "\14", -- music note of the CC font
    bg = sound.enabled and colors.green or colors.gray,
    onClick = function()
      sound.toggle()
      soundBtn:set("bg", sound.enabled and colors.green or colors.gray)
      if not sound.speaker() then
        notice = { text = "No speaker on the network" }
        updateOrder()
      elseif sound.enabled then
        sound.play("done")
      end
    end,
  })
  page:add(ui.Button{
    x = W, y = 1, w = 1, h = 1, text = "x", bg = colors.red,
    onClick = function() app:stop() end,
  })

  local search = page:add(ui.TextInput{
    x = 1, y = 2, w = W - 1, placeholder = "Search an item...",
  })
  page:add(ui.Button{
    x = W, y = 2, w = 1, h = 1, text = "x", bg = colors.lightGray, fg = colors.black,
    onClick = function() search:setValue("") end,
  })
  page.focus = search

  -- Search results: only the displayed page is asked from the mod
  local grid = page:add(ui.Grid{
    x = 1, y = 3, w = W, h = H - 5, altBg = colors.black,
    emptyText = "No item",
    onSelect = function(_, tile) ctx.pages.recipe.open(tile.item) end,
  })
  local perPage = grid.cols * grid.h
  local pageNo, pages = 0, 1

  -- Order being prepared (shown when the search is empty)
  local orderTitle = page:add(ui.Label{
    x = 1, y = 3, w = W, text = "", align = "center", fg = colors.black, bg = colors.lightGray,
  })

  -- Output of the order, under the list: a click goes to the next one (stations.outputs),
  -- then to the storage (the product stays there). "Empty" empties the chosen output
  local chosen -- name of the chosen output, false = storage, nil = the first one
  local function selectedOutput()
    local outs = stations.outputs()
    if chosen == false then return nil, outs end
    for _, o in ipairs(outs) do
      if o.name == chosen then return o, outs end
    end
    return outs[1], outs
  end
  local outBtn = page:add(ui.Button{
    x = 1, y = H - 3, w = W, h = 1, text = "", bg = colors.purple,
  })
  local orderList = page:add(ui.List{
    x = 1, y = 4, w = W, h = H - 6, altBg = colors.gray,
    emptyText = "Search an item to add",
    onSelect = function(_, it) ctx.pages.recipe.edit(it.line) end,
  })

  -- Machines that have a station (the turtle always has one)
  local machines = {}
  for m in pairs(crafter.machines) do
    if stations.pool(m)[1] then machines[m] = true end
  end

  -- Bottom bar: paging (search) or Crafts + Empty + Logs + Scan + CRAFT (order)
  local prev, pageLabel, nextBtn, craftsBtn, trashBtn, craftBtn, scanBtn
  local CONFIRM = 5 -- seconds to confirm "Empty" with a 2nd click
  local armed -- os.clock() of the 1st click on "Empty"

  local function disarm()
    armed = nil
    trashBtn:set("text", "Empty")
    trashBtn:set("bg", colors.blue)
  end

  function updateOrder()
    local items = {}
    for i, l in ipairs(lines) do
      items[i] = { text = name(l.recipe.output.name), right = tostring(l.qty * l.recipe.output.count), line = l }
    end
    orderList:setItems(items)
    local out, outs = selectedOutput()
    outBtn.hidden = orderTitle.hidden or not outs[2] -- a single output: nothing to choose
    outBtn:set("text", "Output: " .. (out and out.label or "storage") .. "  (change)")
    orderList.h = outBtn.hidden and H - 6 or H - 7
    if notice then
      orderTitle:set("text", notice.text)
      orderTitle:set("bg", notice.ok and colors.lime or colors.red)
    else
      orderTitle:set("text", #lines > 0 and ("Order (" .. #lines .. ")") or "Empty order")
      orderTitle:set("bg", colors.lightGray)
    end
    craftBtn:set("bg", #lines > 0 and colors.green or colors.gray)
  end

  local function refresh()
    local searching = search.value ~= ""
    grid.hidden = not searching
    prev.hidden, pageLabel.hidden, nextBtn.hidden = not searching, not searching, not searching
    orderTitle.hidden, orderList.hidden, outBtn.hidden = searching, searching, searching
    craftsBtn.hidden, craftBtn.hidden, scanBtn.hidden = searching, searching, searching
    trashBtn.hidden = searching or not (config.trash and selectedOutput())
    disarm()
    updateStations()
    if searching then
      local total, items = recipes.listItems(search.value, pageNo * perPage, perPage, machines)
      pages = math.max(1, math.ceil(total / perPage))
      local tiles = {}
      for i, it in ipairs(items) do tiles[i] = { text = it.label, item = it.name } end
      grid:setItems(tiles)
      pageLabel:set("text", (pageNo + 1) .. "/" .. pages)
    else
      updateOrder()
    end
    -- The focus does not stay on hidden or empty tiles or order
    local f = page.focus
    if f ~= search and (f.hidden or not f.items[1]) then page.focus = search end
  end

  local function goTo(n)
    pageNo = math.max(0, math.min(n, pages - 1))
    refresh()
  end

  -- 3-line buttons, text on H - 1, one column away from the edges: the monitor's frame
  -- takes the background color of the next cell and would make the button overflow
  local y = H - 2
  prev = page:add(ui.Button{
    x = 2, y = y, w = 4, h = 3, text = "<",
    onClick = function() goTo(pageNo - 1) end,
  })
  pageLabel = page:add(ui.Label{ x = 6, y = y + 1, w = 7, text = "1/1", align = "center" })
  nextBtn = page:add(ui.Button{
    x = 13, y = y, w = 5, h = 3, text = ">",
    onClick = function() goTo(pageNo + 1) end,
  })
  craftsBtn = page:add(ui.Button{
    x = 2, y = y, w = 9, h = 3, text = "Crafts",
    onClick = function() app:show("crafts") end,
  })
  -- 1st click: "Sure?" in red; 2nd click within CONFIRM s: everything goes to the lava
  trashBtn = page:add(ui.Button{
    x = 12, y = y, w = 6, h = 3, text = "Empty",
    onClick = function()
      if not (armed and os.clock() - armed < CONFIRM) then
        armed = os.clock()
        trashBtn:set("text", "Sure?")
        trashBtn:set("bg", colors.red)
        return
      end
      disarm()
      local out = selectedOutput()
      if not (out and peripheral.isPresent(out.name) and peripheral.isPresent(config.trash)) then
        notice = { text = "Output or trash not found" }
      else
        local moved, left = storage.moveAll(out.name, config.trash)
        notice = left > 0 and { text = ("Trash full: %d items left"):format(left) }
                 or { text = ("Output emptied: %d items"):format(moved), ok = true }
      end
      updateOrder()
    end,
  })
  craftBtn = page:add(ui.Button{
    x = W - 7, y = y, w = 7, h = 3, text = "CRAFT", bg = colors.gray, fg = colors.black,
    onClick = function()
      if not lines[1] then return end
      local out = selectedOutput()
      for _, l in ipairs(lines) do crafter.order(l.recipe, l.qty, out and out.name or false) end
      for i = #lines, 1, -1 do lines[i] = nil end
      notice = nil
      refresh()
      app:show("crafts")
    end,
  })

  -- Next output, then the storage, then the first one
  outBtn.onClick = function()
    local out, outs = selectedOutput()
    if not out then
      chosen = outs[1] and outs[1].name
    else
      local i = 1
      while outs[i] ~= out do i = i + 1 end
      chosen = outs[i + 1] and outs[i + 1].name or false
    end
    refresh()
  end

  search.onChange = function()
    notice = nil
    goTo(0)
  end

  -- Keyboard: down from the search goes to the tiles (search) or to the order (no
  -- search); up from the 1st line comes back; so does a letter or Backspace.
  -- Tiles: left / right at the edges change page. Order: left / right quantity +-1, Page +-10
  local typeKey = search.key -- the one of TextInput (Backspace)
  function search:key(k)
    if k == keys.down and not grid.hidden and grid.items[1] then
      grid:select(1)
      page.focus = grid
    elseif k == keys.down and not orderList.hidden and orderList.items[1] then
      orderList:select(1)
      page.focus = orderList
    else
      typeKey(self, k)
    end
  end

  local function backToSearch(w)
    w.onChar = function(_, c)
      page.focus = search
      search:char(c)
    end
    w.onKey = function(_, k)
      if k == keys.backspace then
        page.focus = search
        search:key(k)
      elseif w.onOtherKey then
        w.onOtherKey(k)
      end
    end
  end
  backToSearch(grid)
  backToSearch(orderList)

  grid.onLeave = function(_, k)
    if k == keys.up then
      page.focus = search
    elseif k == keys.left and pageNo > 0 then
      goTo(pageNo - 1)
      grid:select(#grid.items)
    elseif (k == keys.right or k == keys.down) and pageNo < pages - 1 then
      goTo(pageNo + 1)
      grid:select(1)
    end
  end

  local QTY_STEPS = { [keys.right] = 1, [keys.left] = -1, [keys.pageUp] = 10, [keys.pageDown] = -10 }
  orderList.onLeave = function(_, k)
    if k == keys.up then page.focus = search end
  end
  orderList.onOtherKey = function(k)
    local it = orderList.items[orderList.sel]
    if not (QTY_STEPS[k] and it) then return end
    it.line.qty = math.max(1, math.min(9999, it.line.qty + QTY_STEPS[k]))
    notice = nil
    updateOrder()
  end

  page:add(ui.Button{
    x = 19, y = y, w = 6, h = 3, text = "Logs",
    onClick = function() ctx.pages.logs.open(nil) end,
  })
  -- Runs the network detection again (pages/detector.lua asks: everything, or additional)
  scanBtn = page:add(ui.Button{
    x = 26, y = y, w = 5, h = 3, text = "Scan",
    onClick = function()
      local s = crafter.status
      if s.running[1] or s.queue[1] then
        notice = { text = "Scan: wait for the orders to finish" }
        return updateOrder()
      end
      app:show("detector")
    end,
  })

  -- Order being prepared, used by the recipe page
  local order = {}

  -- Adds `qty` crafts of `recipe`; clears the search to come back to the order.
  -- One line per item: if the item is already there (even with another recipe), its
  -- line keeps its recipe and gets at least as many extra items
  function order.add(recipe, qty)
    for _, l in ipairs(lines) do
      if l.recipe.output.name == recipe.output.name then
        local items = qty * recipe.output.count
        l.qty = math.min(9999, l.qty + math.ceil(items / l.recipe.output.count))
        search:setValue("")
        return
      end
    end
    lines[#lines + 1] = { recipe = recipe, qty = qty }
    search:setValue("")
  end

  function order.remove(line)
    for i, l in ipairs(lines) do
      if l == line then table.remove(lines, i) return end
    end
  end

  -- Recipe received from the JEI "+" button (tablet): 1 craft, or a stack with shift
  function order.fromJei(id, max)
    storage.scan()
    local r = recipes.get(id, storage.stock)
    local m = r and recipes.machine(r)
    if not r then
      notice = { text = "JEI: recipe not supported" }
    elseif not (crafter.machines[m] and stations.pool(m)[1]) then
      notice = { text = "JEI: no station " .. (recipes.machineLabel(r) or m) }
    else
      order.add(r, max and math.max(1, math.floor(64 / r.output.count)) or 1)
      notice = { text = "+ " .. name(r.output.name), ok = true }
    end
    if app.current == "list" then refresh() end
  end

  order.lines = lines

  page.onShow = refresh

  -- Network read again (network.check): Stations button in red, and a message if blocks
  -- of the configuration just disappeared (`lost`: their names); `text`: other message.
  -- The "Missing" message drops the blocks that came back, and is cleared when none is
  -- left or after NOTICE_TIME s (tick); the log keeps track (main.lua)
  local function absentText(set)
    local names = {}
    for n in pairs(set) do names[#names + 1] = (n:gsub("^.-:", "")) end
    table.sort(names)
    return names[1] and ("Missing: " .. table.concat(names, ", "))
  end
  local function onNetwork(lost, text)
    if notice and notice.lost then
      local missingSet = network.state and network.state.missingSet or {}
      for n in pairs(notice.lost) do
        if not missingSet[n] then notice.lost[n] = nil end
      end
      local t = absentText(notice.lost)
      if t then notice.text = t else notice = nil end
    end
    if lost and lost[1] then
      local set = notice and notice.lost or {}
      for _, n in ipairs(lost) do set[n] = true end
      notice = { text = absentText(set), lost = set, expires = os.clock() + NOTICE_TIME }
    end
    if text then notice = { text = text } end
    if app.current == "list" then refresh() else updateStations() end
  end

  return {
    page = page,
    order = order,
    onNetwork = onNetwork,
    -- "Sure?" does not stay displayed after the confirmation delay
    tick = function()
      if armed and os.clock() - armed >= CONFIRM then disarm() end
      if notice and notice.expires and os.clock() >= notice.expires then
        notice = nil
        updateOrder()
      end
    end,
  }
end
