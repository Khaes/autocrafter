-- machines/basin.lua : poste sur basin (mixer, presse en compactage)
-- Vérifié en jeu : cases 1-9 = ingrédients, cases 10-18 = résultats.

return require("machines.container"){ input = { 1, 9 }, output = { 10, 18 } }
