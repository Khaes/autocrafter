-- machines/depot.lua: depot station (press, spout, deployer)
-- Checked in game: slot 1 = placed item, slots 2-9 = results.

return require("machines.container"){ input = { 1, 1 }, output = { 2, 9 } }
