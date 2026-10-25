-- pages/list.lua : écran principal. Sans recherche, la commande en préparation (les
-- recettes ajoutées depuis la page recette) et le bouton CRAFTER qui la lance ; avec
-- une recherche, les items trouvés en tuiles, une page à la fois (comme JEI). CRAFTER
-- ouvre le suivi des crafts (pages/crafts.lua). Avec le mod Recipe API, la liste et le
-- total viennent du jeu ; seuls les items que l'atelier sait faire (machine avec un
-- poste) sont montrés. La sortie de la commande se choisit à droite de son titre ;
-- « Vider » envoie cette sortie à la poubelle (config.trash). « Postes » : pages/postes.lua.

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
  local lines = {} -- commande en préparation : { recipe, qty }
  local notice -- message sur la ligne de titre de la commande : { text, ok, lost, expires }
  local NOTICE_TIME = 60 -- secondes d'affichage d'un bloc absent

  -- Page des postes du réseau, en rouge quand un bloc de la configuration manque
  local postesBtn = page:add(ui.Button{
    x = 1, y = 1, w = 8, h = 1, text = "Postes",
    onClick = function() app:show("postes") end,
  })
  page:add(ui.Label{
    x = 9, y = 1, w = W - 12, text = "AUTO-CRAFTEUR",
    align = "center", fg = colors.black, bg = colors.cyan,
  })
  local function updatePostes()
    local state = network.state
    postesBtn:set("bg", state and state.missing > 0 and colors.red or colors.blue)
  end
  -- Son de fin de commande (sound.lua) : vert = actif ; remis, il joue l'accord de fin
  local soundBtn, updateOrder
  soundBtn = page:add(ui.Button{
    x = W - 3, y = 1, w = 3, h = 1, text = "\14", -- note de musique de la police CC
    bg = sound.enabled and colors.green or colors.gray,
    onClick = function()
      sound.toggle()
      soundBtn:set("bg", sound.enabled and colors.green or colors.gray)
      if not sound.speaker() then
        notice = { text = "Pas de haut-parleur sur le reseau" }
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
    x = 1, y = 2, w = W - 1, placeholder = "Rechercher un item...",
  })
  page:add(ui.Button{
    x = W, y = 2, w = 1, h = 1, text = "x", bg = colors.lightGray, fg = colors.black,
    onClick = function() search:setValue("") end,
  })
  page.focus = search

  -- Résultats de la recherche : seule la page affichée est demandée au mod
  local grid = page:add(ui.Grid{
    x = 1, y = 3, w = W, h = H - 5, altBg = colors.black,
    emptyText = "Aucun item",
    onSelect = function(_, tile) ctx.pages.recipe.open(tile.item) end,
  })
  local perPage = grid.cols * grid.h
  local pageNo, pages = 0, 1

  -- Commande en préparation (affichée quand la recherche est vide)
  local orderTitle = page:add(ui.Label{
    x = 1, y = 3, w = W, text = "", align = "center", fg = colors.black, bg = colors.lightGray,
  })

  -- Sortie de la commande, sous la liste : un clic passe à la suivante (stations.outputs),
  -- puis au stockage (le produit y reste). « Vider » vide la sortie choisie
  local chosen -- nom de la sortie choisie, false = stockage, nil = la première
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
    emptyText = "Cherche un item a ajouter",
    onSelect = function(_, it) ctx.pages.recipe.edit(it.line) end,
  })

  -- Machines qui ont un poste (la turtle en a toujours un)
  local machines = {}
  for m in pairs(crafter.machines) do
    if stations.pool(m)[1] then machines[m] = true end
  end

  -- Barre du bas : pagination (recherche) ou Crafts + Vider + Logs + Scan + CRAFTER (commande)
  local prev, pageLabel, nextBtn, craftsBtn, trashBtn, craftBtn, scanBtn
  local CONFIRM = 5 -- secondes pour confirmer « Vider » par un 2e clic
  local armed -- os.clock() du 1er clic sur « Vider »

  local function disarm()
    armed = nil
    trashBtn:set("text", "Vider")
    trashBtn:set("bg", colors.blue)
  end

  function updateOrder()
    local items = {}
    for i, l in ipairs(lines) do
      items[i] = { text = name(l.recipe.output.name), right = tostring(l.qty * l.recipe.output.count), line = l }
    end
    orderList:setItems(items)
    local out, outs = selectedOutput()
    outBtn.hidden = orderTitle.hidden or not outs[2] -- une seule sortie : rien à choisir
    outBtn:set("text", "Sortie : " .. (out and out.label or "stockage") .. "  (changer)")
    orderList.h = outBtn.hidden and H - 6 or H - 7
    if notice then
      orderTitle:set("text", notice.text)
      orderTitle:set("bg", notice.ok and colors.lime or colors.red)
    else
      orderTitle:set("text", #lines > 0 and ("Commande (" .. #lines .. ")") or "Commande vide")
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
    updatePostes()
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
    -- Le focus ne reste pas sur des tuiles ou une commande cachées ou vides
    local f = page.focus
    if f ~= search and (f.hidden or not f.items[1]) then page.focus = search end
  end

  local function goTo(n)
    pageNo = math.max(0, math.min(n, pages - 1))
    refresh()
  end

  -- Boutons de 3 lignes, texte en H - 1, à une colonne des bords : le cadre du moniteur
  -- prend la couleur de fond de la case voisine et ferait dépasser le bord du bouton
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
  -- 1er clic : « Sur ? » en rouge ; 2e clic dans les CONFIRM s : tout part à la lave
  trashBtn = page:add(ui.Button{
    x = 12, y = y, w = 6, h = 3, text = "Vider",
    onClick = function()
      if not (armed and os.clock() - armed < CONFIRM) then
        armed = os.clock()
        trashBtn:set("text", "Sur ?")
        trashBtn:set("bg", colors.red)
        return
      end
      disarm()
      local out = selectedOutput()
      if not (out and peripheral.isPresent(out.name) and peripheral.isPresent(config.trash)) then
        notice = { text = "Sortie ou poubelle introuvable" }
      else
        local moved, left = storage.moveAll(out.name, config.trash)
        notice = left > 0 and { text = ("Poubelle pleine : %d items restent"):format(left) }
                 or { text = ("Sortie videe : %d items"):format(moved), ok = true }
      end
      updateOrder()
    end,
  })
  craftBtn = page:add(ui.Button{
    x = W - 7, y = y, w = 7, h = 3, text = "CRAFTER", bg = colors.gray, fg = colors.black,
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

  -- Sortie suivante, puis le stockage, puis la première
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

  -- Clavier : ↓ depuis la recherche passe sur les tuiles (recherche) ou sur la commande
  -- (sans recherche) ; ↑ depuis la 1re ligne y revient ; une lettre ou Retour aussi.
  -- Tuiles : ← / → aux bords changent de page. Commande : ← / → quantité ±1, Page ±10
  local typeKey = search.key -- celle de TextInput (Retour arrière)
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
  -- Relance la détection du réseau (pages/detector.lua demande : tout, ou en plus)
  scanBtn = page:add(ui.Button{
    x = 26, y = y, w = 5, h = 3, text = "Scan",
    onClick = function()
      local s = crafter.status
      if s.running[1] or s.queue[1] then
        notice = { text = "Scan : attendre la fin des commandes" }
        return updateOrder()
      end
      app:show("detector")
    end,
  })

  -- Commande en préparation, utilisée par la page recette
  local order = {}

  -- Ajoute `qty` crafts de `recipe` ; vide la recherche pour revenir sur la commande.
  -- Une ligne par item : si l'item y est déjà (même par une autre recette), sa ligne
  -- garde sa recette et reçoit au moins autant d'items en plus
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

  -- Recette reçue du bouton « + » de JEI (tablette) : 1 craft, ou une pile avec shift
  function order.fromJei(id, max)
    storage.scan()
    local r = recipes.get(id, storage.stock)
    local m = r and recipes.machine(r)
    if not r then
      notice = { text = "JEI : recette non geree" }
    elseif not (crafter.machines[m] and stations.pool(m)[1]) then
      notice = { text = "JEI : pas de poste " .. (recipes.machineLabel(r) or m) }
    else
      order.add(r, max and math.max(1, math.floor(64 / r.output.count)) or 1)
      notice = { text = "+ " .. name(r.output.name), ok = true }
    end
    if app.current == "list" then refresh() end
  end

  order.lines = lines

  page.onShow = refresh

  -- Réseau relu (network.check) : bouton Postes en rouge, et message si des blocs de la
  -- configuration viennent de disparaître (`lost` : leurs noms) ; `text` : autre message.
  -- Le message « Absent » perd les blocs revenus, et s'efface quand il n'en reste plus
  -- ou après NOTICE_TIME s (tick) ; le journal garde la trace (main.lua)
  local function absentText(set)
    local names = {}
    for n in pairs(set) do names[#names + 1] = (n:gsub("^.-:", "")) end
    table.sort(names)
    return names[1] and ("Absent : " .. table.concat(names, ", "))
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
    if app.current == "list" then refresh() else updatePostes() end
  end

  return {
    page = page,
    order = order,
    onNetwork = onNetwork,
    -- « Sur ? » ne reste pas affiché après le délai de confirmation
    tick = function()
      if armed and os.clock() - armed >= CONFIRM then disarm() end
      if notice and notice.expires and os.clock() >= notice.expires then
        notice = nil
        updateOrder()
      end
    end,
  }
end
