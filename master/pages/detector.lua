-- pages/detector.lua: first start, network detection
-- On-screen questions for the storage, the buffer, the outputs and the trash, then
-- detection of the machines by sending test items (flow machines: an inlet chest ->
-- machine -> an output chest; depots, basins, deployers, workers). The result is
-- saved in config.json.

local ui = require("ui")
local config = require("config")
local storage = require("storage")
local remote = require("remote")
local burner = require("machines.burner")

-- Test setup: these answers are taken as is and the machine scan starts right away.
-- nil to ask the questions
--[[local DEV_CONFIG = {
  storage = { 'storagedrawers:controller_slave_1' },
  trash = 'minecraft:chest_27',
  outputs = { 'minecraft:chest_26' },
  buffer = 'minecraft:chest_1',
}]]--
local DEV_CONFIG = nil

-- Items sent into each chest, in this order (a list: pairs does not guarantee any
-- order), with for each machine the expected result. A result must be certain and
-- specific to its machine, otherwise another station could be taken for it.
-- confirm: 2nd item when the result can come from another machine; it must give
-- confirm.output in the same output chest
local TESTS = {
  -- First: the millstone refuses items without a recipe, which then stay stuck in
  -- the chute in front of it; the fans and the saw let everything through.
  -- Washing gravel sometimes gives 1 flint: wheat (flour) confirms the milling
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
local INTAKE_DELAY = 1     -- seconds before checking whether the machine took the item
local OUTPUT_TIMEOUT = 9   -- max seconds to see the result arrive (fans: 7.5 s + travel)
local CHECK_INTERVAL = 0.5 -- seconds between two readings of the chests while waiting
local PROBE_TIMEOUT = 2    -- max seconds for the workers' reply
-- Depot test: press (DEPOT_ITEM -> DEPOT_PRESSED) or water spout (-> DEPOT_FILLED)
local DEPOT_ITEM, DEPOT_PRESSED, DEPOT_FILLED = "minecraft:dirt", "minecraft:dirt_path", "minecraft:grass_block"
local SPOUT_WATER = 500    -- mB of water sent to the tested spout
local DEPOT_TIMEOUT = 3    -- max seconds for a press or a spout to transform the item
-- Basin test (Create recipes): mixer without heat, then heated
local MIX_ITEMS, MIX_RESULT = { "minecraft:andesite", "minecraft:iron_nugget" }, "create:andesite_alloy"
local HEATED_ITEMS, HEATED_RESULT = { "minecraft:copper_ingot", "create:zinc_ingot" }, "create:brass_ingot"
local MIX_TIMEOUT = 10     -- max seconds for a mixer to make its recipe
-- Test of the basins under a press (compacting): create:compacting/andesite_from_flint,
-- 2 flint + 1 gravel + 100 mB of lava, without heat, and that no mixer makes
local COMPACT_ITEMS = { "minecraft:flint", "minecraft:flint", "minecraft:gravel" }
local COMPACT_FLUID, COMPACT_MB, COMPACT_RESULT = "minecraft:lava", 100, "minecraft:andesite"
-- Heated press: createdeco:compacting/industrial_iron_ingot (Create Deco; without that
-- mod, the burners of the presses are not found)
local HEATED_COMPACT_ITEMS, HEATED_COMPACT_RESULT = { "minecraft:iron_ingot" }, "createdeco:industrial_iron_ingot"
-- Deployer test (Create recipe): DEPLOY_ITEM on the depot, DEPLOY_HELD in hand
local DEPLOY_ITEM, DEPLOY_HELD, DEPLOY_RESULT = "create:cogwheel", "minecraft:oak_planks", "create:large_cogwheel"
local MARKER = "minecraft:cobblestone" -- item put into a chest to find a worker's buffer
-- Saw of a saw station: with SAW_FILTER (no recipe of SAW_ITEM gives it) the right saw
-- lets SAW_ITEM through unchanged instead of making SAW_RESULT
local SAW_ITEM, SAW_RESULT, SAW_FILTER = "minecraft:oak_log", "minecraft:stripped_oak_log", "minecraft:cobblestone"

-- Blank configuration: the buffer is always below the turtle
local function newConfig()
  local c = { bufferDir = "down", outputs = {}, stations = {} }
  for _, m in ipairs(MACHINES) do c.stations[m] = {} end
  return c
end

-- "minecraft:chest_12" -> "chest_12", for the messages
local function short(name)
  return (name:gsub("^minecraft:", ""))
end

return function(ctx)
  local app = ctx.app
  local W, H = app.w, app.h
  local page = ui.Page()
  local detected = newConfig()
  local peripherals = {}

  -- Defined below; declared here for the handlers of the tree
  local setInfo, detectMainStorages, searchChest, searchChests
  local startDetection, saveConfig, countFound, reset, detectDepot

  -- storage.lua takes its inventories from config.storage: without config.json, it
  -- would take the whole network (depots, machine inlets...)
  local function setStorage(list)
    detected.storage = list
    config.storage = list
  end
  local missing -- TESTS item missing from the storage: the detection stopped
  local outCandidate -- chest found for the next output, not confirmed yet
  local unused = {} -- network chests that no step assigned
  local savedStorage -- config.storage before the detection, put back if it is cancelled
  -- "Additional" detection (run again from the auto-crafter): storage, buffer, outputs,
  -- trash and stations of config.json are kept, only the free blocks are tested.
  -- baseline: number of stations already configured, to count only the new ones
  local additive, baseline = false, 0
  local loadCurrent -- defined below

  -- Run again from the Stations page (config.json exists): it is possible to go back
  -- without changing anything. On the first start, quitting stops the program
  local function quit()
    if not config.scanned then return app:stop() end
    config.storage = savedStorage
    app:show("stations")
  end
  local cancel = { label = "Cancel", run = function() quit() end,
                   when = function() return config.scanned end }

  -- Question tree: each answer has an optional handler and the next question.
  -- text, label and next can be functions (evaluated on display / on click)
  local tree = {
    -- Run again from the auto-crafter (config.json exists)
    rerun = {
      text = "Start over, or only look for machines besides the known ones?",
      answers = {
        { label = "Additional", run = function() loadCurrent() end, next = "scan" },
        { label = "Everything", run = function() reset() end, next = "mainStorage" },
        cancel,
      },
    },
    mainStorage = {
      text = "Is the main storage made of chests or of a drawer controller?",
      answers = {
        { label = "Chest", next = "mainStorageWhich" },
        { label = "Drawer", run = function() detectMainStorages() end,
          next = function() return detected.storage and "mainStorageDrawer" or "mainStorage" end },
        cancel,
      },
    },
    mainStorageDrawer = {
      text = function() return "Is it the drawer " .. detected.storage[1] .. '?' end,
      answers = {
        { label = "Confirm", next = "bufferWhich"},
        { label = "Back", run = function() setStorage(nil) end, next = "mainStorage" },
      },
    },
    mainStorageWhich = {
      text = "Empty the chests and put 1 cobblestone in each storage chest",
      answers = {
        { label = "Done", run = function() setStorage(searchChests('minecraft:cobblestone')) end,
          next = function() return #detected.storage > 0 and "mainStorageConfirm" or "mainStorageWhich" end },
        { label = "Back", next = "mainStorage" },
      },
    },
    mainStorageConfirm = {
      text = function() return "Are these the chests " .. table.concat(detected.storage, ", ") .. '?' end,
      answers = {
        { label = "Confirm", next = "bufferWhich", run = function()
          -- The marked cobblestones join the first storage chest
          for index = 2, #detected.storage do
            storage.empty(detected.storage[index])
          end
        end },
        { label = "Back", run = function() setStorage(nil) end, next = "mainStorageWhich" },
      },
    },
    bufferWhich = {
      text = "Empty the chests and put 1 cobblestone in the buffer",
      answers = {
        { label = "Done", run = function()
          detected.buffer = searchChest('minecraft:cobblestone')
          if not detected.buffer then
            -- Cobble below but in no chest of the network: buffer not connected
            if peripheral.isPresent("bottom") and storage.has("bottom", 'minecraft:cobblestone') then
              setInfo("Buffer off the network: turn its modem on")
            else
              setInfo("No cobblestone in the buffer")
            end
          end
        end,
          next = function() return detected.buffer and "bufferConfirm" or "bufferWhich" end },
        { label = "Back", next = "mainStorage" },
      },
    },
    bufferConfirm = {
      text = function() return "Is it the chest " .. detected.buffer .. '?' end,
      answers = {
        { label = "Confirm", next = "outWhich", run = function() storage.empty(detected.buffer) end },
        { label = "Back", run = function() detected.buffer = nil end, next = "bufferWhich" },
      },
    },
    -- Several possible outputs: each order chooses its own on the main screen
    outWhich = {
      text = function()
        return "Empty the chests and put 1 cobblestone in " ..
          (detected.outputs[1] and "the next output" or "the output")
      end,
      answers = {
        { label = "Done", run = function() outCandidate = searchChest('minecraft:cobblestone') end,
          next = function() return outCandidate and "outConfirm" or "outWhich" end },
        { label = "Back", run = function() detected.outputs = {} end, next = "bufferWhich" },
      },
    },
    outConfirm = {
      text = function() return "Is it the chest " .. outCandidate .. '?' end,
      answers = {
        { label = "Confirm", next = "outMore", run = function()
          storage.empty(outCandidate)
          table.insert(detected.outputs, outCandidate)
          outCandidate = nil
        end },
        { label = "Back", run = function() outCandidate = nil end, next = "outWhich" },
      },
    },
    outMore = {
      text = function()
        local names = {}
        for i, n in ipairs(detected.outputs) do names[i] = short(n) end
        return "Outputs: " .. table.concat(names, ", ") .. ". Another output?"
      end,
      answers = {
        { label = "Yes", next = "outWhich" },
        { label = "No", next = "trash" },
      },
    },
    trash = {
      text = "Does the network have a trash?",
      answers = {
        { label = "Yes", next = "trashWhich" },
        { label = "No", run = function() detected.trash = nil end, next = "scan" },
      },
    },
    trashWhich = {
      text = "Put a cobblestone in the trash and turn its mechanism off",
      answers = {
        { label = "Done", run = function() detected.trash = searchChest('minecraft:cobblestone') end,
          next = function() return detected.trash and "trashConfirm" or "trashWhich" end },
        { label = "Back", next = "trash" },
      },
    },
    trashConfirm = {
      text = function() return "Is it the chest " .. detected.trash .. '?' end,
      answers = {
        { label = "Confirm", next = "scan", run = function() storage.empty(detected.trash) end },
        { label = "Back", run = function() detected.trash = nil end, next = "trashWhich" },
      },
    },
    scan = {
      text = "The machine detection is about to start",
      answers = {
        { label = "Go", run = function() startDetection() end,
          next = function() return missing and "missingItem" or "save" end },
        cancel,
      },
    },
    missingItem = {
      text = function() return "Not enough " .. short(missing) .. " in the storage. Add some, then retry" end,
      answers = {
        { label = "Retry", next = "scan" },
        { label = "Quit", run = function() quit() end },
      },
    },
    save = {
      text = function()
        local extra = unused[1] and (", " .. #unused .. " chest(s) without a role") or ""
        local found = additive and ((countFound() - baseline) .. " new machine(s)")
                      or (countFound() .. " machine(s) detected")
        return found .. extra .. ". Save the configuration?"
      end,
      answers = {
        { label = "Save", run = function() saveConfig() end, next = "reboot" },
        { label = "Start over", run = function() reset() end, next = "mainStorage" },
        cancel,
      },
    },
    reboot = {
      text = "Configuration saved. Restart to run the auto-crafter",
      answers = {
        { label = "Restart", run = function() os.reboot() end },
      },
    },
  }

  -- Layout: title, info (INFO_LINES lines), question (QUESTION_LINES lines), the
  -- buttons, and at the bottom the status and the number of machines
  local INFO_Y, INFO_LINES = 3, 2
  local QUESTION_Y, QUESTION_LINES = 6, 3
  page:add(ui.Label{
    x = 1, y = 1, w = W, text = "NETWORK DETECTION", align = "center",
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
  -- Three answers at most, on one line; the x position is computed in setButtons
  local BUTTON_W, BUTTON_GAP = 11, 2
  local buttons = {}
  for i = 1, 3 do
    buttons[i] = page:add(ui.Button{
      x = 1, y = QUESTION_Y + QUESTION_LINES + 1, w = BUTTON_W, hidden = true,
    })
  end

  ---------------------------------------------------------------- Display
  -- The scan blocks the app's loop: each text change redraws the screen.
  -- No print: it would write over the UI when it is on the terminal

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
    number.text = n > 0 and 'Machines found: ' .. n or "No machine found"
    app:render()
  end

  -- A value can be a string or a function that returns it
  local function resolve(v)
    if type(v) == "function" then return v() end
    return v
  end

  -- Cuts a text into lines of at most `width` characters, at the spaces
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

  -- Spreads a text over one-line labels; what does not fit is lost
  local function setLines(labels, text)
    local lines = wrap(text or "", W)
    for i, l in ipairs(labels) do l.text = lines[i] or "" end
  end

  local function setQuestion(text) setLines(questionLines, text) end

  function setInfo(text)
    setLines(infoLines, text)
    app:render()
  end

  -- choices: { { label, onClick }, ... }; the displayed buttons are centered, the
  -- extra ones are hidden
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

  -- Shows the error instead of the question, with a way to retry or quit
  local function fail(msg)
    status.text = "Error"
    setLines(infoLines, "")
    setQuestion(msg)
    setButtons({
      { label = "Retry", onClick = function() update() end },
      { label = "Quit", onClick = function() quit() end },
    })
    app:render()
  end

  -- During a handler the buttons are hidden: the screen shows that it is working and
  -- a second click cannot start the action again
  local function choose(a)
    if a.run then
      setLines(infoLines, "") -- the handler writes its result there if it has one
      setButtons({})
      updateStatus("Updating ...")
      local ok, err = pcall(a.run)
      if not ok then return fail(tostring(err)) end
      updateStatus("")
    end
    local ok, nextId = pcall(resolve, a.next)
    if not ok then return fail(tostring(nextId)) end
    if nextId then
      ask(nextId)
    else
      setQuestion("Detection finished")
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

  ---------------------------------------------------------------- Network
  -- Sorts the network peripherals by type into `peripherals`. With withTurtle, returns
  -- an error message if the setup around the turtle is wrong
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
        return "The turtle needs exactly one chest next to it: the buffer, below"
      end
    end
  end

  -- Chests already assigned (storage, buffer, outputs, trash)
  local function assigned()
    local used = {}
    for _, name in ipairs(detected.storage or {}) do used[name] = true end
    for _, o in ipairs(detected.outputs) do used[type(o) == "table" and o.name or o] = true end
    if outCandidate then used[outCandidate] = true end
    for _, key in ipairs({ "buffer", "trash" }) do
      if detected[key] then used[detected[key]] = true end
    end
    -- Blocks of the stations already known (additional detection): neither tested nor emptied
    for _, list in pairs(detected.stations) do
      for _, station in ipairs(list) do
        for _, key in ipairs({ "inlet", "output", "name", "spout", "deployer", "burner", "buffer", "saw" }) do
          if station[key] then used[station[key]] = true end
        end
      end
    end
    return used
  end

  -- Unassigned chests that hold itemName
  function searchChests(itemName)
    -- Reads the network again: a modem may have been turned on since the page opened
    detectPeripherals(false)
    local used, chests = assigned(), {}
    for _, name in ipairs(peripherals['minecraft:chest']) do
      if not used[name] and storage.has(name, itemName) then
        table.insert(chests, name)
      end
    end
    if #chests == 0 then setInfo("No chest of the network with " .. itemName) end
    return chests
  end

  -- First unassigned chest that holds itemName
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
    setInfo(detected.storage and "" or "No single drawer controller found")
  end

  -- Empties a chest into the trash, or into the storage if there is none
  local function trashChest(chest)
    if detected.trash then storage.moveAll(chest, detected.trash) else storage.empty(chest) end
  end

  ---------------------------------------------------------------- Machines
  -- Station fields that are network blocks, in the order of the messages
  local STATION_KEYS = { "inlet", "output", "name", "spout", "deployer", "burner", "saw" }

  -- Adds a station to machineName: { inlet, output } (flow), { name } (press),
  -- { name, spout } (spout)... Its blocks are taken and its inventories emptied
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
    setInfo(machineName .. " machine found ( " .. table.concat(names, " => ") .. " )")
    table.insert(detected.stations[machineName], station)
    updateNumber()
  end

  -- Count of each item in an inventory: { [name] = total }
  local function totals(name)
    local t = {}
    for _, item in pairs(peripheral.wrap(name).list()) do
      t[item.name] = (t[item.name] or 0) + item.count
    end
    return t
  end

  -- Contents of the unassigned chests other than the inlet: { [chest] = totals }.
  -- Read before sending, then while waiting: only the increase counts, what was left
  -- in an output chest by a previous scan is ignored
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

  -- Checks every CHECK_INTERVAL s, OUTPUT_TIMEOUT s at most (real time: reading the
  -- chests counts in the wait), whether a chest received one of the expected results:
  -- returns the machine and that chest. Gives up as soon as the inlet chest is no
  -- longer empty (item given back or refused) or itemName comes out unchanged elsewhere
  -- (the machine does not process it: that chest is emptied)
  local function waitOutput(inlet, itemName, results, used, storages, before)
    local inv = peripheral.wrap(inlet)
    local start = os.clock()
    while os.clock() - start < OUTPUT_TIMEOUT do
      sleep(CHECK_INTERVAL)
      setInfo(("Waiting for the result ... %.1f/%g s"):format(os.clock() - start, OUTPUT_TIMEOUT))
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

  -- Sends confirm.item into inlet; true if it gives confirm.output in output, false
  -- if it arrives unchanged (not processed) or if nothing arrives in time
  local function confirmOutput(inlet, output, confirm)
    local before = { [output] = totals(output) }
    if storage.export(confirm.item, 1, inlet) == 0 then
      missing = confirm.item
      return false
    end
    local start = os.clock()
    while os.clock() - start < OUTPUT_TIMEOUT do
      sleep(CHECK_INTERVAL)
      setInfo(("Confirming with %s ... %.1f/%g s"):format(short(confirm.item), os.clock() - start, OUTPUT_TIMEOUT))
      local now = { [output] = totals(output) }
      if gained(before, now, output, confirm.output) > 0 then return true end
      if gained(before, now, output, confirm.item) > 0 then return false end
    end
    return false
  end

  -- Finds the mechanical saw (with a modem and the AutoCrafter Link mod: setFilter) of a
  -- saw station: each free saw in turn gets SAW_FILTER, then a SAW_ITEM goes into the
  -- inlet; the saw that lets it through unchanged (or holds it) is the station's.
  -- The filter is cleared after each try. Without a saw found, station.saw stays nil
  local function findSaw(station, used)
    for _, saw in ipairs(peripherals['create:saw'] or {}) do
      if not used[saw] and pcall(peripheral.call, saw, "setFilter", SAW_FILTER) then
        updateStatus('Looking for the saw of ' .. short(station.inlet) .. ': ' .. short(saw))
        local before = { [station.output] = totals(station.output) }
        if storage.export(SAW_ITEM, 1, station.inlet) == 0 then
          pcall(peripheral.call, saw, "setFilter")
          missing = SAW_ITEM
          return
        end
        local found, start = false, os.clock()
        while os.clock() - start < OUTPUT_TIMEOUT do
          sleep(CHECK_INTERVAL)
          local now = { [station.output] = totals(station.output) }
          if gained(before, now, station.output, SAW_ITEM) > 0 then found = true break end
          if gained(before, now, station.output, SAW_RESULT) > 0 then break end
          local ok, held = pcall(peripheral.call, saw, "list")
          if ok and held and next(held) then found = true break end
        end
        pcall(peripheral.call, saw, "setFilter")
        -- The log (or what the saw still holds) goes back to storage
        sleep(CHECK_INTERVAL)
        for _, inv in ipairs({ station.inlet, station.output, saw }) do storage.empty(inv) end
        if found then
          station.saw = saw
          used[saw] = true
          setInfo("Saw found: " .. short(station.inlet) .. " => " .. short(saw))
          return
        end
      end
    end
  end

  -- Sends each item of TESTS into the chest until the machine it feeds is found;
  -- true if found. A chest that keeps the item feeds nothing (the first one, gravel,
  -- goes through everything): it is emptied and the tests stop there
  local function testChest(inlet, used, storages)
    local inv = peripheral.wrap(inlet)
    for _, test in ipairs(TESTS) do
      updateStatus('Testing ' .. short(inlet) .. ' with ' .. short(test.item))
      local before = snapshot(inlet, used, storages)
      if storage.export(test.item, 1, inlet) == 0 then
        missing = test.item -- used up during the scan: the detection stops
        return false
      else
        sleep(INTAKE_DELAY)
        if next(inv.list()) ~= nil then
          updateStatus('Chest unchanged, cleaning ...')
          storage.empty(inlet)
          return false
        else
          local machineName, output = waitOutput(inlet, test.item, test.results, used, storages, before)
          local confirm = machineName and test.results[machineName].confirm
          if confirm and not confirmOutput(inlet, output, confirm) then
            if missing then return false end
            storage.empty(output) -- result of another machine: the tests go on
            machineName = nil
          end
          if machineName then
            addToDetected(machineName, { inlet = inlet, output = output }, used)
            return true
          end
          if next(inv.list()) ~= nil then
            updateStatus('Item back in the chest, cleaning ...')
            storage.empty(inlet)
          end
        end
      end
    end
    return false
  end

  -- used: chests already assigned, or taken by a machine; skipped, and filled in along the way
  local function handleStorages(storages, used)
    updateStatus('Detecting the chests')
    for _, name in ipairs(storages) do
      if not used[name] then
        testChest(name, used, storages)
        if missing then return end
      end
    end
  end

  -- Checks every second whether itemName is on the depot, DEPOT_TIMEOUT s at most
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

  -- A DEPOT_ITEM on the depot: press if it becomes DEPOT_PRESSED, else each free spout
  -- gets SPOUT_WATER mB of water, and the one that makes DEPOT_FILLED is above it
  function detectDepot(depot, used)
    updateStatus('Testing ' .. short(depot))
    storage.empty(depot) -- leftovers of a failed try
    if storage.export(DEPOT_ITEM, 1, depot) == 0 then
      missing = DEPOT_ITEM -- used up during the scan: the detection stops
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
          setInfo("Not enough water (" .. SPOUT_WATER .. " mB): spouts skipped")
          break
        end
        local filled = waitItem(depot, DEPOT_FILLED)
        -- The unused water goes back to the tanks, whether it is the right spout or not
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
  -- Sends 1 of each item of `items` into target; false (and missing) if one is missing
  local function sendEach(items, target)
    for _, item in ipairs(items) do
      if storage.export(item, 1, target) == 0 then
        -- Still in stock: target refuses the item, it is not missing
        storage.scan()
        if storage.count(item) > 0 then
          error(short(target) .. " refuses " .. short(item), 0)
        end
        missing = item -- used up during the scan: the detection stops
        return false
      end
    end
    return true
  end

  -- Checks the basins of `list` every second, MIX_TIMEOUT s at most; stops as soon
  -- as `count` of them are done (done(basin) true). Returns those that are done
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

  -- Empties the items and fluids of a basin into the storage
  local function cleanBasin(basin)
    storage.empty(basin)
    storage.importFluids(basin)
  end

  -- Gives the deployer 1 fuel of level `heat` (burner.fuels): true if it gave it to a
  -- blaze burner (empty hand), false otherwise (taken back), nil if there is no fuel
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

  -- Free basins that make `result` after send(basin) (sends the test items), then emptied
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
    updateStatus('Looking for ' .. label)
    local found = waitBasins(tested, function(b) return storage.has(b, result) end)
    for _, basin in ipairs(tested) do cleanBasin(basin) end
    return found
  end

  -- Blaze burners under the basins of `stations` ({ [basin] = station }). Each basin gets
  -- its heated test recipe (heatTest[basin] = { items, result }), then each free
  -- deployer gets a fuel, one at a time: if it gives it away, it is a burner, and the
  -- basin that then makes its result is its own. A single search for mixers and
  -- presses: a burner lit by a deployer during the search for one machine would be seen
  -- "already lit" by the other. A blaze burner does heated and superheated: the station
  -- is marked superheated. Returns the remarks, or nil if an item is missing
  local function findBurners(stations, heatTest, deployers, used)
    local notes, cold = {}, {}
    for basin in pairs(stations) do
      if not sendEach(heatTest[basin].items, basin) then return nil end
      cold[#cold + 1] = basin
    end
    if #cold == 0 then return notes end
    updateStatus('Looking for blaze burners')
    local heated = function(b) return storage.has(b, heatTest[b].result) end
    -- Burner already lit before the scan: there is no way to know which deployer feeds it
    for _, basin in ipairs(waitBasins(cold, heated, 1)) do
      stations[basin].heat = "superheated"
      remove(cold, basin)
      notes[#notes + 1] = short(basin) .. ": burner already lit, deployer unknown"
    end
    for _, deployer in ipairs(deployers or {}) do
      if #cold == 0 then break end
      if not used[deployer] then
        local fed = feedBurner(deployer, "heated")
        if fed == nil then
          notes[#notes + 1] = "no heated fuel"
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

  -- 1. MIX_ITEMS in every free basin: those that make MIX_RESULT have a mixer.
  -- 2. COMPACT_ITEMS and COMPACT_MB mB of COMPACT_FLUID in the basins still free:
  --    those that make COMPACT_RESULT have a press above (compacting).
  -- 3. Burners of the mixers (HEATED_ITEMS -> HEATED_RESULT) and of the presses
  --    (HEATED_COMPACT_ITEMS -> HEATED_COMPACT_RESULT), together (findBurners).
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
        missing = COMPACT_FLUID -- used up during the scan: the detection stops
        return false
      end
      return true
    end, COMPACT_RESULT, "presses on basins")
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
  -- DEPLOY_ITEM on each free depot, then each free deployer gets DEPLOY_HELD, one at a
  -- time: the depot that then makes DEPLOY_RESULT is under that deployer.
  -- The deployer must be in "use" mode (right click)
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
        updateStatus('Testing ' .. short(deployer))
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
        storage.empty(deployer) -- plank not used: not above a free depot
        if found then
          remove(free, found)
          addToDetected('deploying', { name = found, deployer = deployer }, used)
        end
      end
    end
    for _, depot in ipairs(free) do storage.empty(depot) end
  end

  ---------------------------------------------------------------- Workers
  -- Asks each worker of `ids` for its buffer; { [id] = buffer slots } for those that
  -- replied (no reply: worker.lua is not running)
  -- The replies are read here with rednet.receive, not by remote.listen: with
  -- DEV_CONFIG, the detection runs in app:show, before main.lua starts listen
  local function probeWorkers(ids)
    local jobs = {}
    for _, id in ipairs(ids) do jobs[id] = remote.send(id, { kind = "probe" }) end
    local replies, deadline = {}, os.clock() + PROBE_TIMEOUT
    while next(jobs) and os.clock() < deadline do
      local from, msg = rednet.receive(remote.PROTOCOL, deadline - os.clock())
      if from and jobs[from] and type(msg) == "table" and msg.job == jobs[from] then
        replies[from] = msg.items or {}
        remote.take(msg.job, from) -- copy kept by listen if it is running
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

  -- The network turtles that reply are workers. Their buffer is found by putting
  -- 1 MARKER into each free chest: it is the one the worker sees arrive
  local function handleWorkers(chests, used)
    local ids, notes, known = {}, {}, {}
    for _, w in ipairs(detected.stations.turtle) do known[w.worker] = true end
    for _, name in ipairs(peripherals['turtle'] or {}) do
      local id = peripheral.call(name, "getID")
      if known[id] then
        -- worker already configured (additional detection)
      elseif peripheral.call(name, "isOn") then
        ids[#ids + 1] = id
      else
        notes[#notes + 1] = "turtle " .. id .. " off"
      end
    end
    if #ids == 0 then return end
    if not remote.isOpen() then return setInfo("No modem: workers skipped") end
    updateStatus('Detecting the worker turtles')
    local before = probeWorkers(ids)
    local workers = {}
    for _, id in ipairs(ids) do
      if before[id] then
        workers[#workers + 1] = id
      else
        notes[#notes + 1] = "turtle " .. id .. " without worker.lua"
      end
    end
    for _, chest in ipairs(chests) do
      if #workers == 0 then break end
      if not used[chest] then
        updateStatus('Worker buffers: ' .. short(chest))
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
      notes[#notes + 1] = "worker " .. id .. ": buffer off the network"
    end
    if #notes > 0 then setInfo(table.concat(notes, ", ")) end
  end

  -- Chests that no step assigned: counted when saving, named here
  -- (the Stations page shows them too, in yellow)
  local function handleRemaining(chests)
    unused = chests
    if not chests[1] then return end
    local names = {}
    for i, n in ipairs(chests) do names[i] = short(n) end
    setInfo("No role: " .. table.concat(names, ", "))
  end

  function startDetection()
    -- A new scan starts from scratch: no duplicate stations. Additional: the known
    -- stations stay, their blocks are taken (assigned) and the new ones are added
    if not additive then
      for _, m in ipairs(MACHINES) do detected.stations[m] = {} end
    end
    unused = {}
    updateNumber()
    setQuestion('')
    -- Every test item must be there before starting
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
    -- Count of each item: an item listed twice (2 flint) asks for 2
    local counts, order = {}, {}
    for _, item in ipairs(needed) do
      if not counts[item] then order[#order + 1] = item end
      counts[item] = (counts[item] or 0) + 1
    end
    if peripherals['create:basin'] then
      order[#order + 1] = COMPACT_FLUID
      counts[COMPACT_FLUID] = COMPACT_MB -- in mB: fluids are counted with the items
    end
    storage.scan()
    for _, item in ipairs(order) do
      if storage.count(item) < counts[item] then
        missing = item
        return
      end
    end
    -- Assigned chests, shared by every step
    local used = assigned()
    handleStorages(peripherals['minecraft:chest'], used)
    if missing then return end
    -- Saws of the saw stations, also those of an earlier scan (saw modem added since)
    for _, station in ipairs(detected.stations.sawing) do
      if not station.saw then findSaw(station, used) end
      if missing then return end
    end
    handleDepot(peripherals['create:depot'], used)
    if missing then return end
    handleBasin(peripherals['create:basin'], peripherals['create:deployer'], used)
    if missing then return end
    -- After the basins: the deployers of the blaze burners are already taken
    handleDeployer(peripherals['create:depot'], peripherals['create:deployer'], used)
    if missing then return end
    local remaining = {}
    for _, name in ipairs(peripherals['minecraft:chest']) do
      if not used[name] then table.insert(remaining, name) end
    end
    -- After the machines: the MARKER must not fall into a machine's inlet
    handleWorkers(remaining, used)
    if missing then return end
    local left = {}
    for _, name in ipairs(remaining) do
      if not used[name] then table.insert(left, name) end
    end
    handleRemaining(left)
  end

  ---------------------------------------------------------------- Saving
  -- Fields the detection does not find (timeout, idle, retries, fuel...): taken from
  -- the old station that had the same blocks. The blocks and the heat come from the scan
  local DETECTED_KEYS = { heat = true, worker = true }
  for _, key in ipairs(STATION_KEYS) do DETECTED_KEYS[key] = true end
  local function keepSettings(old, station)
    if old and old[1] == nil and next(old) then old = { old } end -- a single station, no list
    for _, o in ipairs(old or {}) do
      if o.name == station.name and o.inlet == station.inlet and o.worker == station.worker then
        for k, v in pairs(o) do
          if not DETECTED_KEYS[k] and station[k] == nil then station[k] = v end
        end
        return
      end
    end
  end

  -- Writes the result into config.json. The settings already in the file (fuel,
  -- monitorScale...) are kept. The machines the detection can find (MACHINES) are
  -- replaced: a dismantled station disappears from the configuration; the others
  -- (emptying, written by hand) do not change
  function saveConfig()
    config.edit(function(out)
      for _, key in ipairs({ "storage", "buffer", "bufferDir", "trash" }) do
        out[key] = detected[key]
      end
      out.output = nil -- old key, replaced by outputs
      out.outputs = detected.outputs[1] and detected.outputs or nil
      out.stations = out.stations or {}
      for _, m in ipairs(MACHINES) do
        local list = detected.stations[m]
        for _, station in ipairs(list) do keepSettings(out.stations[m], station) end
        out.stations[m] = list[1] and list or nil
      end
    end)
  end

  -- Additional detection: the saved configuration (config.json, not the memory where
  -- the stations have working fields) becomes the starting point
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
      elseif list[1] == nil then list = { list } end -- a single station, no list
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

  -- Run again from the Stations page: starts from scratch, the current configuration
  -- is kept for "Cancel"
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
