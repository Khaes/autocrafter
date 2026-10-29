-- recipes.lua: recipe base (pure data, no hardware access)
-- A recipe:
--   { output = { name, count }, grid = { [1..9] = item name }, names = { name -> display },
--     machine = "turtle" }  -- machine optional, "turtle" by default
-- A tag ingredient (planks, create:stone_types/veridium...) uses one item of the tag;
--   alts = { [that item] = { every item of the tag but the result } } lets the crafter
--   take any of them from storage (crafter.lua planSplit)
-- A Create machine recipe replaces grid with inputs:
--   { output = ..., machine = "pressing", inputs = { [name] = count } }
-- Fluids (in mB): fluids = { [name] = mB } as input; a fluid result is written
--   output = { name = "minecraft:lava", count = 50, fluid = true }
-- Deployer: held = the ingredient held by the deployer (also counted in inputs), the
--   others go on the depot
--
-- The AutoCrafter Link mod gives the computer the `recipes` API: the game's recipes are
-- converted to this format on demand.

-- The mod's API, before the module takes its name
local api = type(recipes) == "table" and recipes.getFor and recipes or nil

local recipes = {}

local apiCache = {} -- item -> raw recipes from recipes.getFor
local apiNames, apiFluids = {}, {}

-- true if `name` is a fluid of a recipe (amounts in mB)
function recipes.isFluid(name)
  return apiFluids[name] == true
end

-- "250 mB Water" or "3 Iron Ingot"
function recipes.amount(n, name)
  return ("%d%s %s"):format(n, recipes.isFluid(name) and " mB" or "", recipes.displayName(name))
end

