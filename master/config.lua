-- config.lua : réglages du montage, lus dans DATA_DIR/config.json
--
-- Montage par défaut :
--   * Crafty Turtle (turtle + table de craft)
--   * coffre de STOCKAGE au-dessus de la turtle (ou n'importe quels
--     inventaires reliés par modem filaire)
--   * coffre TAMPON vide en dessous de la turtle (sert de sas)
--   * moniteur avancé optionnel sur un côté libre
--
-- Clés de config.json (une clé absente = nil) :
--   buffer       : coffre tampon (sous la turtle), nom réseau
--   bufferDir    : "up" | "down" | "front" ; déduit si buffer est un côté
--   storage      : inventaires de stockage ; absent = tous sauf le tampon et la sortie.
--                  À lister dès qu'il y a des machines sur le réseau (sinon depot, basin... comptent)
--   outputs      : sorties qui reçoivent l'item commandé, choisies sur l'écran principal
--                  pour chaque commande ; la première est celle par défaut. Absent = il
--                  reste dans le stockage. Noms réseau, ou { name, label } :
--                  [ "minecraft:chest_0", { "name": "minecraft:chest_30", "label": "Atelier" } ]
--                  Ancienne clé output (une seule sortie) : lue comme outputs = [ output ]
--   trash        : poubelle (chute dans la lave) : bouton « Vider » de l'écran
--                  principal ; absent = pas de bouton
--   stations     : postes Create, par machine des recettes (noms réseau des blocs)
--     timeout : secondes sans nouveau résultat avant d'abandonner (30 par défaut)
--     Bloc cassé puis reposé (basin_0 -> basin_1) : retrouvé tout seul s'il est
--     le seul de son type libre. On peut aussi écrire "type": "create:basin" sans name.
--     Plusieurs postes pour une machine : ils se partagent les lots en même temps
--       "pressing": [ { "name": "create:depot_0" }, { "name": "create:depot_1" } ]
--     turtle    : turtles ouvrières en plus de celle-ci : ID du computer et nom réseau
--                 de son coffre tampon (programme worker.lua sur l'ouvrière)
--     filling   : depot sous un spout (spout = nom du spout)
--     deploying : depot sous un deployer en mode « utiliser » (deployer = son nom)
--     mixing    : basin sous un mixer ; heat = niveau max ("heated" ou "superheated"),
--                 burner = deployer qui nourrit le blaze burner. Il fait aussi les
--                 recettes sans chaleur.
--     washing, smoking, haunting, blasting, crushing, milling, sawing : postes où les
--       items défilent, coffre d'entrée (inlet) -> machine -> coffre de sortie (output)
--       idle : entrée vide et rien de nouveau depuis idle s = passage fini (10 par défaut)
--       retries : nouveaux passages si le résultat manque (3 par défaut)
--   fluidStorage : réservoirs des fluides (un fluide par tank) ; absent = tous les fluid tanks
--   fuel         : combustibles des blaze burners, par niveau (le premier en stock est pris)
--   logFile      : journal des commandes ; absent = DATA_DIR/log.txt
--   refreshRate  : secondes entre deux relevés du stock (10 par défaut)
--   monitorScale : taille du texte sur le moniteur, 0.5 à 5 (1 par défaut)
--   monitor      : moniteur de l'écran principal ; absent = le plus grand (puis retenu)
--   screens      : autres moniteurs, choisis en les touchant (screens.lua) :
--                  { "monitor_1": "logs", "monitor_2": "crafts", "monitor_3": "status" }
--   screenScale  : taille du texte des autres moniteurs (0.5 par défaut)
--   sound        : son de fin de commande sur un speaker (true par défaut), bouton
--                  note de musique du titre de l'écran principal

local DATA_DIR = "/recipecrafter"
local PATH = DATA_DIR .. "/config.json"
local config = {}
config.scanned = false
local f = fs.open(PATH, "r")
if f then
  local text = f.readAll()
  f.close()
  local err
  config, err = textutils.unserializeJSON(text)
  if type(config) ~= "table" then
    error("Configuration invalide (" .. PATH .. ") : " .. tostring(err), 0)
  end
  -- Après la lecture : unserializeJSON renvoie une nouvelle table
  config.scanned = true
end

config.dataDir = DATA_DIR
config.logFile = config.logFile or DATA_DIR .. "/log.txt"
config.refreshRate = config.refreshRate or 10
config.monitorScale = config.monitorScale or 1
if config.output then
  config.outputs = config.outputs or { config.output }
  config.output = nil
end

-- Modifie config.json : fn(données du fichier) les change, puis le fichier est réécrit.
-- La configuration en mémoire ne change pas (à l'appelant de le faire s'il le faut)
function config.edit(fn)
  local data = {}
  local file = fs.open(PATH, "r")
  if file then
    data = textutils.unserializeJSON(file.readAll()) or {}
    file.close()
  end
  fn(data)
  fs.makeDir(DATA_DIR)
  file = fs.open(PATH, "w")
  file.write(textutils.serializeJSON(data))
  file.close()
end

return config
