-- machines/depot.lua : poste sur depot (presse, spout, deployer)
-- Vérifié en jeu : case 1 = item posé, cases 2-9 = résultats.

return require("machines.container"){ input = { 1, 1 }, output = { 2, 9 } }
