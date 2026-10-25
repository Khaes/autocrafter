-- peri.lua : liste les périphériques visibles, leurs fonctions et leur contenu
-- dans peripherals.txt

local f = fs.open("peripherals.txt", "w")
for _, n in ipairs(peripheral.getNames()) do
  local p = peripheral.wrap(n)
  f.writeLine(n .. " [" .. table.concat({ peripheral.getType(n) }, ", ") .. "]")
  f.writeLine("  " .. table.concat(peripheral.getMethods(n), " "))
  if p.size then
    f.writeLine("  cases : " .. p.size())
    for slot, it in pairs(p.list()) do
      f.writeLine(("  case %d : %d %s"):format(slot, it.count, it.name))
    end
  end
  if p.tanks then
    for i, t in pairs(p.tanks()) do
      f.writeLine(("  reservoir %d : %d mB %s"):format(i, t.amount, t.name))
    end
  end
end
f.close()
print(#peripheral.getNames() .. " peripheriques ecrits dans peripherals.txt")
