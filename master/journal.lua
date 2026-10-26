-- journal.lua: formatting of the log lines (pages/logs.lua, screens.lua)

local journal = {}

-- Cuts `text` into lines of `w` characters, the continuations indented by 2
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
  if line:find("Error", 1, true) or line:find("Failed", 1, true) or line:find("Block missing", 1, true) then
    return colors.red
  end
  if line:find("Block reconnected", 1, true) then return colors.lime end
  if line:find("Done", 1, true) then return colors.lime end
  if line:find("Order", 1, true) then return colors.yellow end
  return colors.white
end

-- Wrapped and colored lines for a ui.List of width w
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
