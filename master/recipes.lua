-- recipes.lua: recipe base (pure data, no hardware access)
-- A recipe:
--   { output = { name, count }, grid = { [1..9] = item name }, names = { name -> display },
--     machine = "turtle" }  -- machine optional, "turtle" by default
-- A Create machine recipe replaces grid with inputs:
--   { output = ..., machine = "pressing", inputs = { [name] = count } }
-- Fluids (in mB): fluids = { [name] = mB } as input; a fluid result is written
--   output = { name = "minecraft:lava", count = 50, fluid = true }
-- Deployer: held = the ingredient held by the deployer (also counted in inputs), the
--   others go on the depot
--
-- The AutoCrafter Link mod gives the computer the `recipes` API: the game's recipes are
-- converted to this format on demand. Recipes from recipes.db (written by hand) come
-- before the game's recipes for the same machine.

-- The mod's API, before the module takes its name
local api = type(recipes) == "table" and recipes.getFor and recipes or nil

local recipes = {}

local list = {}
local path
local nameCache = {}
local fluidNames = {}
-- From the mod's API (indexNames does not clear them)
local apiCache = {} -- item -> raw recipes from recipes.getFor
local apiNames, apiFluids = {}, {}

local function indexNames()
  nameCache, fluidNames = {}, {}
  for _, r in ipairs(list) do
    for k, v in pairs(r.names or {}) do nameCache[k] = v end
    for k in pairs(r.fluids or {}) do fluidNames[k] = true end
    if r.output.fluid then fluidNames[r.output.name] = true end
  end
end

-- true if `name` is a fluid of a recipe (amounts in mB)
function recipes.isFluid(name)
  return fluidNames[name] == true or apiFluids[name] == true
end

-- "250 mB Water" or "3 Iron Ingot"
function recipes.amount(n, name)
  return ("%d%s %s"):format(n, recipes.isFluid(name) and " mB" or "", recipes.displayName(name))
end

function recipes.displayName(name)
  if nameCache[name] then return nameCache[name] end
  if apiNames[name] then return apiNames[name] end
  return ((name:match(":(.+)$") or name):gsub("_", " "))
end

local function sort()
  table.sort(list, function(a, b)
    return recipes.displayName(a.output.name):lower()
         < recipes.displayName(b.output.name):lower()
  end)
end

function recipes.load(p)
  path = p
  list = {}
  apiCache = {}
  if fs.exists(path) then
    local f = fs.open(path, "r")
    local data = textutils.unserialize(f.readAll())
    f.close()
    if type(data) == "table" then list = data end
  end
  indexNames()
  sort()
end

function recipes.save()
  local f = fs.open(path, "w")
  f.write(textutils.serialize(list))
  f.close()
end

function recipes.all() return list end