function recipes.displayName(name)
  if apiNames[name] then return apiNames[name] end
  return ((name:match(":(.+)$") or name):gsub("_", " "))
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
  -- Stonecutter recipes, made by a saw whose filter the computer sets (station.saw)
  ["minecraft:stonecutting"] = "stonecutting",
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
-- `skip`: the recipe's result, never chosen (a stone tag holds cut veridium, which would
-- be circular) but still an alternative to avoid: the stairs, made from cut veridium,
-- must not look like a way out
-- `avoid` (optional set): items being crafted by the recipes above, never chosen either
-- (no stock: the sub-craft would loop back to them)
local function pick(alts, stock, chosen, skip, avoid)
  local key = table.concat(alts, ",")
  if chosen[key] then return chosen[key] end
  local options = {}
  for _, a in ipairs(alts) do
    if a ~= skip and not (avoid and avoid[a]) then options[#options + 1] = a end
  end
  if not options[1] then options = alts end
  local best, most = options[1], 0
  for _, a in ipairs(options) do
    local n = stock and stock[a] or 0
    if n > most then best, most = a, n end
  end
  if most == 0 and options[2] then
    local set = {}
    for _, a in ipairs(alts) do set[a] = true end
    local found = false
    if stock then
      for _, a in ipairs(options) do
        local n = fromStock(a, set, stock)
        if n > most then best, most, found = a, n, true end
      end
    end
    if not found then
      for _, a in ipairs(options) do
        if hasRecipe(a, set) then best = a; break end
      end
    end
  end
  chosen[key] = best
  return best
end

-- Game recipe (API format) -> internal format; nil if the machine is not supported
-- `avoid` (optional set): items never chosen among the alternatives (see pick)
function recipes.convert(raw, stock, avoid)
  local machine = TYPE_MACHINE[raw.type]
  if not machine or not raw.output then return nil end
  local r = {
    id = raw.id, machine = machine ~= "turtle" and machine or nil, names = raw.names,
    output = { name = raw.output.name, count = raw.output.count, fluid = raw.output.fluid },
    chance = raw.output.chance, heat = raw.heat,
  }
  local chosen = {}
  -- The result itself is never chosen among the alternatives of its ingredients (pick)
  local function choose(alts)
    local n = pick(alts, stock, chosen, r.output.name, avoid)
    local others = {}
    for _, a in ipairs(alts) do
      if a == n or (a ~= r.output.name and not (avoid and avoid[a])) then
        others[#others + 1] = a
      end
    end
    if others[2] then
      r.alts = r.alts or {}
      r.alts[n] = others
    end
    return n
  end
  if machine == "turtle" then
    local w = raw.width
    if w and (w > 3 or raw.height > 3) then return nil end
    r.grid = {}
    for i, alts in ipairs(raw.ingredients) do
      -- Shaped recipe: slot i of the recipe (width w) -> slot of the 3x3 grid
      local cell = w and (math.floor((i - 1) / w) * 3 + (i - 1) % w + 1) or i
      if cell > 9 then return nil end
      if alts[1] then r.grid[cell] = choose(alts) end
    end
  else
    -- Deployer: the placed item, then the held item
    if machine == "deploying" and #raw.ingredients ~= 2 then return nil end
    r.inputs = {}
    for _, alts in ipairs(raw.ingredients) do
      local n = choose(alts)
      r.inputs[n] = (r.inputs[n] or 0) + 1
    end
    if machine == "deploying" then
      r.held = choose(raw.ingredients[2])
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
-- changed since the recipe was displayed
function recipes.refresh(r, stock)
  return r.id and recipes.get(r.id, stock) or r
end

---------------------------------------------------------------- lookup

function recipes.find(outputName)
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

-- Every recipe that produces `outputName` (an item can have several), without duplicates
-- `stock` (optional) is used to choose among the alternatives of an ingredient, `avoid`
-- (optional set) holds the items never chosen among them (see pick).
function recipes.findAll(outputName, stock, avoid)
  local t, seen = {}, {}
  local function keep(r)
    local sig = signature(r)
    if not seen[sig] then
      seen[sig] = true
      t[#t + 1] = r
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
    if machine and raw.output and raw.output.name == outputName
       and not (smoked and machine == "blasting") then
      local r = recipes.convert(raw, stock, avoid)
      if r then keep(r) end
    end
  end
  return t
end

-- One page of craftable items, sorted by name: returns total, items
-- (items[i] = { name, label, machines }). `machines` (optional): set of available
-- machines, to keep only what the workshop can make.
function recipes.listItems(query, offset, limit, machines)
  if not api then return 0, {} end
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

-- Stock of ingredient `name` of `r`: with a tag ingredient, every item of the tag
function recipes.inStock(r, name, stock)
  local n = math.max(0, stock[name] or 0)
  for _, a in ipairs(r.alts and r.alts[name] or {}) do
    if a ~= name then n = n + math.max(0, stock[a] or 0) end
  end
  return n
end

-- `name` has a recipe that uses no item of `set` ({ [name] = true }): it can be made
-- from outside a tag
recipes.madeOutside = hasRecipe

-- Copy of `r` that uses `to` instead of `from` (another item of a tag ingredient); its
-- ingredients are then fixed (no alts)
function recipes.variant(r, from, to)
  local v = {}
  for k, x in pairs(r) do v[k] = x end
  if r.grid then
    v.grid = {}
    for i = 1, 9 do v.grid[i] = r.grid[i] == from and to or r.grid[i] end
  end
  if r.inputs then
    v.inputs = {}
    for n, c in pairs(r.inputs) do
      local m = n == from and to or n
      v.inputs[m] = (v.inputs[m] or 0) + c
    end
  end
  if r.held == from then v.held = to end
  v.alts = nil
  return v
end

-- Machine that makes the recipe (no field for the turtle)
function recipes.machine(r)
  return r.machine or "turtle"
end

local MACHINE_LABELS = {
  pressing = "press", mixing = "mixer", compacting = "compacting",
  filling = "spout", emptying = "draining",
  washing = "washing", smoking = "smoking", blasting = "blasting", haunting = "haunting",
  crushing = "crushing", milling = "millstone", sawing = "saw", stonecutting = "saw", deploying = "deployer",
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
      best = math.min(best, math.floor(recipes.inStock(r, name, stock) * recipes.chance(r) / per))
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
