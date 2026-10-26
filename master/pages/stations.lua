-- pages/stations.lua: network blocks of the configuration (step 9), opened by the
-- "Stations" button of the main screen. Green: present; red: missing (broken, modem
-- off or renumbered); yellow: network block that no role uses.
-- "Repair" replaces a renumbered block (network.repair); "Detect" runs the detection
-- again (pages/detector.lua), only when no order is running.

local ui = require("ui")
local network = require("network")
local crafter = require("crafter")
local storage = require("storage")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local short = network.short

  page:add(ui.Label{
    x = 1, y = 1, w = W, text = "NETWORK STATIONS", align = "center",
    fg = colors.black, bg = colors.yellow,
  })
  local list = page:add(ui.List{
    x = 1, y = 2, w = W, h = H - 5, altBg = colors.gray, emptyText = "No block configured",
  })
  local status = page:add(ui.Label{ x = 1, y = H - 3, w = W, text = "" })
  local function setStatus(text, color)
    status:set("text", text)
    status:set("fg", color or colors.white)
  end

  local repairBtn

  local function update()
    local state = network.state or network.check()
    local items = {}
    for _, r in ipairs(state.rows) do
      local what = r.worker and ("worker " .. r.worker) or short(r.name)
      items[#items + 1] = { text = r.role .. " " .. what, right = r.present and "ok" or "missing",
                            fg = r.present and colors.lime or colors.red,
                            rightFg = r.present and colors.lime or colors.red }
    end
    for _, n in ipairs(state.new) do
      items[#items + 1] = { text = short(n), right = "no role", fg = colors.yellow, rightFg = colors.yellow }
    end
    list:setItems(items)
    repairBtn.hidden = state.missing == 0
  end

  -- 3-line buttons, text on H - 1, one column away from the edges: the monitor's frame
  -- takes the background color of the next cell and would make the button overflow
  local y = H - 2
  page:add(ui.Button{
    x = 2, y = y, w = 8, h = 3, text = "< Back",
    onClick = function() app:show("list") end,
  })
  page:add(ui.Button{
    x = 11, y = y, w = 3, h = 3, text = "<",
    onClick = function() list:scroll(-list.h) end,
  })
  page:add(ui.Button{
    x = 15, y = y, w = 3, h = 3, text = ">",
    onClick = function() list:scroll(list.h) end,
  })
  repairBtn = page:add(ui.Button{
    x = 19, y = y, w = 9, h = 3, text = "Repair", bg = colors.orange, fg = colors.black,
    onClick = function()
      local done = network.repair()
      if done[1] then
        storage.ready() -- the buffer may have changed its name
        setStatus("Replaced: " .. table.concat(done, ", "), colors.lime)
      else
        setStatus("Nothing to replace: run the detection again", colors.red)
      end
      update()
    end,
  })
  page:add(ui.Button{
    x = W - 10, y = y, w = 10, h = 3, text = "Detect",
    onClick = function()
      local s = crafter.status
      if s.running[1] or s.queue[1] then
        return setStatus("Wait for the orders to finish", colors.red)
      end
      app:show("detector")
    end,
  })

  page.onShow = function()
    setStatus("")
    network.check()
    update()
  end

  return {
    page = page,
    update = update,
  }
end
