-- pages/list.lua: main screen. Without a search, the order being prepared (the
-- recipes added from the recipe page) and the CRAFT button that starts it; with a
-- search, the items found as tiles, one page at a time (like JEI). CRAFT opens the
-- craft tracking (pages/crafts.lua). The list and the total come from the AutoCrafter
-- Link mod; only the items the workshop can make (machine with a station)
-- are shown. The output of the order is chosen under the list. "Stations":
-- pages/stations.lua.

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
    x = 9, y = 1, w = W - 18, text = "AUTO-CRAFTER",
    align = "center", fg = colors.black, bg = colors.cyan,
  })
  -- Material Checklist of a Schematicannon on a lectern: its missing items go into the order
  local order = {}
  page:add(ui.Button{
    x = W - 9, y = 1, w = 6, h = 1, text = "Book",
    onClick = function() order.fromBook() end,
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
  -- then to the storage (the product stays there)
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
    onSelect = function(_, it)
      if not it.line.recipe.stock then ctx.pages.recipe.edit(it.line) end
    end,
  })

  -- Machines that have a station (the turtle always has one)
  local machines = {}
  for m in pairs(crafter.machines) do
    if stations.pool(m)[1] then machines[m] = true end
  end

  -- Bottom bar: paging (search) or Crafts + Logs + Scan + CRAFT (order)
  local prev, pageLabel, nextBtn, craftsBtn, craftBtn, scanBtn

  function updateOrder()
    local items = {}
    for i, l in ipairs(lines) do
      local text = name(l.recipe.output.name) .. (l.recipe.stock and " (stock)" or "")
      items[i] = { text = text, right = tostring(l.qty * l.recipe.output.count), line = l }
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
  craftBtn = page:add(ui.Button{
    x = W - 7, y = y, w = 7, h = 3, text = "CRAFT", bg = colors.gray, fg = colors.black,
    onClick = function()
      if not lines[1] then return end
      local out = selectedOutput()
      -- A stock line only sends from stock to an output: kept in storage, nothing to do
      for _, l in ipairs(lines) do
        if out or not l.recipe.stock then crafter.order(l.recipe, l.qty, out and out.name or false) end
      end
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
    x = 12, y = y, w = 6, h = 3, text = "Logs",
    onClick = function() ctx.pages.logs.open(nil) end,
  })
  -- Runs the network detection again (pages/detector.lua asks: everything, or additional)
  scanBtn = page:add(ui.Button{
    x = 19, y = y, w = 5, h = 3, text = "Scan",
    onClick = function()
      local s = crafter.status
      if s.running[1] or s.queue[1] then
        notice = { text = "Scan: wait for the orders to finish" }
        return updateOrder()
      end
      app:show("detector")
    end,
  })

  -- Order being prepared, used by the recipe page (`order` is declared with the Book button)

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

  -- Material Checklist on a lectern of the network (lectern peripheral of the mod): every
  -- item is ordered in full; sent to an output, the order takes the stock first and
  -- crafts the rest (crafter.lua) with the item's first recipe that has a station (a
  -- possible one first). An item without such a recipe is sent from stock only (stock
  -- line); what the stock lacks for it goes to the log
  local function findLectern()
    return peripheral.find("lectern", function(_, p) return p.getChecklist ~= nil end)
  end

  -- What the book would add, without touching the order:
  -- { adds = { { recipe, items } }, missing = { "120 Stone" } }, or nil + message
  local function readBook()
    local lectern = findLectern()
    if not lectern then return nil, "No lectern on the network" end
    local items = lectern.getChecklist()
    if not items then return nil, "No book on the lectern" end
    storage.scan()
    local book = { adds = {}, missing = {} }
    for _, it in ipairs(items) do
      local short = it.count - storage.count(it.name)
      local chosen
      for _, r in ipairs(recipes.findAll(it.name, storage.stock)) do
        local m = recipes.machine(r)
        if crafter.machines[m] and stations.pool(m, r.heat)[1] then
          chosen = chosen or r
          if short <= 0 or crafter.feasible(r, math.ceil(short / r.output.count)) then chosen = r break end
        end
      end
      local items = it.count
      if not chosen then
        -- Not craftable: what the stock has
        items = math.min(it.count, storage.count(it.name))
        if short > 0 then book.missing[#book.missing + 1] = recipes.amount(short, it.name) end
        if items > 0 then
          chosen = { output = { name = it.name, count = 1 }, stock = true, machine = "stock" }
        end
      end
      if chosen then book.adds[#book.adds + 1] = { recipe = chosen, items = items } end
    end
    return book
  end

  -- Read twice, the book does not order twice: an existing line gets at least its amount
  local function applyBook(book)
    for _, a in ipairs(book.adds) do
      local line
      for _, l in ipairs(lines) do
        if l.recipe.output.name == a.recipe.output.name then line = l end
      end
      if not line then
        line = { recipe = a.recipe, qty = 0 }
        lines[#lines + 1] = line
      end
      line.qty = math.min(9999, math.max(line.qty, math.ceil(a.items / line.recipe.output.count)))
    end
    local added, missing = #book.adds, book.missing
    if missing[1] then crafter.log(nil, "Book: not craftable, missing " .. table.concat(missing, ", ")) end
    notice = missing[1] and { text = ("Book: %d added, %d missing (Logs)"):format(added, #missing) }
             or { text = ("Book: %d added"):format(added), ok = true }
  end

  function order.fromBook()
    local book, err = readBook()
    if book then applyBook(book) else notice = { text = err } end
    search.value = "" -- back to the order (setValue would clear the notice)
    refresh()
  end

  -- Popup when a new checklist is put on the lectern (watchBook below): Add / Ignore.
  -- Added last, it is above the page; `blocker` takes the clicks around it
  local popup, pending = {}, nil
  local bw = math.min(W - 2, 30)
  local bx, by = math.floor((W - bw) / 2) + 1, math.floor((H - 6) / 2) + 1
  local blocker = ui.Label{ x = 1, y = 1, w = W, h = H }
  blocker.draw = function() end
  blocker.click = function() end
  popup[1] = page:add(blocker)
  popup[2] = page:add(ui.Label{ x = bx, y = by, w = bw, text = "Schematicannon book",
                                align = "center", fg = colors.black, bg = colors.cyan })
  local popupLines = {}
  for i = 1, 4 do
    popupLines[i] = page:add(ui.Label{ x = bx, y = by + i, w = bw, align = "center", bg = colors.gray })
    popup[#popup + 1] = popupLines[i]
  end
  local function closePopup()
    pending = nil
    for _, w in ipairs(popup) do w.hidden = true end
  end
  popup[#popup + 1] = page:add(ui.Button{
    x = bx + 1, y = by + 3, w = math.floor(bw / 2) - 1, h = 1, text = "Add", bg = colors.green,
    onClick = function()
      local book = pending
      closePopup()
      applyBook(book)
      search.value = ""
      refresh()
    end,
  })
  popup[#popup + 1] = page:add(ui.Button{
    x = bx + math.floor(bw / 2) + 1, y = by + 3, w = bw - math.floor(bw / 2) - 2, h = 1,
    text = "Ignore", bg = colors.red, onClick = closePopup,
  })
  closePopup()

  -- "checklist" event of watchBook: the book is read and the popup shown on this page
  local function onBook()
    if app.current == "detector" then return end
    local book = readBook()
    if not book or not (book.adds[1] or book.missing[1]) then return end
    pending = book
    popupLines[1]:set("text", ("%d items to order"):format(#book.adds))
    popupLines[2]:set("text", book.missing[1] and ("%d missing, not craftable"):format(#book.missing) or "")
    for _, w in ipairs(popup) do w.hidden = false end
    if app.current ~= "list" then app:show("list") end
  end

  -- Runs beside the UI: every BOOK_POLL s, the fingerprint of the checklist on the lectern
  -- (getBookId, the pages are not read); a new one sends the "checklist" event. A book
  -- taken off then put back counts as new; the book already there at startup does not
  -- (Book button)
  local BOOK_POLL = 2
  local function bookId()
    local lectern = findLectern()
    local ok, id = pcall(function() return lectern and lectern.getBookId() end)
    return ok and id or nil
  end
  local function watchBook()
    local last = bookId()
    while true do
      sleep(BOOK_POLL)
      local id = bookId()
      if id ~= last then
        last = id
        if id then os.queueEvent("checklist") end
      end
    end
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
    onBook = onBook,
    watchBook = watchBook,
    tick = function()
      if notice and notice.expires and os.clock() >= notice.expires then
        notice = nil
        updateOrder()
      end
    end,
  }
end
