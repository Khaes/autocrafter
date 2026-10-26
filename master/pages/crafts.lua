-- pages/crafts.lua: order tracking, opened after CRAFT. At the top the running orders
-- (yellow), then the queue (gray, "waiting" if the stock is held by another one), then
-- the finished orders (green), failed (red) or cancelled (orange), most recent first.
-- Clicking a line opens its logs, where a queued or running order can be cancelled.

local ui = require("ui")
local recipes = require("recipes")
local crafter = require("crafter")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local name = recipes.displayName

  page:add(ui.Label{
    x = 1, y = 1, w = W, text = "CRAFT TRACKING", align = "center",
    fg = colors.black, bg = colors.yellow,
  })

  local list = page:add(ui.List{
    x = 1, y = 2, w = W, h = H - 4, altBg = colors.gray, emptyText = "No craft",
    onSelect = function(_, item) ctx.pages.logs.open(item.order) end,
  })

  local COLORS = { running = colors.yellow, queued = colors.lightGray, done = colors.lime,
                   error = colors.red, cancelled = colors.orange }

  local function update()
    local items = {}
    for _, e in ipairs(crafter.summary()) do
      local o, fg = e.order, COLORS[e.kind]
      items[#items + 1] = { text = name(o.recipe.output.name), fg = fg, rightFg = fg,
                            right = o.times * o.recipe.output.count .. "  " .. e.state, order = o }
    end
    list:setItems(items)
  end

  -- Bottom bar
  -- 3-line buttons, text on H - 1, one column away from the edges: the monitor's frame
  -- takes the background color of the next cell and would make the button overflow
  local y = H - 2
  page:add(ui.Button{
    x = 2, y = y, w = 10, h = 3, text = "< Back",
    onClick = function() app:show("list") end,
  })
  page:add(ui.Button{
    x = 13, y = y, w = 8, h = 3, text = "Logs",
    onClick = function() ctx.pages.logs.open(nil) end,
  })
  page:add(ui.Button{
    x = 22, y = y, w = 4, h = 3, text = "<",
    onClick = function() list:scroll(-list.h) end,
  })
  page:add(ui.Button{
    x = 27, y = y, w = 4, h = 3, text = ">",
    onClick = function() list:scroll(list.h) end,
  })
  page:add(ui.Button{
    x = W - 8, y = y, w = 8, h = 3, text = "Clear", bg = colors.gray,
    onClick = function() crafter.clearHistory() end,
  })

  page.onShow = update

  return {
    page = page,
    onCraft = update,
  }
end
