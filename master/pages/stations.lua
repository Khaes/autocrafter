-- pages/postes.lua : blocs du réseau de la configuration (étape 9), ouverte par le
-- bouton « Postes » de l'écran principal. Vert : présent ; rouge : absent (cassé, modem
-- coupé ou renuméroté) ; jaune : bloc du réseau qu'aucun rôle n'utilise.
-- « Reparer » remplace un bloc renuméroté (network.repair) ; « Detecter » relance la
-- détection (pages/detector.lua), seulement quand aucune commande ne tourne.

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
    x = 1, y = 1, w = W, text = "POSTES DU RESEAU", align = "center",
    fg = colors.black, bg = colors.yellow,
  })
  local list = page:add(ui.List{
    x = 1, y = 2, w = W, h = H - 5, altBg = colors.gray, emptyText = "Aucun bloc configure",
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
      local what = r.worker and ("ouvriere " .. r.worker) or short(r.name)
      items[#items + 1] = { text = r.role .. " " .. what, right = r.present and "ok" or "absent",
                            fg = r.present and colors.lime or colors.red,
                            rightFg = r.present and colors.lime or colors.red }
    end
    for _, n in ipairs(state.new) do
      items[#items + 1] = { text = short(n), right = "sans role", fg = colors.yellow, rightFg = colors.yellow }
    end
    list:setItems(items)
    repairBtn.hidden = state.missing == 0
  end

  -- Boutons de 3 lignes, texte en H - 1, à une colonne des bords : le cadre du moniteur
  -- prend la couleur de fond de la case voisine et ferait dépasser le bord du bouton
  local y = H - 2
  page:add(ui.Button{
    x = 2, y = y, w = 8, h = 3, text = "< Retour",
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
    x = 19, y = y, w = 9, h = 3, text = "Reparer", bg = colors.orange, fg = colors.black,
    onClick = function()
      local done = network.repair()
      if done[1] then
        storage.ready() -- le tampon a peut-être changé de nom
        setStatus("Remplace : " .. table.concat(done, ", "), colors.lime)
      else
        setStatus("Rien a remplacer : relancer la detection", colors.red)
      end
      update()
    end,
  })
  page:add(ui.Button{
    x = W - 10, y = y, w = 10, h = 3, text = "Detecter",
    onClick = function()
      local s = crafter.status
      if s.running[1] or s.queue[1] then
        return setStatus("Attendre la fin des commandes", colors.red)
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
