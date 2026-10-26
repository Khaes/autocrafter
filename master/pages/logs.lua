-- pages/logs.lua: detailed log of one order, or of all of them (crafter.journal)

local ui = require("ui")
local crafter = require("crafter")
local journal = require("journal")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local order -- nil = every order
  local back = "list" -- page the logs were opened from

  local title = page:add(ui.Label{
    x = 1, y = 1, w = W, text = "LOGS", align = "center", fg = colors.black, bg = colors.cyan,
  })

  local pageLabel
  local function updatePageLabel(l)
    local cur, total = l:pageInfo()
    pageLabel:set("text", cur .. "/" .. total)
  end

  local list = page:add(ui.List{
    x = 1, y = 2, w = W, h = H - 4, emptyText = "Nothing yet",
    onScroll = updatePageLabel,
  })

  -- 3-line buttons, text on H - 1, one column away from the edges: the monitor's frame
  -- takes the background color of the next cell and would make the button overflow
  local y = H - 2
  page:add(ui.Button{
    x = 2, y = y, w = 8, h = 3, text = "< Back",
    onClick = function() app:show(back) end,
  })
  page:add(ui.Button{
    x = 11, y = y, w = 4, h = 3, text = "<",
    onClick = function() list:scroll(-list.h) end,
  })
  pageLabel = page:add(ui.Label{ x = 15, y = y + 1, w = 5, text = "1/1", align = "center" })
  page:add(ui.Button{
    x = 20, y = y, w = 4, h = 3, text = ">",
    onClick = function() list:scroll(list.h) end,
  })
  page:add(ui.Button{
    x = 25, y = y, w = 6, h = 3, text = "All",
    onClick = function() ctx.pages.logs.open(nil) end,
  })

  -- "Cancel" a queued or running order: 1st click "Sure?", 2nd click within
  -- CONFIRM s
  local CONFIRM = 5
  local armed -- os.clock() of the 1st click
  local cancelBtn
  local function disarm()
    armed = nil
    cancelBtn:set("text", "Cancel")
  end
  cancelBtn = page:add(ui.Button{
    x = 32, y = y, w = 7, h = 3, text = "Cancel", bg = colors.red, hidden = true,
    onClick = function()
      if not (armed and os.clock() - armed < CONFIRM) then
        armed = os.clock()
        cancelBtn:set("text", "Sure?")
        return
      end
      disarm()
      crafter.cancel(order)
      cancelBtn.hidden = true
    end,
  })

  -- Reloads the lines; stays at the bottom if it was there (live follow)
  local function update()
    cancelBtn.hidden = not (order and order.ok == nil and not order.cancel)
    if armed and os.clock() - armed >= CONFIRM then disarm() end
    local atEnd = list.offset >= list:maxOffset()
    list:setItems(journal.lines(order and order.log or crafter.journal, W))
    if atEnd then list.offset = list:maxOffset() end
    updatePageLabel(list)
  end

  local function open(o)
    if app.current ~= "logs" then back = app.current or "list" end
    order = o
    disarm()
    title:set("text", o and ("LOGS - " .. crafter.orderText(o)) or "LOGS - all")
    list.offset = 0
    list:setItems({})
    -- An order reads from the start, the full log from the end
    if o then
      update()
      list.offset = 0
      updatePageLabel(list)
    else
      list.offset = math.huge
      update()
    end
    app:show("logs")
  end

  return {
    page = page,
    open = open,
    tick = update,
    onCraft = update,
  }
end
