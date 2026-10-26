-- machines/basin.lua: basin station (mixer, press compacting)
-- Checked in game: slots 1-9 = ingredients, slots 10-18 = results.

return require("machines.container"){ input = { 1, 9 }, output = { 10, 18 } }
