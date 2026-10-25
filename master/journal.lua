-- journal.lua : mise en forme des lignes du journal (pages/logs.lua, screens.lua)

local journal = {}

-- Coupe `text` en lignes de `w` caractères, les suites décalées de 2
function journal.wrap(text, w, out)
  local first = true
  while #text > 0 do
    local width = first and w or w - 2
    local cut = #text <= width and #text or (text:sub(1, width):match(".*() ") or width + 1) - 1
    if cut < 1 then cut = width end
    out[#out + 1] = (first and "" or "  ") .. text:sub(1, cut)
    text = text:sub(cut + 1):gsub("^ +", "")
    first = false
  end
end

function journal.color(line)
  if line:find("Erreur", 1, true) or line:find("Echec", 1, true) or line:find("Bloc absent", 1, true) then
    return colors.red
  end
  if line:find("Bloc reconnecte", 1, true) then return colors.lime end
  if line:find("Termine", 1, true) then return colors.lime end
  if line:find("Commande", 1, true) then return colors.yellow end
  return colors.white
end

-- Lignes coupées et colorées pour une ui.List de largeur w
function journal.lines(log, w)
  local lines = {}
  for _, l in ipairs(log) do
    local parts = {}
    journal.wrap(l, w, parts)
    for _, p in ipairs(parts) do lines[#lines + 1] = { text = p, fg = journal.color(l) } end
  end
  return lines
end

return journal
