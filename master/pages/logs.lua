-- pages/logs.lua : journal détaillé d'une commande, ou de toutes (crafter.journal)

local ui = require("ui")
local crafter = require("crafter")
local journal = require("journal")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local order -- nil = toutes les commandes
  local back = "list" -- page d'où les logs ont été ouverts

  local title = page:add(ui.Label{
    x = 1, y = 1, w = W, text = "LOGS", align = "center", fg = colors.black, bg = colors.cyan,
  })

  local pageLabel
  local function updatePageLabel(l)
    local cur, total = l:pageInfo()
    pageLabel:set("text", cur .. "/" .. total)
  end

  local list = page:add(ui.List{
    x = 1, y = 2, w = W, h = H - 4, emptyText = "Rien pour l'instant",
    onScroll = updatePageLabel,
  })

  -- Boutons de 3 lignes, texte en H - 1, à une colonne des bords : le cadre du moniteur
  -- prend la couleur de fond de la case voisine et ferait dépasser le bord du bouton
  local y = H - 2
  page:add(ui.Button{
    x = 2, y = y, w = 8, h = 3, text = "< Retour",
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
    x = 25, y = y, w = 6, h = 3, text = "Tout",
    onClick = function() ctx.pages.logs.open(nil) end,
  })

  -- « Annuler » une commande en file ou en cours : 1er clic « Sur ? », 2e clic dans
  -- les CONFIRM s
  local CONFIRM = 5
  local armed -- os.clock() du 1er clic
  local cancelBtn
  local function disarm()
    armed = nil
    cancelBtn:set("text", "Annuler")
  end
  cancelBtn = page:add(ui.Button{
    x = 32, y = y, w = 7, h = 3, text = "Annuler", bg = colors.red, hidden = true,
    onClick = function()
      if not (armed and os.clock() - armed < CONFIRM) then
        armed = os.clock()
        cancelBtn:set("text", "Sur ?")
        return
      end
      disarm()
      crafter.cancel(order)
      cancelBtn.hidden = true
    end,
  })

  -- Recharge les lignes ; reste en bas si on y était (suivi en direct)
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
    title:set("text", o and ("LOGS - " .. crafter.orderText(o)) or "LOGS - tout")
    list.offset = 0
    list:setItems({})
    -- Une commande se lit depuis le début, le journal complet depuis la fin
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
