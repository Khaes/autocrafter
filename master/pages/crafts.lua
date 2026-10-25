-- pages/crafts.lua : suivi des commandes, ouvert après CRAFTER. En haut les commandes en
-- cours (jaune), puis la file (gris, « attente » si le stock est pris par une autre), puis les commandes finies (vert) ou en erreur
-- (rouge) ou annulées (orange), la plus récente d'abord. Un clic sur une ligne ouvre
-- ses logs, où une commande en file ou en cours peut être annulée.

local ui = require("ui")
local recipes = require("recipes")
local crafter = require("crafter")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local name = recipes.displayName

  page:add(ui.Label{
    x = 1, y = 1, w = W, text = "SUIVI DES CRAFTS", align = "center",
    fg = colors.black, bg = colors.yellow,
  })

  local list = page:add(ui.List{
    x = 1, y = 2, w = W, h = H - 4, altBg = colors.gray, emptyText = "Aucun craft",
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

  -- Barre du bas
  -- Boutons de 3 lignes, texte en H - 1, à une colonne des bords : le cadre du moniteur
  -- prend la couleur de fond de la case voisine et ferait dépasser le bord du bouton
  local y = H - 2
  page:add(ui.Button{
    x = 2, y = y, w = 10, h = 3, text = "< Retour",
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
    x = W - 8, y = y, w = 8, h = 3, text = "Effacer", bg = colors.gray,
    onClick = function() crafter.clearHistory() end,
  })

  page.onShow = update

  return {
    page = page,
    onCraft = update,
  }
end
