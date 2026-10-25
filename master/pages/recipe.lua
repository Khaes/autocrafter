-- pages/recipe.lua : recettes d'un item que l'atelier sait faire (celles de recipes.db
-- d'abord), une à la fois ; < > pour passer de l'une à l'autre quand il y en a
-- plusieurs. « AJOUTER » met la recette dans la commande de l'écran principal ;
-- ouverte depuis une ligne de la commande, la page la modifie ou la retire. La
-- quantité se règle aussi au clavier (flèches, Page préc./suiv., chiffres, Entrée).

local ui = require("ui")
local storage = require("storage")
local recipes = require("recipes")
local crafter = require("crafter")
local stations = require("stations")

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local name = recipes.displayName
  local page = ui.Page()
  local item, choices, index = nil, {}, 1
  local current, qty = nil, 1
  local editing -- ligne de la commande modifiée, sinon nil

  local title = page:add(ui.Label{
    x = 1, y = 1, w = W, text = "", align = "center", fg = colors.black, bg = colors.yellow,
  })

  local status = page:add(ui.Label{ x = 1, y = H - 3, w = W, text = "" })
  local function setStatus(text, color)
    status:set("fg", color or colors.white)
    status:set("text", text)
  end

  -- Grille 3x3 + résultat
  local cw = math.max(4, math.min(12, math.floor((W - 18) / 3)))
  local grid = page:add(ui.CraftGrid{
    x = 2, y = 3, cellW = cw, rowGap = 1,
    onClick = function(_, i, cell)
      if not cell then return end
      local input = recipes.displayGrid(current)[i]
      local need = recipes.needs(current)[input] * qty
      setStatus(("%s : %d/%d"):format(name(input), storage.count(input), need), colors.lightGray)
    end,
  })

  local gx = grid.x + grid.w + 1
  local stockLabel = page:add(ui.Label{ x = gx, y = 3, w = W - gx + 1, text = "" })
  page:add(ui.Label{ x = gx, y = 5, text = "=>" })
  local outLabel = page:add(ui.Label{ x = gx + 3, y = 5, w = W - gx - 2, text = "", fg = colors.yellow })
  local maxLabel = page:add(ui.Label{ x = gx, y = 7, w = W - gx + 1, text = "" })
  -- Rangée de quantité centrée : -10 -1 [x1] +1 +10 Max
  local qx = math.floor((W - 33) / 2) + 1
  local qtyLabel = page:add(ui.Label{ x = qx + 9, y = 9, w = 9, text = "", align = "center" })

  local navLabel, navBtns
  local function update()
    local many = #choices > 1
    navLabel.hidden, navBtns[1].hidden, navBtns[2].hidden = not many, not many, not many
    navLabel:set("text", index .. "/" .. #choices)
    local r = current
    if not r then
      grid:setCells({})
      title:set("text", name(item))
      outLabel:set("text", ""); stockLabel:set("text", "Stock: " .. storage.count(item))
      maxLabel:set("text", ""); qtyLabel:set("text", "")
      setStatus("Aucune recette pour les machines de l'atelier", colors.red)
      return
    end
    local needs = recipes.needs(r)
    local display = recipes.displayGrid(r)
    local cells = {}
    for i = 1, 9 do
      local input = display[i]
      if input then
        local bg = colors.green
        if storage.count(input) < needs[input] * qty then
          bg = recipes.find(input) and colors.orange or colors.red
        end
        cells[i] = { text = name(input), bg = bg, fg = colors.black }
      end
    end
    grid:setCells(cells)
    local label = recipes.machineLabel(r)
    title:set("text", name(r.output.name) .. (label and (" [" .. label .. "]") or ""))
    outLabel:set("text", r.output.count .. "x " .. name(r.output.name))
    stockLabel:set("text", "Stock: " .. storage.count(r.output.name))
    maxLabel:set("text", "Faisable: x" .. recipes.craftable(r, storage.stock))
    local s = "x" .. qty
    if r.output.count > 1 then s = s .. " =" .. qty * r.output.count end
    qtyLabel:set("text", s)
  end

  -- Quantité
  local function setQty(v)
    if not current then return end
    qty = math.max(1, math.min(9999, v))
    update()
  end

  page:add(ui.Button{ x = qx,      y = 9, w = 4, h = 1, text = "-10", onClick = function() setQty(qty - 10) end })
  page:add(ui.Button{ x = qx + 5,  y = 9, w = 3, h = 1, text = "-1",  onClick = function() setQty(qty - 1) end })
  page:add(ui.Button{ x = qx + 19, y = 9, w = 3, h = 1, text = "+1",  onClick = function() setQty(qty + 1) end })
  page:add(ui.Button{ x = qx + 23, y = 9, w = 4, h = 1, text = "+10", onClick = function() setQty(qty + 10) end })
  page:add(ui.Button{
    x = qx + 28, y = 9, w = 5, h = 1, text = "Max",
    onClick = function()
      if current then setQty(recipes.craftable(current, storage.stock)) end
    end,
  })

  -- Barre du bas, centrée : Retour, AJOUTER (ou VALIDER), et Retirer en modification
  local backBtn = page:add(ui.Button{
    x = 1, y = H - 2, w = 10, h = 3, text = "< Retour",
    onClick = function() app:show("list") end,
  })

  local addBtn = page:add(ui.Button{
    x = 1, y = H - 2, w = 11, h = 3, text = "AJOUTER",
    bg = colors.green, fg = colors.black,
    onClick = function()
      if not current then return end
      local order = ctx.pages.list.order
      if editing then
        editing.recipe, editing.qty = current, qty
      else
        order.add(current, qty)
      end
      app:show("list")
    end,
  })

  local removeBtn = page:add(ui.Button{
    x = 1, y = H - 2, w = 9, h = 3, text = "Retirer", bg = colors.red, hidden = true,
    onClick = function()
      ctx.pages.list.order.remove(editing)
      app:show("list")
    end,
  })

  -- Clavier : ← → ±1, ↑ ↓ ±64, Page préc./suiv. ±10, Entrée = AJOUTER. Les chiffres
  -- tapent la quantité (le 1er remplace, les suivants s'ajoutent), Retour efface
  local STEPS = { [keys.right] = 1, [keys.left] = -1, [keys.up] = 64, [keys.down] = -64,
                  [keys.pageUp] = 10, [keys.pageDown] = -10 }
  local typed = "" -- chiffres tapés depuis la dernière flèche ou l'ouverture
  page.focus = {
    key = function(_, k)
      if STEPS[k] then
        typed = ""
        setQty(qty + STEPS[k])
      elseif k == keys.enter then
        addBtn.onClick()
      elseif k == keys.backspace and typed ~= "" then
        typed = typed:sub(1, -2)
        setQty(tonumber(typed) or 1)
      end
    end,
    char = function(_, c)
      if not current or not c:match("^%d$") or tonumber(typed .. c) > 9999 then return end
      typed = typed .. c
      setQty(tonumber(typed))
    end,
  }

  -- Recette précédente / suivante quand l'item en a plusieurs (rangée centrée)
  local function choose(i)
    if not choices[1] then return end
    index = (i - 1) % #choices + 1
    current, qty = choices[index], editing and qty or 1
    setStatus("")
    update()
  end
  local nx = math.floor((W - 15) / 2) + 1
  navBtns = {
    page:add(ui.Button{ x = nx, y = 11, w = 4, h = 3, text = "<", onClick = function() choose(index - 1) end }),
    page:add(ui.Button{ x = nx + 11, y = 11, w = 4, h = 3, text = ">", onClick = function() choose(index + 1) end }),
  }
  navLabel = page:add(ui.Label{ x = nx + 4, y = 12, w = 7, text = "", align = "center" })

  -- Recettes de `name` que l'atelier peut faire (machine connue et poste configuré),
  -- demandées au moment de l'ouverture
  local function load(itemName)
    item = itemName
    storage.scan()
    choices = {}
    for _, r in ipairs(recipes.findAll(item, storage.stock)) do
      if crafter.machines[recipes.machine(r)] and stations.pool(recipes.machine(r))[1] then
        choices[#choices + 1] = r
      end
    end
    current, index, qty = choices[1], 1, 1
    typed = ""
    setStatus("")
  end

  local function setEditing(line)
    editing = line
    removeBtn.hidden = not line
    addBtn:set("text", line and "VALIDER" or "AJOUTER")
    -- Recentre les boutons visibles
    local shown = { backBtn, addBtn, line and removeBtn or nil }
    local total = -1
    for _, b in ipairs(shown) do total = total + b.w + 1 end
    local x = math.floor((W - total) / 2) + 1
    for _, b in ipairs(shown) do
      b.x = x
      x = x + b.w + 1
    end
  end

  local function open(itemName)
    load(itemName)
    setEditing(nil)
    update()
    app:show("recipe")
  end

  -- Modifier une ligne de la commande : sa recette et sa quantité
  local function edit(line)
    load(line.recipe.output.name)
    index = nil
    for i, r in ipairs(choices) do
      if r == line.recipe or (r.id ~= nil and r.id == line.recipe.id) then index = i break end
    end
    if not index then
      table.insert(choices, 1, line.recipe)
      index = 1
    end
    current, qty = choices[index], line.qty
    setEditing(line)
    update()
    app:show("recipe")
  end

  return {
    page = page,
    open = open,
    edit = edit,
    tick = function()
      storage.scan()
      update()
    end,
  }
end
