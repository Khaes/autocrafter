-- machines/drain.lua: item drain station (empties items that hold a fluid)
-- 1 slot: the placed item, which becomes the empty container; the fluid goes into the
-- drain's tank, then the computer moves it back to the storage tanks.
-- One item at a time (not checked whether a whole stack gets emptied).

return require("machines.container"){ input = { 1, 1 }, output = { 1, 1 }, maxBatch = 1 }