-- Recipes whose name contains q (case insensitive)
function recipes.search(q)
  q = (q or ""):lower()
  if q == "" then return list end
  local out = {}
  for _, r in ipairs(list) do
    if recipes.displayName(r.output.name):lower():find(q, 1, true)
       or r.output.name:find(q, 1, true) then
      out[#out + 1] = r
    end
  end
  return out
end

---------------------------------------------------------------- game recipes

-- Game recipe type -> machine. Create's fans cook with the furnace recipes
-- (blasting) and the smoker recipes (smoking).
local TYPE_MACHINE = {
  ["minecraft:crafting"] = "turtle",
  ["create:pressing"] = "pressing", ["create:mixing"] = "mixing",
  ["create:compacting"] = "compacting", ["create:filling"] = "filling",
  ["create:emptying"] = "emptying", ["create:splashing"] = "washing",
  ["minecraft:smoking"] = "smoking", ["minecraft:smelting"] = "blasting",
  ["minecraft:blasting"] = "blasting", ["create:haunting"] = "haunting",
  ["create:crushing"] = "crushing", ["create:milling"] = "milling",
  ["create:cutting"] = "sawing",
  -- Deployer on a depot: manual application (andesite casing) or deploying
  ["create:item_application"] = "deploying", ["create:deploying"] = "deploying",
}
recipes.TYPE_MACHINE = TYPE_MACHINE

function recipes.hasApi() return api ~= nil end

-- Raw game recipes that produce `name` (kept until the next load)
local function gameRecipes(name)
  if not api then return {} end
  if not apiCache[name] then
    local ok, res = pcall(api.getFor, name)
    apiCache[name] = ok and res or {}
  end
  return apiCache[name]
end

-- `name` has a recipe that uses no item of `avoid` (set of names)
local function hasRecipe(name, avoid)
  for _, r in ipairs(list) do
    if r.output.name == name then
      local free = true
      for _, item in pairs(r.grid or {}) do if avoid[item] then free = false end end
      for item in pairs(r.inputs or {}) do if avoid[item] then free = false end end
      if free then return true end
    end
  end
  for _, raw in ipairs(gameRecipes(name)) do
    if TYPE_MACHINE[raw.type] and raw.output and raw.output.name == name then
      local free = true
      for _, alts in ipairs(raw.ingredients or {}) do
        for _, a in ipairs(alts) do if avoid[a] then free = false end end
      end
      if free then return true end
    end
  end
  return false
end

-- Amount of `name` a game recipe makes from the stock, without sub-crafts and without
-- items of `avoid` (stripped oak log: as many as oak logs at the saw)
local function fromStock(name, avoid, stock)
  local best = 0
  for _, raw in ipairs(gameRecipes(name)) do
    if TYPE_MACHINE[raw.type] and raw.output and raw.output.name == name then
      local times = math.huge
      for _, alts in ipairs(raw.ingredients or {}) do
        if alts[1] then
          local most = 0
          for _, a in ipairs(alts) do
            if not avoid[a] then most = math.max(most, stock[a] or 0) end
          end
          times = math.min(times, most)
        end
      end
      if times ~= math.huge then best = math.max(best, times * (raw.output.count or 1)) end
    end
  end
  return best
end

-- Alternative for a slot: the one most in stock; if none is in stock, the one that can
-- be made the most from the stock (andesite casing: stripped oak log if there is oak),
-- else the first one that has a recipe. Never through another alternative of the slot
-- (planks: wood is made from logs, so ask for logs). Slots with the same alternatives
-- take the same item (two woods are never mixed in one batch).
local function pick(alts, stock, chosen)
  local key = table.concat(alts, ",")
  if chosen[key] then return chosen[key] end
  local best, most = alts[1], 0
  for _, a in ipairs(alts) do
    local n = stock and stock[a] or 0
    if n > most then best, most = a, n end
  end
  if most == 0 and alts[2] then
    local set = {}
    for _, a in ipairs(alts) do set[a] = true end
    local found = false
    if stock then
      for _, a in ipairs(alts) do
        local n = fromStock(a, set, stock)
        if n > most then best, most, found = a, n, true end
      end
    end
    if not found then
      for _, a in ipairs(alts) do
        if hasRecipe(a, set) then best = a; break end
      end
    end
  end
  chosen[key] = best
  return best
end

-- Game recipe (API format) -> internal format; nil if the machine is not supported
function recipes.convert(raw, stock)
  local machine = TYPE_MACHINE[raw.type]
  if not machine or not raw.output then return nil end
  local r = {
    id = raw.id, machine = machine ~= "turtle" and machine or nil, names = raw.names,
    output = { name = raw.output.name, count = raw.output.count, fluid = raw.output.fluid },
    chance = raw.output.chance, heat = raw.heat,
  }
  local chosen = {}
  if machine == "turtle" then
    local w = raw.width
    if w and (w > 3 or raw.height > 3) then return nil end
    r.grid = {}
    for i, alts in ipairs(raw.ingredients) do
      -- Shaped recipe: slot i of the recipe (width w) -> slot of the 3x3 grid
      local cell = w and (math.floor((i - 1) / w) * 3 + (i - 1) % w + 1) or i
      if cell > 9 then return nil end
      if alts[1] then r.grid[cell] = pick(alts, stock, chosen) end
    end
  else
    -- Deployer: the placed item, then the held item
    if machine == "deploying" and #raw.ingredients ~= 2 then return nil end
    r.inputs = {}
    for _, alts in ipairs(raw.ingredients) do
      local n = pick(alts, stock, chosen)
      r.inputs[n] = (r.inputs[n] or 0) + 1
    end
    if machine == "deploying" then
      r.held = pick(raw.ingredients[2], stock, chosen)
      if r.inputs[r.held] ~= 1 then return nil end -- placed = held: not supported
    end
  end
  for _, f in ipairs(raw.fluids or {}) do
    r.fluids = r.fluids or {}
    local n = pick(f.names, stock, chosen)
    r.fluids[n] = (r.fluids[n] or 0) + f.amount
    apiFluids[n] = true
  end
  if r.output.fluid then apiFluids[r.output.name] = true end
  for i = 2, #(raw.results or {}) do
    local res = raw.results[i]
    r.byproducts = r.byproducts or {}
    r.byproducts[res.name] = res.chance or 1
  end
  for k, v in pairs(raw.names or {}) do apiNames[k] = v end
  return r
end

-- A game recipe by its id ("create:pressing/iron_ingot"), in internal format;
-- nil without the mod, if it does not exist or if its machine is not supported
function recipes.get(id, stock)
  if not api then return nil end
  local ok, raw = pcall(api.get, id)
  if not ok or not raw then return nil end
  return recipes.convert(raw, stock)
end

-- The same game recipe, its alternatives chosen again with `stock`: the stock may have
-- changed since the recipe was displayed. Unchanged if it comes from recipes.db.
function recipes.refresh(r, stock)
  for _, mine in ipairs(list) do
    if mine == r then return r end
  end
  return r.id and recipes.get(r.id, stock) or r
end

---------------------------------------------------------------- lookup

function recipes.find(outputName)
  for i, r in ipairs(list) do
    if r.output.name == outputName then return r, i end
  end
  return recipes.findAll(outputName)[1]
end

-- Key of a { name -> count } table sorted by name: "a=1,b=2"
local function sortedKey(m)
  local keys = {}
  for k, v in pairs(m or {}) do keys[#keys + 1] = k .. "=" .. tostring(v) end
  table.sort(keys)
  return table.concat(keys, ",")
end

-- Two recipes that do the same thing (furnace and blast furnace, two game recipes that
-- give the same grid once the alternatives are chosen) have the same signature
local function signature(r)
  local grid = {}
  for i = 1, 9 do grid[i] = r.grid and r.grid[i] or "" end
  return table.concat({
    recipes.machine(r), r.output.name, tostring(r.output.count), tostring(r.heat),
    table.concat(grid, ","), sortedKey(r.inputs), sortedKey(r.fluids), sortedKey(r.byproducts),
  }, "|")
end

-- Every recipe that produces `outputName` (an item can have several): those from
-- recipes.db, then the game's for the other machines, without duplicates.
-- `stock` (optional) is used to choose among the alternatives of an ingredient.
function recipes.findAll(outputName, stock)
  local t, mine, seen = {}, {}, {}
  local function keep(r)
    local sig = signature(r)
    if not seen[sig] then
      seen[sig] = true
      t[#t + 1] = r
    end
  end
  for _, r in ipairs(list) do
    if r.output.name == outputName then
      keep(r)
      mine[recipes.machine(r)] = true
    end
  end
  local raws = gameRecipes(outputName)
  -- To be safe, what goes in the smoker does not go to the lava fan
  local smoked = false
  for _, raw in ipairs(raws) do
    if raw.type == "minecraft:smoking" then smoked = true end
  end
  for _, raw in ipairs(raws) do
    local machine = TYPE_MACHINE[raw.type]
    -- getFor also returns recipes where the item is only a by-product
    if machine and not mine[machine] and raw.output and raw.output.name == outputName
       and not (smoked and machine == "blasting") then
      local r = recipes.convert(raw, stock)
      if r then keep(r) end
    end
  end
  return t
end

-- One page of craftable items, sorted by name: returns total, items
-- (items[i] = { name, label, machines }). `machines` (optional): set of available
-- machines, to keep only what the workshop can make.
function recipes.listItems(query, offset, limit, machines)
  if api then
    local types
    if machines then
      types = {}
      for t, m in pairs(TYPE_MACHINE) do
        if machines[m] then types[#types + 1] = t end
      end
    end
    local ok, res = pcall(api.listItems, query or "", offset, limit, types)
    if not ok then return 0, {} end
    local items = {}
    for i, it in ipairs(res.items) do
      apiNames[it.name] = it.label
      local ms = {}
      for _, t in ipairs(it.types) do ms[#ms + 1] = TYPE_MACHINE[t] end
      items[i] = { name = it.name, label = it.label, machines = ms }
    end
    return res.total, items
  end
  -- Without the mod: the items of recipes.db
  local seen, all = {}, {}
  for _, r in ipairs(recipes.search(query)) do
    local n = r.output.name
    if not machines or machines[recipes.machine(r)] then
      if not seen[n] then
        seen[n] = { name = n, label = recipes.displayName(n), machines = {} }
        all[#all + 1] = seen[n]
      end
      table.insert(seen[n].machines, recipes.machine(r))
    end
  end
  local items = {}
  for i = offset + 1, math.min(#all, offset + limit) do items[#items + 1] = all[i] end
  return #all, items
end

-- Same item made on the same machine = same recipe
local function indexOf(r)
  for i, other in ipairs(list) do
    if other == r then return i end
  end
  for i, other in ipairs(list) do
    if other.output.name == r.output.name and recipes.machine(other) == recipes.machine(r) then
      return i
    end
  end
end

-- Adds or replaces (same item, same machine); returns true if replaced
function recipes.add(r)
  local idx = indexOf(r)
  if idx then list[idx] = r else table.insert(list, r) end
  indexNames()
  sort()
  recipes.save()
  return idx ~= nil
end

function recipes.remove(r)
  local idx = indexOf(r)
  if idx then table.remove(list, idx) end
  indexNames()
  recipes.save()
end

-- Machine that makes the recipe; old recipes do not have this field
function recipes.machine(r)
  return r.machine or "turtle"
end

local MACHINE_LABELS = {
  pressing = "press", mixing = "mixer", compacting = "compacting",
  filling = "spout", emptying = "draining",
  washing = "washing", smoking = "smoking", blasting = "blasting", haunting = "haunting",
  crushing = "crushing", milling = "millstone", sawing = "saw", deploying = "deployer",
}

-- Probability of getting the result on each craft (random outputs); 1 by default
function recipes.chance(r)
  return r.chance or 1
end

-- Fluids used by one craft (mB)
function recipes.fluids(r)
  return r.fluids or {}
end

-- Items and fluids needed for `times` crafts, on average if the result is random
function recipes.expected(r, times)
  local t = {}
  for _, src in ipairs({ recipes.needs(r), recipes.fluids(r) }) do
    for n, per in pairs(src) do
      t[n] = math.ceil(per * times / recipes.chance(r))
    end
  end
  return t
end

-- Name of the machine to display; nil for the turtle
function recipes.machineLabel(r)
  local m = recipes.machine(r)
  if m == "turtle" then return nil end
  return MACHINE_LABELS[m] or m
end

-- Ingredients to display in a 3x3 grid: the crafting grid for the turtle, else one
-- ingredient per slot for the machines
function recipes.displayGrid(r)
  if r.grid then return r.grid end
  local cells = {}
  for item in pairs(r.inputs or {}) do cells[#cells + 1] = item end
  table.sort(cells)
  return cells
end

-- Amount of each ingredient for one craft
function recipes.needs(r)
  if r.inputs then
    local t = {}
    for n, count in pairs(r.inputs) do t[n] = count end
    return t
  end
  local t = {}
  for i = 1, 9 do
    local n = r.grid[i]
    if n then t[n] = (t[n] or 0) + 1 end
  end
  return t
end

-- Number of crafts possible with `stock` (without sub-crafts)
function recipes.craftable(r, stock)
  local best = math.huge
  for _, src in ipairs({ recipes.needs(r), recipes.fluids(r) }) do
    for name, per in pairs(src) do
      best = math.min(best, math.floor((stock[name] or 0) * recipes.chance(r) / per))
    end
  end
  return best == math.huge and 0 or best
end

-- true if a missing ingredient can be crafted itself
function recipes.hasSubCraft(r, stock)
  for name, per in pairs(recipes.expected(r, 1)) do
    if (stock[name] or 0) < per and recipes.find(name) then return true end
  end
  return false
end

return recipes
