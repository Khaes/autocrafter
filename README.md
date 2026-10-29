# AutoCrafter

An auto-crafter for **CC:Tweaked** turtles and **Create 6** (Minecraft 1.20.1).
Pick an item on a monitor, and the turtle plans the whole craft tree, takes the
ingredients from your storage, crafts with its crafting table and hands the Create
steps (pressing, mixing, compacting, filling, deploying, washing, smoking, crushing...)
to the machines on its wired network. The finished item goes to an output chest.

```
master/   program of the main Crafty Turtle (the "master")
worker/   program of the optional worker turtles (extra crafting tables)
```


## Requirements

- Minecraft 1.20.1 with **CC:Tweaked** and **Create 6**
- **AutoCrafter Link** (`mod/autocrafterlink-1.0.0.jar`): gives the computer the game's
  recipes, nothing can be crafted without it
- Optional:
  - **Storage Drawers**: a drawer controller can be the main storage
  - **Create Deco**: only used to detect blaze burners under presses

## Installation

 - Copy `mod/autocrafterlink-1.0.0.jar` into your mod folder

## 1. Build the setup in game

**Main turtle**
1. Place a **Crafty Turtle** (turtle + crafting table) with a **wired modem**
   connected to your network.
2. Put an **empty chest directly below** the turtle: the *buffer*. Give it a wired
   modem too and turn the modem on (right click). It must be the only chest touching
   the turtle.
3. Place an **advanced monitor** (touch screen) on the network: the biggest one becomes
   the main screen.

**Storage and outputs** (all on the wired network, modems turned on)
- Main storage: some chests, or a Storage Drawers controller.
- One or more **output chests**: where the finished items are delivered.
- Optional **trash**: a chest that drops into lava (the detection empties the tested
  chests there).
- Optional Create **fluid tanks** for fluids (water, lava...).

**Machines** (every block that the computer touches needs a modem)

| Machine | Blocks on the network |
|---|---|
| Press | depot under a mechanical press |
| Spout (filling) | depot under a spout, and the spout |
| Deployer | depot under a deployer in "use" mode (right click), and the deployer |
| Mixer | basin under a mechanical mixer |
| Press on basin (compacting) | basin under a mechanical press |
| Heated mixer / press | same, with a blaze burner under the basin and a deployer that can feed it |
| Fans, crushing wheels, millstone, saw | an inlet chest that feeds the machine and an output chest that collects the result |

Several stations of the same machine share the work.

**Saw with a modem**: also put a wired modem on the mechanical saw of a saw station.
The computer then sets the saw's filter to the wanted result before each batch, which
allows the **stonecutter recipes** (copper block -> cut copper, stone stairs, slabs...):
without a filter the saw cycles through every result of an item. The detection finds
the saw on its own (Scan > Additional for a station that already exists); it briefly
puts a cobblestone filter on each free saw and sends an oak log.

**Optional extras**
- **Worker turtles**: more Crafty Turtles, each with its own buffer chest below it
  (modem on), on the same network.
- **More monitors**: small screens for the live log, the craft list or the status.
  Keep one block between monitors of the same type, otherwise they merge.
- **Speaker**: plays a chord when an order is done, low notes on errors.
- **Lectern** (with a modem): holds the Material Checklist of a Create Schematicannon
  for the **Book** button.

## 2. Install the code

Copy (or link) the folders into the save, where `<ID>` is the turtle's computer ID
(`id` in the turtle's shell):

```
<save>/computercraft/computer/<ID of the main turtle>/   <- contents of master/
<save>/computercraft/computer/<ID of each worker>/       <- contents of worker/
```

Reboot the turtles (`Ctrl+R` in their screen, or `reboot`). Both programs start on
their own (`startup.lua`).

## 3. First start: detection

On the first start the main screen asks a few questions and then tests the machines
by sending items to them. Follow the screen:

1. **Main storage**: chests or drawer controller. For chests: empty them and put
   1 cobblestone in each storage chest, then "Done".
2. **Buffer**: put 1 cobblestone in the buffer chest.
3. **Outputs**: put 1 cobblestone in an output chest; repeat for each output.
4. **Trash** (optional): put 1 cobblestone in it and turn its mechanism off.
5. **Go**: the scan starts. Put these test items in the storage first (one of each
   is enough unless stated):

   | For | Items |
   |---|---|
   | Flow machines | gravel, white concrete powder, cobblestone, oak log, raw beef, wheat |
   | Press / spout | dirt, 500 mB of water in a tank (spout) |
   | Mixers | andesite, iron nugget, copper ingot, zinc ingot |
   | Compacting | 2 flint, gravel, 100 mB of lava in a tank, iron ingot (heated) |
   | Deployers | cogwheel, oak planks |
   | Blaze burners | charcoal or coal |

   The screen names any missing item and lets you retry.
6. **Save**, then **Restart**. The configuration is written to
   `/recipecrafter/config.json` on the main turtle.

Machines added later: press **Scan** on the main screen and choose **Additional**:
only the blocks that have no role yet are tested. **Everything** runs the full
detection again.

## 4. Use it

**Main screen**
- Type in the search field (keyboard, or the Recipe Tablet / keyboard block of the
  AutoCrafter Link mod) and pick an item. The recipe page shows the ingredients (green: in
  stock, orange: can be crafted, red: missing), set the quantity and press **ADD**.
- Repeat to build an order, choose the output under the list if you have several,
  then press **CRAFT**. Missing ingredients are crafted first when possible. Sent to an
  output, an order first takes what the storage already has and only crafts the rest
  (with the output "storage", everything is crafted).
- **Book**: put the Material Checklist printed by a Schematicannon on the lectern; a
  popup appears within 2 seconds (**Add** / **Ignore**). **Add** puts every item of the
  book into the order, in full: the stock is sent first and the rest is crafted. An
  item that cannot be crafted becomes a "(stock)" line, sent from the storage only;
  what is missing of it is listed in the log. The **Book** button (top bar) does the
  same at any time, for example with a book that was already on the lectern when the
  turtle started.
- **Crafts**: running, queued and finished orders. Click one to see its log and
  **Cancel** it.
- **Logs**: the full log.
- **Stations**: every configured block (green present, red missing, yellow no role).
  **Repair** renames a block that was broken and placed again.
- Music note (top right): sound on/off.

**Other monitors**: the first time, touch one to choose what it shows (Logs, Crafts,
Status, None). Touch its title to choose again; touch the top / bottom half to scroll.

**Worker turtles**: nothing to do; they appear as "worker N" and take crafting
batches when the main turtle is busy.

## Configuration

`/recipecrafter/config.json` is written by the detection; the keys are described at
the top of `master/config.lua`. Settings you add by hand (`timeout`, `idle`,
`retries`, `fuel`, `monitorScale`, `refreshRate`...) are kept when the detection runs
again.

## Troubleshooting

- **"The turtle needs exactly one chest next to it"**: only the buffer, below.
- **"Buffer off the network"**: turn on the modem of the buffer chest.
- **A block shows as missing** after breaking it: open **Stations** and press
  **Repair**, or run **Scan > Everything**.
- **Station stuck**: the machine did not produce in time (no rotation, no water,
  out of fuel). Check it and set a longer `timeout` for that station if needed.
