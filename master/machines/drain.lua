-- machines/drain.lua : poste item drain (vidange d'items qui contiennent un fluide)
-- 1 case : l'item posé, qui devient le récipient vide ; le fluide va dans le
-- réservoir du drain, puis le computer le ramène aux réservoirs de stockage.
-- Un item à la fois (pas vérifié qu'une pile entière soit vidée).

return require("machines.container"){ input = { 1, 1 }, output = { 1, 1 }, maxBatch = 1 }
