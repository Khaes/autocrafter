-- pages/detector.lua : premier lancement, détection du réseau
-- Questions à l'écran pour le stockage, le tampon, la sortie et la poubelle, puis
-- détection des machines à défilement (un coffre d'entrée -> machine -> un coffre de
-- sortie) en envoyant des items de test. Le résultat est enregistré dans config.json.

local ui = require("ui")
local config = require("config")
local storage = require("storage")
local remote = require("remote")
local burner = require("machines.burner")

-- Montage de test : ces réponses sont prises telles quelles et le scan des machines
-- démarre directement. nil pour poser les questions
--[[local DEV_CONFIG = {
  storage = { 'storagedrawers:controller_slave_1' },
  trash = 'minecraft:chest_27',
  outputs = { 'minecraft:chest_26' },
  buffer = 'minecraft:chest_1',
}]]--
local DEV_CONFIG = nil

-- Items envoyés dans chaque coffre, dans cet ordre (liste : pairs ne garantit pas
-- d'ordre), avec pour chaque machine le résultat attendu. Un résultat doit être
-- certain et propre à sa machine, sinon un autre poste peut être pris pour elle.
-- confirm : 2e item quand le résultat peut venir d'une autre machine ; il doit
-- donner confirm.output dans le même coffre de sortie
local TESTS = {
  -- En premier : le millstone refuse les items sans recette, qui restent alors
  -- bloqués dans la chute devant lui ; les fans et le saw laissent tout passer.
  -- Le lavage de gravel sort parfois 1 flint : le blé (farine) confirme le milling
  { item = "minecraft:gravel", results = {
    crushing = {output = 'minecraft:sand', qty = 1},
    milling = {output = 'minecraft:flint', qty = 1,
               confirm = { item = "minecraft:wheat", output = "create:wheat_flour" }},
  } },
  { item = "minecraft:white_concrete_powder", results = {
    washing = {output = 'minecraft:white_concrete', qty = 1},
  } },
  { item = "minecraft:cobblestone", results = {
    blasting = {output = 'minecraft:stone', qty = 1},
    haunting = {output = 'minecraft:blackstone', qty = 1},
  } },
  { item = "minecraft:oak_log", results = {
    sawing = {output = 'minecraft:stripped_oak_log', qty = 1}
  } },
  { item = "minecraft:beef", results = {
    smoking = {output = 'minecraft:cooked_beef', qty = 1}
  } },
}

local MACHINES = { "turtle", "pressing", "filling", "deploying", "mixing", "compacting", "washing",
  "smoking", "haunting", "blasting", "crushing", "milling", "sawing" }
local SIDES = { left = true, right = true, front = true, back = true, top = true, bottom = true }
local INTAKE_DELAY = 1     -- secondes avant de regarder si la machine a pris l'item
local OUTPUT_TIMEOUT = 9   -- secondes max pour voir arriver le résultat (fans : 7,5 s + trajet)
local CHECK_INTERVAL = 0.5 -- secondes entre deux relevés des coffres pendant l'attente
local PROBE_TIMEOUT = 2    -- secondes max pour la réponse des ouvrières
-- Test des depots : press (DEPOT_ITEM -> DEPOT_PRESSED) ou spout d'eau (-> DEPOT_FILLED)
local DEPOT_ITEM, DEPOT_PRESSED, DEPOT_FILLED = "minecraft:dirt", "minecraft:dirt_path", "minecraft:grass_block"
local SPOUT_WATER = 500    -- mB d'eau envoyés au spout testé
local DEPOT_TIMEOUT = 3    -- secondes max pour qu'une press ou un spout transforme l'item
-- Test des basins (recettes de Create) : mixer sans chaleur, puis chauffé
local MIX_ITEMS, MIX_RESULT = { "minecraft:andesite", "minecraft:iron_nugget" }, "create:andesite_alloy"
local HEATED_ITEMS, HEATED_RESULT = { "minecraft:copper_ingot", "create:zinc_ingot" }, "create:brass_ingot"
local MIX_TIMEOUT = 10     -- secondes max pour qu'un mixer fasse sa recette
-- Test des basins sous une press (compacting) : create:compacting/andesite_from_flint,
-- 2 flint + 1 gravel + 100 mB de lave, sans chaleur, et qu'aucun mixer ne fait
local COMPACT_ITEMS = { "minecraft:flint", "minecraft:flint", "minecraft:gravel" }
local COMPACT_FLUID, COMPACT_MB, COMPACT_RESULT = "minecraft:lava", 100, "minecraft:andesite"
-- Press chauffée : createdeco:compacting/industrial_iron_ingot (Create Deco ; sans ce mod,
-- les burners des presses ne sont pas trouvés)
local HEATED_COMPACT_ITEMS, HEATED_COMPACT_RESULT = { "minecraft:iron_ingot" }, "createdeco:industrial_iron_ingot"
-- Test des deployers (recette de Create) : DEPLOY_ITEM sur le depot, DEPLOY_HELD en main
local DEPLOY_ITEM, DEPLOY_HELD, DEPLOY_RESULT = "create:cogwheel", "minecraft:oak_planks", "create:large_cogwheel"
local MARKER = "minecraft:cobblestone" -- item posé dans un coffre pour trouver le tampon d'une ouvrière

-- Configuration vierge : le tampon est toujours sous la turtle
local function newConfig()
  local c = { bufferDir = "down", outputs = {}, stations = {} }
  for _, m in ipairs(MACHINES) do c.stations[m] = {} end
  return c
end

-- "minecraft:chest_12" -> "chest_12", pour les messages
local function short(name)
  return (name:gsub("^minecraft:", ""))
end

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local detected = newConfig()
  local peripherals = {}

  -- Définies plus bas ; déclarées ici pour les handlers de l'arbre
  local setInfo, detectMainStorages, searchChest, searchChests
  local startDetection, saveConfig, countFound, reset, detectDepot

  -- storage.lua prend ses inventaires dans config.storage : sans config.json, il
  -- prendrait tout le réseau (depots, entrées des machines...)
  local function setStorage(list)
    detected.storage = list
    config.storage = list
  end
  local missing -- item de TESTS absent du stockage : la détection s'est arrêtée
  local outCandidate -- coffre trouvé pour la sortie suivante, pas encore validé
  local unused = {} -- coffres du réseau qu'aucune étape n'a attribués
  local savedStorage -- config.storage avant la détection, remis si on l'annule
  -- Détection « en plus » (relancée depuis l'autocrafter) : stockage, tampon, sorties,
  -- poubelle et postes de config.json sont gardés, seuls les blocs libres sont testés.
  -- baseline : nombre de postes déjà configurés, pour ne compter que les nouveaux
  local additive, baseline = false, 0
  local loadCurrent -- défini plus bas

  -- Relancée depuis la page Postes (config.json existe) : on peut revenir sans rien
  -- changer. Au premier lancement, quitter arrête le programme
  local function quit()
    if not config.scanned then return app:stop() end
    config.storage = savedStorage
    app:show("postes")
  end
  local cancel = { label = "Annuler", run = function() quit() end,
                   when = function() return config.scanned end }

  -- Arbre de questions : chaque réponse a un handler optionnel et la question suivante.
  -- text, label et next peuvent être des fonctions (évaluées à l'affichage / au clic)
  local tree = {
    -- Relancée depuis l'autocrafter (config.json existe)
    rerun = {
      text = "Tout recommencer, ou seulement chercher les machines en plus de celles connues ?",
      answers = {
        { label = "En plus", run = function() loadCurrent() end, next = "scan" },
        { label = "Tout", run = function() reset() end, next = "mainStorage" },
        cancel,
      },
    },
    mainStorage = {
      text = "Le stockage principal est avec des chests ou drawers controller ?",
      answers = {
        { label = "Chest", next = "mainStorageWhich" },
        { label = "Drawer", run = function() detectMainStorages() end,
          next = function() return detected.storage and "mainStorageDrawer" or "mainStorage" end },
        cancel,
      },
    },
    mainStorageDrawer = {
      text = function() return "Est ce le drawer " .. detected.storage[1] .. ' ?' end,
      answers = {
        { label = "Valider", next = "bufferWhich"},
        { label = "Retour", run = function() setStorage(nil) end, next = "mainStorage" },
      },
    },
    mainStorageWhich = {
      text = "Vider les chests et mettre 1 cobblestone dans chaque storage",
      answers = {
        { label = "C'est fait", run = function() setStorage(searchChests('minecraft:cobblestone')) end,
          next = function() return #detected.storage > 0 and "mainStorageConfirm" or "mainStorageWhich" end },
        { label = "Retour", next = "mainStorage" },
      },
    },
    mainStorageConfirm = {
      text = function() return "Est ce les chests " .. table.concat(detected.storage, ", ") .. ' ?' end,
      answers = {
        { label = "Valider", next = "bufferWhich", run = function()
          -- Les cobblestones repérées rejoignent le premier coffre de stockage
          for index = 2, #detected.storage do
            storage.empty(detected.storage[index])
          end
        end },
        { label = "Retour", run = function() setStorage(nil) end, next = "mainStorageWhich" },
      },
    },
    bufferWhich = {
      text = "Vider les chests et mettre 1 cobblestone dans le tampon",
      answers = {
        { label = "C'est fait", run = function()
          detected.buffer = searchChest('minecraft:cobblestone')
          if not detected.buffer then
            -- Cobble présente dessous mais dans aucun coffre du réseau : tampon non relié
            if peripheral.isPresent("bottom") and storage.has("bottom", 'minecraft:cobblestone') then
              setInfo("Tampon hors reseau : active son modem")
            else
              setInfo("Pas de cobblestone dans le tampon")
            end
          end
        end,
          next = function() return detected.buffer and "bufferConfirm" or "bufferWhich" end },
        { label = "Retour", next = "mainStorage" },
      },
    },
    bufferConfirm = {
      text = function() return "Est ce le chest " .. detected.buffer .. ' ?' end,
      answers = {
        { label = "Valider", next = "outWhich", run = function() storage.empty(detected.buffer) end },
        { label = "Retour", run = function() detected.buffer = nil end, next = "bufferWhich" },
      },
    },
    -- Plusieurs sorties possibles : la commande choisit la sienne sur l'écran principal
    outWhich = {
      text = function()
        return "Vider les chests et mettre 1 cobblestone dans " ..
          (detected.outputs[1] and "la sortie suivante" or "l'output")
      end,
      answers = {
        { label = "C'est fait", run = function() outCandidate = searchChest('minecraft:cobblestone') end,
          next = function() return outCandidate and "outConfirm" or "outWhich" end },
        { label = "Retour", run = function() detected.outputs = {} end, next = "bufferWhich" },
      },
    },
    outConfirm = {
      text = function() return "Est ce le chest " .. outCandidate .. ' ?' end,
      answers = {
        { label = "Valider", next = "outMore", run = function()
          storage.empty(outCandidate)
          table.insert(detected.outputs, outCandidate)
          outCandidate = nil
        end },
        { label = "Retour", run = function() outCandidate = nil end, next = "outWhich" },
      },
    },
    outMore = {
      text = function()
        local names = {}
        for i, n in ipairs(detected.outputs) do names[i] = short(n) end
        return "Sorties : " .. table.concat(names, ", ") .. ". Une autre sortie ?"
      end,
      answers = {
        { label = "Oui", next = "outWhich" },
        { label = "Non", next = "trash" },
      },
    },
    trash = {
      text = "Le reseau a t'il une poubelle ?",
      answers = {
        { label = "Oui", next = "trashWhich" },
        { label = "Non", run = function() detected.trash = nil end, next = "scan" },
      },
    },
    trashWhich = {
      text = "Mettre un cobblestone dans la poubelle et desactiver son mecanisme",
      answers = {
        { label = "C'est fait", run = function() detected.trash = searchChest('minecraft:cobblestone') end,
          next = function() return detected.trash and "trashConfirm" or "trashWhich" end },
        { label = "Retour", next = "trash" },
      },
    },
    trashConfirm = {
      text = function() return "Est ce le chest " .. detected.trash .. ' ?' end,
      answers = {
        { label = "Valider", next = "scan", run = function() storage.empty(detected.trash) end },
        { label = "Retour", run = function() detected.trash = nil end, next = "trashWhich" },
      },
    },
    scan = {
      text = "La detection des machines va commencer",
      answers = {
        { label = "Go", run = function() startDetection() end,
          next = function() return missing and "missingItem" or "save" end },
        cancel,
      },
    },
    missingItem = {
      text = function() return "Pas assez de " .. short(missing) .. " dans le stockage. En ajouter puis relancer" end,
      answers = {
        { label = "Relancer", next = "scan" },
        { label = "Quitter", run = function() quit() end },
      },
    },
    save = {
      text = function()
        local extra = unused[1] and (", " .. #unused .. " coffre(s) sans role") or ""
        local found = additive and ((countFound() - baseline) .. " nouvelle(s) machine(s)")
                      or (countFound() .. " machine(s) detectee(s)")
        return found .. extra .. ". Enregistrer la configuration ?"
      end,
      answers = {
        { label = "Enregistrer", run = function() saveConfig() end, next = "reboot" },
        { label = "Recommencer", run = function() reset() end, next = "mainStorage" },
        cancel,
      },
    },
    reboot = {
      text = "Configuration enregistree. Redemarrer pour lancer l'autocrafter",
      answers = {
        { label = "Redemarrer", run = function() os.reboot() end },
      },
    },
  }

  -- Disposition : titre, info (INFO_LINES lignes), question (QUESTION_LINES lignes),
  -- les boutons, et en bas le status et le nombre de machines
  local INFO_Y, INFO_LINES = 3, 2
  local QUESTION_Y, QUESTION_LINES = 6, 3
  page:add(ui.Label{
    x = 1, y = 1, w = W, text = "DETECTION DU RESEAU", align = "center",
    fg = colors.black, bg = colors.yellow,
  })
  local status = page:add(ui.Label{ x = 1, y = H - 3, w = W, text = "", align = "right" })
  local number = page:add(ui.Label{ x = 1, y = H - 1, w = W, text = "", align = "right" })
  local infoLines = {}
  for i = 1, INFO_LINES do
    infoLines[i] = page:add(ui.Label{ x = 1, y = INFO_Y + i - 1, w = W, text = "", align = "left" })
  end
  local questionLines = {}
  for i = 1, QUESTION_LINES do
    questionLines[i] = page:add(ui.Label{ x = 1, y = QUESTION_Y + i - 1, w = W, text = "", align = "center" })
  end
  -- Trois réponses au plus, sur une ligne ; la position x est calculée dans setButtons
  local BUTTON_W, BUTTON_GAP = 11, 2
  local buttons = {}
  for i = 1, 3 do
    buttons[i] = page:add(ui.Button{
      x = 1, y = QUESTION_Y + QUESTION_LINES + 1, w = BUTTON_W, hidden = true,
    })
  end

  ---------------------------------------------------------------- Affichage
  -- Le scan bloque la boucle de l'app : chaque changement de texte redessine l'écran.
  -- Pas de print : il écrirait par-dessus l'interface quand elle est sur le terminal

  local function updateStatus(text)
    status.text = text
    app:render()
  end

  function countFound()
    local n = 0
    for _, list in pairs(detected.stations) do n = n + #list end
    return n
  end

  local function updateNumber()
    local n = countFound()
    number.text = n > 0 and 'Machines trouvees : ' .. n or "Aucune machine trouvee"
    app:render()
  end

  -- Une valeur peut être une chaîne ou une fonction qui la renvoie
  local function resolve(v)
    if type(v) == "function" then return v() end
    return v
  end

  -- Découpe un texte en lignes de `width` caractères au plus, aux espaces
  local function wrap(text, width)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
      if line == "" then
        line = word
      elseif #line + 1 + #word <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
  end

  -- Répartit un texte sur des labels d'une ligne ; ce qui dépasse est perdu
  local function setLines(labels, text)
    local lines = wrap(text or "", W)
    for i, l in ipairs(labels) do l.text = lines[i] or "" end
  end

  local function setQuestion(text) setLines(questionLines, text) end

  function setInfo(text)
    setLines(infoLines, text)
    app:render()
  end

  -- choices : { { label, onClick }, ... } ; les boutons affichés sont centrés,
  -- ceux en trop sont masqués
  local function setButtons(choices)
    local n = math.min(#choices, #buttons)
    local total = n * BUTTON_W + (n - 1) * BUTTON_GAP
    local x = math.max(1, math.floor((W - total) / 2) + 1)
    for i, b in ipairs(buttons) do
      local c = choices[i]
      b.hidden = c == nil
      if c then
        b.text = c.label
        b.onClick = c.onClick
        b.x = x + (i - 1) * (BUTTON_W + BUTTON_GAP)
      end
    end
  end

  ---------------------------------------------------------------- Questions
  local ask, update

  -- Affiche l'erreur à la place de la question, avec de quoi recommencer ou quitter
  local function fail(msg)
    status.text = "Erreur"
    setLines(infoLines, "")
    setQuestion(msg)
    setButtons({
      { label = "Reessayer", onClick = function() update() end },
      { label = "Quitter", onClick = function() quit() end },
    })
    app:render()
  end

  -- Pendant un handler, les boutons sont masqués : l'écran montre qu'il travaille
  -- et un second clic ne peut pas relancer l'action
  local function choose(a)
    if a.run then
      setLines(infoLines, "") -- le handler y écrit le résultat s'il y en a un
      setButtons({})
      updateStatus("Mise a jour ...")
      local ok, err = pcall(a.run)
      if not ok then return fail(tostring(err)) end
      updateStatus("")
    end
    local ok, nextId = pcall(resolve, a.next)
    if not ok then return fail(tostring(nextId)) end
    if nextId then
      ask(nextId)
    else
      setQuestion("Detection terminee")
      setButtons({})
      app:render()
    end
  end

  function ask(id)
    local node = tree[id]
    local ok, text = pcall(resolve, node.text)
    if not ok then return fail(tostring(text)) end
    setQuestion(text)
    local choices = {}
    for _, a in ipairs(node.answers) do
      if not a.when or a.when() then
        choices[#choices + 1] = { label = resolve(a.label), onClick = function() choose(a) end }
      end
    end
    setButtons(choices)
    app:render()
  end

  ---------------------------------------------------------------- Réseau
  -- Range les périphériques du réseau par type dans `peripherals`. Avec withTurtle,
  -- renvoie un message d'erreur si le montage autour de la turtle ne va pas
  local function detectPeripherals(withTurtle)
    peripherals = { ['minecraft:chest'] = {} }
    local aroundTurtle = {}
    for _, peri in ipairs(peripheral.getNames()) do
      local type = peripheral.getType(peri)
      if SIDES[peri] then
        aroundTurtle[peri] = type
      else
        peripherals[type] = peripherals[type] or {}
        table.insert(peripherals[type], peri)
      end
    end
    if withTurtle then
      local nbChest = 0
      for _, type in pairs(aroundTurtle) do
        if type == 'minecraft:chest' then nbChest = nbChest + 1 end
      end
      if nbChest ~= 1 or aroundTurtle.bottom ~= "minecraft:chest" then
        return "Il faut un seul chest colle a la turtle : le tampon, en dessous"
      end
    end
  end

  -- Coffres déjà attribués (stockage, tampon, sortie, poubelle)
  local function assigned()
    local used = {}
    for _, name in ipairs(detected.storage or {}) do used[name] = true end
    for _, o in ipairs(detected.outputs) do used[type(o) == "table" and o.name or o] = true end
    if outCandidate then used[outCandidate] = true end
    for _, key in ipairs({ "buffer", "trash" }) do
      if detected[key] then used[detected[key]] = true end
    end
    -- Blocs des postes déjà connus (détection en plus) : ni testés, ni vidés
    for _, list in pairs(detected.stations) do
      for _, station in ipairs(list) do
        for _, key in ipairs({ "inlet", "output", "name", "spout", "deployer", "burner", "buffer" }) do
          if station[key] then used[station[key]] = true end
        end
      end
    end
    return used
  end

  -- Coffres non attribués qui contiennent itemName
  function searchChests(itemName)
    -- Relit le réseau : un modem a pu être activé depuis l'ouverture de la page
    detectPeripherals(false)
    local used, chests = assigned(), {}
    for _, name in ipairs(peripherals['minecraft:chest']) do
      if not used[name] and storage.has(name, itemName) then
        table.insert(chests, name)
      end
    end
    if #chests == 0 then setInfo("Aucun chest du reseau avec " .. itemName) end
    return chests
  end

  -- Premier coffre non attribué qui contient itemName
  function searchChest(itemName)
    return searchChests(itemName)[1]
  end

  function detectMainStorages()
    setStorage(nil)
    for _, type in ipairs({ 'storagedrawers:controller', 'storagedrawers:controller_slave' }) do
      if peripherals[type] and #peripherals[type] == 1 then
        setStorage({ peripherals[type][1] })
      end
    end
    setInfo(detected.storage and "" or "Aucun drawer controller unique trouve")
  end

  -- Vide un coffre dans la poubelle, ou dans le stockage s'il n'y en a pas
  local function trashChest(chest)
    if detected.trash then storage.moveAll(chest, detected.trash) else storage.empty(chest) end
  end

  ---------------------------------------------------------------- Machines
  -- Champs d'un poste qui sont des blocs du réseau, dans l'ordre des messages
  local STATION_KEYS = { "inlet", "output", "name", "spout", "deployer", "burner" }

  -- Ajoute un poste à machineName : { inlet, output } (défilement), { name } (press),
  -- { name, spout } (spout)... Ses blocs sont pris et ses inventaires vidés
  local function addToDetected(machineName, station, used)
    local names = {}
    for _, key in ipairs(STATION_KEYS) do
      local name = station[key]
      if name then
        names[#names + 1] = short(name)
        used[name] = true
        if peripheral.hasType(name, "inventory") then trashChest(name) end
      end
    end
    setInfo("Machine de " .. machineName .. " trouvee ( " .. table.concat(names, " => ") .. " )")
    table.insert(detected.stations[machineName], station)
    updateNumber()
  end

  -- Quantité de chaque item dans un inventaire : { [nom] = total }
  local function totals(name)
    local t = {}
    for _, item in pairs(peripheral.wrap(name).list()) do
      t[item.name] = (t[item.name] or 0) + item.count
    end
    return t
  end

  -- Contenu des coffres non attribués autres que l'entrée : { [coffre] = totals }.
  -- Relevé avant l'envoi puis pendant l'attente : seule l'augmentation compte, ce
  -- qui restait d'un scan précédent dans un coffre de sortie est ignoré
  local function snapshot(inlet, used, storages)
    local t = {}
    for _, name in ipairs(storages) do
      if name ~= inlet and not used[name] then t[name] = totals(name) end
    end
    return t
  end

  local function gained(before, now, chest, item)
    return (now[chest][item] or 0) - ((before[chest] or {})[item] or 0)
  end

  -- Regarde toutes les CHECK_INTERVAL s, OUTPUT_TIMEOUT s au plus (temps réel : le
  -- relevé des coffres compte dans l'attente), si un coffre a reçu un des résultats
  -- attendus : renvoie la machine et ce coffre. Abandonne dès que le coffre d'entrée
  -- n'est plus vide (item rendu ou refusé) ou que itemName ressort tel quel ailleurs
  -- (la machine ne le traite pas : ce coffre est vidé)
  local function waitOutput(inlet, itemName, results, used, storages, before)
    local inv = peripheral.wrap(inlet)
    local start = os.clock()
    while os.clock() - start < OUTPUT_TIMEOUT do
      sleep(CHECK_INTERVAL)
      setInfo(("Attente du resultat ... %.1f/%g s"):format(os.clock() - start, OUTPUT_TIMEOUT))
      local now = snapshot(inlet, used, storages)
      for chest in pairs(now) do
        for machineName, data in pairs(results) do
          if gained(before, now, chest, data.output) == data.qty then return machineName, chest end
        end
      end
      if next(inv.list()) ~= nil then return end
      for chest in pairs(now) do
        if gained(before, now, chest, itemName) > 0 then
          storage.empty(chest)
          return
        end
      end
    end
  end

  -- Envoie confirm.item dans inlet ; true s'il donne confirm.output dans output,
  -- false s'il y arrive tel quel (pas traité) ou si rien n'arrive à temps
  local function confirmOutput(inlet, output, confirm)
    local before = { [output] = totals(output) }
    if storage.export(confirm.item, 1, inlet) == 0 then
      missing = confirm.item
      return false
    end
    local start = os.clock()
    while os.clock() - start < OUTPUT_TIMEOUT do
      sleep(CHECK_INTERVAL)
      setInfo(("Confirmation avec %s ... %.1f/%g s"):format(short(confirm.item), os.clock() - start, OUTPUT_TIMEOUT))
      local now = { [output] = totals(output) }
      if gained(before, now, output, confirm.output) > 0 then return true end
      if gained(before, now, output, confirm.item) > 0 then return false end
    end
    return false
  end

  -- Envoie chaque item de TESTS dans le coffre jusqu'à trouver la machine qu'il
  -- alimente ; true si trouvée. Un coffre qui garde l'item n'alimente rien (le
  -- premier, le gravel, passe partout) : on le vide et on arrête là
  local function testChest(inlet, used, storages)
    local inv = peripheral.wrap(inlet)
    for _, test in ipairs(TESTS) do
      updateStatus('Test sur ' .. short(inlet) .. ' avec ' .. short(test.item))
      local before = snapshot(inlet, used, storages)
      if storage.export(test.item, 1, inlet) == 0 then
        missing = test.item -- épuisé pendant le scan : la détection s'arrête
        return false
      else
        sleep(INTAKE_DELAY)
        if next(inv.list()) ~= nil then
          updateStatus('Coffre inchange, nettoyage ...')
          storage.empty(inlet)
          return false
        else
          local machineName, output = waitOutput(inlet, test.item, test.results, used, storages, before)
          local confirm = machineName and test.results[machineName].confirm
          if confirm and not confirmOutput(inlet, output, confirm) then
            if missing then return false end
            storage.empty(output) -- résultat d'une autre machine : on continue les tests
            machineName = nil
          end
          if machineName then
            addToDetected(machineName, { inlet = inlet, output = output }, used)
            return true
          end
          if next(inv.list()) ~= nil then
            updateStatus('Item revenu dans le coffre, nettoyage ...')
            storage.empty(inlet)
          end
        end
      end
    end
    return false
  end

  -- used : coffres déjà attribués, ou à une machine ; ignorés, et complétés au passage
  local function handleStorages(storages, used)
    updateStatus('Detection des coffres')
    for _, name in ipairs(storages) do
      if not used[name] then
        testChest(name, used, storages)
        if missing then return end
      end
    end
  end

  -- Regarde chaque seconde si itemName est sur le depot, DEPOT_TIMEOUT s au plus
  local function waitItem(depot, itemName)
    for _ = 1, DEPOT_TIMEOUT do
      sleep(1)
      if storage.has(depot, itemName) then return true end
    end
    return false
  end

  local function handleDepot(depots, used)
    for _, depot in ipairs(depots or {}) do
      if not used[depot] then
        detectDepot(depot, used)
        if missing then return end
      end
    end
  end

  -- Un DEPOT_ITEM sur le depot : press s'il devient DEPOT_PRESSED, sinon chaque spout
  -- libre reçoit SPOUT_WATER mB d'eau, et celui qui en fait du DEPOT_FILLED est au-dessus
  function detectDepot(depot, used)
    updateStatus('Test du ' .. short(depot))
    storage.empty(depot) -- restes d'un essai raté
    if storage.export(DEPOT_ITEM, 1, depot) == 0 then
      missing = DEPOT_ITEM -- épuisé pendant le scan : la détection s'arrête
      return false
    end
    if waitItem(depot, DEPOT_PRESSED) then
      addToDetected('pressing', { name = depot }, used)
      return true
    end
    for _, spout in ipairs(peripherals['create:spout'] or {}) do
      if not used[spout] then
        if storage.exportFluid('minecraft:water', SPOUT_WATER, spout) < SPOUT_WATER then
          storage.importFluids(spout)
          setInfo("Pas assez d'eau (" .. SPOUT_WATER .. " mB) : spouts ignores")
          break
        end
        local filled = waitItem(depot, DEPOT_FILLED)
        -- L'eau non utilisée retourne aux tanks, que ce soit le bon spout ou non
        storage.importFluids(spout)
        if filled then
          addToDetected('filling', { name = depot, spout = spout }, used)
          return true
        end
      end
    end
    storage.empty(depot)
    return false
  end

  ---------------------------------------------------------------- Basins
  -- Envoie 1 de chaque item de `items` dans target ; false (et missing) s'il en manque un
  local function sendEach(items, target)
    for _, item in ipairs(items) do
      if storage.export(item, 1, target) == 0 then
        -- Encore en stock : c'est target qui refuse l'item, pas un manque
        storage.scan()
        if storage.count(item) > 0 then
          error(short(target) .. " refuse " .. short(item), 0)
        end
        missing = item -- épuisé pendant le scan : la détection s'arrête
        return false
      end
    end
    return true
  end

  -- Regarde chaque seconde, MIX_TIMEOUT s au plus, les basins de `list` ; s'arrête dès
  -- que `count` d'entre eux ont fini (done(basin) vrai). Renvoie ceux qui ont fini
  local function waitBasins(list, done, count)
    local finished = {}
    for _ = 1, MIX_TIMEOUT do
      sleep(1)
      finished = {}
      for _, basin in ipairs(list) do
        if done(basin) then finished[#finished + 1] = basin end
      end
      if #finished >= (count or #list) then break end
    end
    return finished
  end

  -- Vide items et fluides d'un basin dans le stockage
  local function cleanBasin(basin)
    storage.empty(basin)
    storage.importFluids(basin)
  end

  -- Donne au deployer 1 combustible de niveau `heat` (burner.fuels) : true s'il l'a
  -- donné à un blaze burner (main vide), false sinon (repris), nil si pas de combustible
  local function feedBurner(deployer, heat)
    local given = false
    for _, fuel in ipairs(burner.fuels({}, heat)) do
      if storage.export(fuel, 1, deployer) > 0 then given = true break end
    end
    if not given then return nil end
    sleep(INTAKE_DELAY)
    if next(peripheral.wrap(deployer).list()) == nil then return true end
    storage.empty(deployer)
    return false
  end

  local function remove(list, value)
    for i, v in ipairs(list) do
      if v == value then return table.remove(list, i) end
    end
  end

  -- Basins libres qui font `result` après send(basin) (envoie les items de test), puis vidés
  local function findMachines(basins, used, send, result, label)
    local tested = {}
    for _, basin in ipairs(basins or {}) do
      if not used[basin] then
        cleanBasin(basin)
        if not send(basin) then return nil end
        tested[#tested + 1] = basin
      end
    end
    if #tested == 0 then return {} end
    updateStatus('Recherche des ' .. label)
    local found = waitBasins(tested, function(b) return storage.has(b, result) end)
    for _, basin in ipairs(tested) do cleanBasin(basin) end
    return found
  end

  -- Blaze burners sous les basins de `stations` ({ [basin] = poste }). Chaque basin reçoit
  -- sa recette chauffée de test (heatTest[basin] = { items, result }), puis chaque
  -- deployer libre reçoit un combustible, un à la fois : s'il le donne, c'est un burner,
  -- et le basin qui fait alors son résultat est le sien. Une seule recherche pour mixers
  -- et presses : un burner allumé par un deployer pendant la recherche d'une machine
  -- serait vu « déjà allumé » par l'autre. Un blaze burner fait heated et superheated :
  -- le poste est noté superheated. Renvoie les remarques, ou nil si un item manque
  local function findBurners(stations, heatTest, deployers, used)
    local notes, cold = {}, {}
    for basin in pairs(stations) do
      if not sendEach(heatTest[basin].items, basin) then return nil end
      cold[#cold + 1] = basin
    end
    if #cold == 0 then return notes end
    updateStatus('Recherche des blaze burners')
    local heated = function(b) return storage.has(b, heatTest[b].result) end
    -- Burner déjà allumé avant le scan : on ne peut pas savoir quel deployer le nourrit
    for _, basin in ipairs(waitBasins(cold, heated, 1)) do
      stations[basin].heat = "superheated"
      remove(cold, basin)
      notes[#notes + 1] = short(basin) .. " : burner deja allume, deployer inconnu"
    end
    for _, deployer in ipairs(deployers or {}) do
      if #cold == 0 then break end
      if not used[deployer] then
        local fed = feedBurner(deployer, "heated")
        if fed == nil then
          notes[#notes + 1] = "pas de combustible heated"
          break
        end
        if fed then
          local basin = waitBasins(cold, heated, 1)[1]
          if basin then
            stations[basin].heat, stations[basin].burner = "superheated", deployer
            remove(cold, basin)
          end
        end
      end
    end
    for basin in pairs(stations) do cleanBasin(basin) end
    return notes
  end

  -- 1. MIX_ITEMS dans tous les basins libres : ceux qui font MIX_RESULT ont un mixer.
  -- 2. COMPACT_ITEMS et COMPACT_MB mB de COMPACT_FLUID dans les basins restés libres :
  --    ceux qui font COMPACT_RESULT ont une press au-dessus (compacting).
  -- 3. Burners des mixers (HEATED_ITEMS -> HEATED_RESULT) et des presses
  --    (HEATED_COMPACT_ITEMS -> HEATED_COMPACT_RESULT), ensemble (findBurners).
  local function handleBasin(basins, deployers, used)
    local mixers = findMachines(basins, used, function(b) return sendEach(MIX_ITEMS, b) end,
                                MIX_RESULT, "mixers")
    if not mixers then return end
    local isMixer = {}
    for _, b in ipairs(mixers) do isMixer[b] = true end
    local free = {}
    for _, b in ipairs(basins or {}) do
      if not isMixer[b] then free[#free + 1] = b end
    end
    local presses = findMachines(free, used, function(b)
      if not sendEach(COMPACT_ITEMS, b) then
        cleanBasin(b)
        return false
      end
      if storage.exportFluid(COMPACT_FLUID, COMPACT_MB, b) < COMPACT_MB then
        cleanBasin(b)
        missing = COMPACT_FLUID -- épuisé pendant le scan : la détection s'arrête
        return false
      end
      return true
    end, COMPACT_RESULT, "press sur basin")
    if not presses then return end

    local stations, heatTest, kind = {}, {}, {}
    for _, b in ipairs(mixers) do
      stations[b], kind[b] = { name = b }, "mixing"
      heatTest[b] = { items = HEATED_ITEMS, result = HEATED_RESULT }
    end
    for _, b in ipairs(presses) do
      stations[b], kind[b] = { name = b }, "compacting"
      heatTest[b] = { items = HEATED_COMPACT_ITEMS, result = HEATED_COMPACT_RESULT }
    end
    local notes = findBurners(stations, heatTest, deployers, used)
    if not notes then return end
    for _, list in ipairs({ mixers, presses }) do
      for _, b in ipairs(list) do addToDetected(kind[b], stations[b], used) end
    end
    if #notes > 0 then setInfo(table.concat(notes, ", ")) end
  end

  ---------------------------------------------------------------- Deployers
  -- DEPLOY_ITEM sur chaque depot libre, puis chaque deployer libre reçoit DEPLOY_HELD,
  -- un à la fois : le depot qui fait alors DEPLOY_RESULT est sous ce deployer.
  -- Le deployer doit être en mode « utiliser » (clic droit)
  local function handleDeployer(depots, deployers, used)
    local free = {}
    for _, depot in ipairs(depots or {}) do
      if not used[depot] then
        storage.empty(depot)
        if storage.export(DEPLOY_ITEM, 1, depot) == 0 then
          missing = DEPLOY_ITEM
          return
        end
        free[#free + 1] = depot
      end
    end
    for _, deployer in ipairs(deployers or {}) do
      if #free == 0 then break end
      if not used[deployer] then
        updateStatus('Test du ' .. short(deployer))
        storage.empty(deployer)
        if storage.export(DEPLOY_HELD, 1, deployer) == 0 then
          missing = DEPLOY_HELD
          return
        end
        local found
        for _ = 1, DEPOT_TIMEOUT do
          sleep(1)
          for _, depot in ipairs(free) do
            if storage.has(depot, DEPLOY_RESULT) then found = depot break end
          end
          if found then break end
        end
        storage.empty(deployer) -- planche pas utilisée : pas au-dessus d'un depot libre
        if found then
          remove(free, found)
          addToDetected('deploying', { name = found, deployer = deployer }, used)
        end
      end
    end
    for _, depot in ipairs(free) do storage.empty(depot) end
  end

  ---------------------------------------------------------------- Ouvrières
  -- Demande son tampon à chaque ouvrière de `ids` ; { [id] = cases du tampon } pour
  -- celles qui ont répondu (pas de réponse : worker.lua ne tourne pas)
  -- Les réponses sont lues ici avec rednet.receive, pas par remote.listen : avec
  -- DEV_CONFIG, la détection tourne dans app:show, avant que main.lua lance listen
  local function probeWorkers(ids)
    local jobs = {}
    for _, id in ipairs(ids) do jobs[id] = remote.send(id, { kind = "probe" }) end
    local replies, deadline = {}, os.clock() + PROBE_TIMEOUT
    while next(jobs) and os.clock() < deadline do
      local from, msg = rednet.receive(remote.PROTOCOL, deadline - os.clock())
      if from and jobs[from] and type(msg) == "table" and msg.job == jobs[from] then
        replies[from] = msg.items or {}
        remote.take(msg.job, from) -- copie gardée par listen s'il tourne
        jobs[from] = nil
      end
    end
    return replies
  end

  local function countMarker(items)
    local n = 0
    for _, item in pairs(items) do
      if item.name == MARKER then n = n + item.count end
    end
    return n
  end

  -- Les turtles du réseau qui répondent sont des ouvrières. Leur tampon est trouvé en
  -- posant 1 MARKER dans chaque coffre libre : c'est celui que l'ouvrière voit arriver
  local function handleWorkers(chests, used)
    local ids, notes, known = {}, {}, {}
    for _, w in ipairs(detected.stations.turtle) do known[w.worker] = true end
    for _, name in ipairs(peripherals['turtle'] or {}) do
      local id = peripheral.call(name, "getID")
      if known[id] then
        -- ouvrière déjà configurée (détection en plus)
      elseif peripheral.call(name, "isOn") then
        ids[#ids + 1] = id
      else
        notes[#notes + 1] = "turtle " .. id .. " eteinte"
      end
    end
    if #ids == 0 then return end
    if not remote.isOpen() then return setInfo("Pas de modem : ouvrieres ignorees") end
    updateStatus('Detection des turtles ouvrieres')
    local before = probeWorkers(ids)
    local workers = {}
    for _, id in ipairs(ids) do
      if before[id] then
        workers[#workers + 1] = id
      else
        notes[#notes + 1] = "turtle " .. id .. " sans worker.lua"
      end
    end
    for _, chest in ipairs(chests) do
      if #workers == 0 then break end
      if not used[chest] then
        updateStatus('Tampon des ouvrieres : ' .. short(chest))
        if storage.export(MARKER, 1, chest) == 0 then
          missing = MARKER
          return
        end
        for id, items in pairs(probeWorkers(workers)) do
          if countMarker(items) > countMarker(before[id]) then
            table.insert(detected.stations.turtle, { worker = id, buffer = chest })
            used[chest] = true
            for i, w in ipairs(workers) do
              if w == id then table.remove(workers, i) break end
            end
            updateNumber()
            break
          end
        end
        storage.empty(chest)
      end
    end
    for _, id in ipairs(workers) do
      notes[#notes + 1] = "ouvriere " .. id .. " : tampon hors reseau"
    end
    if #notes > 0 then setInfo(table.concat(notes, ", ")) end
  end

  -- Coffres qu'aucune étape n'a attribués : comptés à l'enregistrement, nommés ici
  -- (la page Postes les montre aussi, en jaune)
  local function handleRemaining(chests)
    unused = chests
    if not chests[1] then return end
    local names = {}
    for i, n in ipairs(chests) do names[i] = short(n) end
    setInfo("Sans role : " .. table.concat(names, ", "))
  end

  function startDetection()
    -- Un nouveau scan repart de zéro : pas de postes en double. En plus : les postes
    -- connus restent, leurs blocs sont pris (assigned) et les nouveaux s'ajoutent
    if not additive then
      for _, m in ipairs(MACHINES) do detected.stations[m] = {} end
    end
    unused = {}
    updateNumber()
    setQuestion('')
    -- Tous les items de test doivent être là avant de commencer
    missing = nil
    local needed = { DEPOT_ITEM }
    for _, test in ipairs(TESTS) do
      needed[#needed + 1] = test.item
      for _, data in pairs(test.results) do
        if data.confirm then needed[#needed + 1] = data.confirm.item end
      end
    end
    if peripherals['create:basin'] then
      for _, list in ipairs({ MIX_ITEMS, HEATED_ITEMS, COMPACT_ITEMS, HEATED_COMPACT_ITEMS }) do
        for _, item in ipairs(list) do needed[#needed + 1] = item end
      end
    end
    if peripherals['create:depot'] and peripherals['create:deployer'] then
      needed[#needed + 1] = DEPLOY_ITEM
      needed[#needed + 1] = DEPLOY_HELD
    end
    -- Quantité de chaque item : un item listé deux fois (2 flint) en demande 2
    local counts, order = {}, {}
    for _, item in ipairs(needed) do
      if not counts[item] then order[#order + 1] = item end
      counts[item] = (counts[item] or 0) + 1
    end
    if peripherals['create:basin'] then
      order[#order + 1] = COMPACT_FLUID
      counts[COMPACT_FLUID] = COMPACT_MB -- en mB : les fluides sont comptés avec les items
    end
    storage.scan()
    for _, item in ipairs(order) do
      if storage.count(item) < counts[item] then
        missing = item
        return
      end
    end
    -- Coffres attribués, partagé par toutes les étapes
    local used = assigned()
    handleStorages(peripherals['minecraft:chest'], used)
    if missing then return end
    handleDepot(peripherals['create:depot'], used)
    if missing then return end
    handleBasin(peripherals['create:basin'], peripherals['create:deployer'], used)
    if missing then return end
    -- Après les basins : les deployers des blaze burners sont déjà pris
    handleDeployer(peripherals['create:depot'], peripherals['create:deployer'], used)
    if missing then return end
    local remaining = {}
    for _, name in ipairs(peripherals['minecraft:chest']) do
      if not used[name] then table.insert(remaining, name) end
    end
    -- Après les machines : le MARKER ne doit pas tomber dans l'entrée d'une machine
    handleWorkers(remaining, used)
    if missing then return end
    local left = {}
    for _, name in ipairs(remaining) do
      if not used[name] then table.insert(left, name) end
    end
    handleRemaining(left)
  end

  ---------------------------------------------------------------- Enregistrement
  -- Champs que la détection ne trouve pas (timeout, idle, retries, fuel...) : repris de
  -- l'ancien poste qui avait les mêmes blocs. Les blocs et la chaleur viennent du scan
  local DETECTED_KEYS = { heat = true, worker = true }
  for _, key in ipairs(STATION_KEYS) do DETECTED_KEYS[key] = true end
  local function keepSettings(old, station)
    if old and old[1] == nil and next(old) then old = { old } end -- un seul poste, sans liste
    for _, o in ipairs(old or {}) do
      if o.name == station.name and o.inlet == station.inlet and o.worker == station.worker then
        for k, v in pairs(o) do
          if not DETECTED_KEYS[k] and station[k] == nil then station[k] = v end
        end
        return
      end
    end
  end

  -- Écrit le résultat dans config.json. Les réglages déjà présents dans le fichier
  -- (fuel, monitorScale...) sont gardés. Les machines que la détection sait trouver
  -- (MACHINES) sont remplacées : un poste démonté disparaît de la configuration ; les
  -- autres (emptying, écrits à la main) ne changent pas
  function saveConfig()
    config.edit(function(out)
      for _, key in ipairs({ "storage", "buffer", "bufferDir", "trash" }) do
        out[key] = detected[key]
      end
      out.output = nil -- ancienne clé, remplacée par outputs
      out.outputs = detected.outputs[1] and detected.outputs or nil
      out.stations = out.stations or {}
      for _, m in ipairs(MACHINES) do
        local list = detected.stations[m]
        for _, station in ipairs(list) do keepSettings(out.stations[m], station) end
        out.stations[m] = list[1] and list or nil
      end
    end)
  end

  -- Détection en plus : la configuration enregistrée (config.json, pas la mémoire où
  -- les postes ont des champs de travail) devient le point de départ
  function loadCurrent()
    reset()
    additive = true
    local data = {}
    local path = config.dataDir .. "/config.json"
    if fs.exists(path) then
      local f = fs.open(path, "r")
      data = textutils.unserializeJSON(f.readAll()) or {}
      f.close()
    end
    for _, key in ipairs({ "buffer", "bufferDir", "trash" }) do detected[key] = data[key] end
    detected.outputs = data.outputs or { data.output }
    setStorage(data.storage)
    for _, m in ipairs(MACHINES) do
      local list = (data.stations or {})[m]
      if type(list) ~= "table" or next(list) == nil then list = {}
      elseif list[1] == nil then list = { list } end -- un seul poste, sans liste
      detected.stations[m] = list
    end
    baseline = countFound()
    updateNumber()
  end

  function reset()
    detected = newConfig()
    outCandidate, unused = nil, {}
    additive, baseline = false, 0
    config.storage = nil
    updateNumber()
  end

  function update()
    status.text = ""
    setLines(infoLines, "")
    local err = detectPeripherals(true)
    if err then return fail(err) end
    if not DEV_CONFIG then return ask(config.scanned and 'rerun' or 'mainStorage') end
    for key, value in pairs(DEV_CONFIG) do detected[key] = value end
        setStorage(detected.storage)
    local ok, scanErr = pcall(startDetection)
    if not ok then return fail(tostring(scanErr)) end
    ask(missing and 'missingItem' or 'save')
  end

  -- Relancée depuis la page Postes : on repart de zéro, la configuration actuelle est
  -- gardée pour « Annuler »
  page.onShow = function()
    savedStorage = config.storage
    reset()
    config.storage = savedStorage
    update()
  end

  return {
    page = page,
  }
end
