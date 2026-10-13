# Items, inventory, crafting, tools, smelting, chests (Milestone 18)

Interviewed and **approved** 2026-10-12. Everything here comes from data files (`data/items/`,
`data/recipes/`, block settings); the numbers are starting values to tune.

## Summary

A Minecraft-familiar core (9 + 27 inventory, stacks of 64, 3x3 crafting,
furnace, chests that join) with our own long tool ladder from wood to star
crystal, and tools that are repaired at a special **Tinker's table** with a
**binding** that depends on the tier. Items drop as small spinning 3D items
you pick up by walking near them; the held item shows in your hand.

## Decisions

| Topic | Decision |
|---|---|
| Inventory | 9 hotbar slots (keys 1–9, mouse wheel) + 27 inventory slots (3 rows of 9); inventory key E |
| Stacks | 64 for blocks and most items; tools (and later armor) don't stack; a few items 16 (buckets, eggs, later) |
| Creative inventory | a catalog of every block and item in category tabs with a search box; click/drag into the hotbar |
| Crafting | shaped recipes: 2x2 grid in the inventory (by hand), 3x3 on a **workbench**; a **recipe book** lists what you can make and fills the grid with one click |
| Tool types | pickaxe (stone, ores), axe (wood; a weapon later), shovel (dirt, sand, gravel, snow, clay), hoe (tills dirt; farming later) |
| Tool tiers | wood → stone → copper → iron → diamond → mythril → adamantite → star crystal. Silver and gold are not tool tiers (magic, trading, decoration later) |
| Ore gates | hand/wood: stone, coal · stone: copper, iron · copper: silver, gold · iron: diamond, emerald · diamond: mythril · mythril: adamantite · adamantite: star crystal. Mining with too low a tier is slow and drops nothing |
| Mining pace | classic: stone by hand ≈ 7 s (no drop), wood pick ≈ 1.1 s, iron ≈ 0.4 s, top tiers near-instant |
| Durability | tools wear out and break at 0; higher tiers last much longer |
| Repair | only at a **Tinker's table** (wood + iron table with tool racks and a vise): tool + its material + the tier's **binding** |
| Drops | broken blocks pop out as small spinning, bobbing items; walk near to collect (they drift to you); they vanish after 5 minutes |
| Item look | held block/tool in the lower right in first person, with a swing; blocks as small 3D cubes, tools as thick pixel sprites, in hand and dropped |
| Smelting | **furnace**: ore on top, fuel below, bars out after a few seconds; keeps working while you're away. Mythril and higher need a **blast furnace** |
| Chests | wooden chest, 27 slots; two side by side join into a 54-slot double chest (metal chests later) |
| Recipes | the familiar shapes where Minecraft has the item (planks, sticks, workbench, tools, furnace, chest); the new ones proposed below |

## Tiers (starting numbers)

| Tier | Material | Durability (uses) | Mining speed | Mines |
|---|---|---|---|---|
| Hand | — | — | 1× | dirt, wood, stone (no drop) |
| Wood | planks | 60 | 2× | stone, coal |
| Stone | cobblestone | 132 | 4× | + copper, iron |
| Copper | copper bar | 190 | 5× | + silver, gold |
| Iron | iron bar | 250 | 6× | + diamond, emerald |
| Diamond | diamond | 1560 | 8× | + mythril |
| Mythril | mythril bar | 2400 | 10× | + adamantite |
| Adamantite | adamantite bar | 3600 | 12× | + star crystal |
| Star crystal | star crystal | 5000 | 16× | everything |

## Repair bindings (new: please review)

| Tool tiers | Binding | How it's made |
|---|---|---|
| wood, stone, copper | **Fibre binding** | workbench, shapeless: 2 plant fibre + 1 resin → 2 bindings. *Plant fibre* drops sometimes from grass, ferns, vines and reeds; *resin* sometimes from logs |
| iron, diamond | **Flux** | workbench, shapeless: 1 salt + 1 sand + 1 coal → 2 flux (salt is found in deserts and salt flats) |
| mythril, adamantite, star crystal | **Star essence** | Tinker's table: 1 star crystal + 2 crystal shards → 1 essence (*crystal shards* drop from the crystal sprouts in crystal caves) |

A repair takes the tool + 1 of its material + 1 binding and restores a
third of the tool's durability; up to 3 pairs at once.

## New stations (new: please review)

* **Tinker's table** — 3x3: `iron iron iron / planks workbench planks /
  planks _ planks`. Repairs tools; later it can hold tool upgrades.
* **Blast furnace** — 3x3: `iron iron iron / iron furnace iron / smooth
  stone ×3`. Smelts everything a furnace does, twice as fast, and is
  needed for mythril and adamantite ore. (Diamond, emerald and star
  crystal are gems: they drop ready to use.)

## Fuels

coal 80 s (smelts 8 items) · log or planks 15 s (1.5 items) · stick 5 s ·
lava bucket 1000 s (with buckets, later).

## Building plan (parts)

1. **Items + inventory:** item registry (`data/items/`), inventory and
   hotbar, HUD hotbar, inventory screen with drag and drop, Creative
   catalog with tabs and search, item icons, held item in hand.
2. **Mining + drops:** block hardness and preferred tool, mining time by
   tool and tier, drop tables, item entities with pickup.
3. **Crafting + chests:** recipe registry (`data/recipes/`), 2x2 and 3x3
   crafting, workbench, recipe book, chests (doubles), saved with the world.
4. **Tools, smelting, repair:** the four tool types in 8 tiers with
   durability, furnace and blast furnace, fuels, Tinker's table and the
   bindings; the new items' textures.

## Survival before milestone 20 (decided)

Survival is unlocked in world creation with this milestone: no flying,
real mining times, drops, crafting and tool wear, but no health or hunger
until milestone 20. Worlds made now keep Survival and gain health and
hunger then.

## Drops (decided while building part 2, following "familiar where it exists")

grass block, forest floor, needle floor, mycelium → dirt; stone →
cobblestone; coal ore → coal; diamond / emerald / star crystal ore → the
gem; leaves, glass, stained glass, ice, short/tall grass, ferns, dead
bushes, crystal sprouts → nothing (fibre, resin and crystal shards come
with the bindings in part 4); metal ores drop the ore block itself, which
the furnace smelts (part 4). Everything else drops itself.

## Built in part 3 (crafting and chests)

Recipes follow the "familiar shapes" decision: logs/bark/stems → 4
planks; 2 planks → 4 sticks; 2 × 2 planks → workbench; 8 planks in a ring
→ chest; per wood: 3 planks → 6 slabs, stairs (4), fence (3, with
sticks), fence gate, door (3), trapdoor (2), ladder (4), sign (3),
pressure plate, carved planks (2 slabs), mossy planks (planks + vine);
per stone and terracotta: slabs, stairs, walls, pillars; 4 stone → 4
stone bricks, 4 sand → sandstone, cobblestone + vine → mossy
cobblestone, 6 glass → 16 panes. Bookshelves wait for books; smooth stone,
bricks and glass come from the furnace (part 4).

Not decided in the interview, chosen while building (tell me if any
should change):
* In Creative, E shows the catalog (no 2 × 2 grid); a workbench still
  opens its grid in Creative.
* Sneak + right click on a workbench or chest places a block against it.
* The recipe book shows only what you can make right now.

## Built in part 4 (tools, smelting, repair)

* The 32 tools with the tier table's numbers; durability bars on slots.
* Furnace (8 cobblestone) and blast furnace (iron bars, a furnace, smooth
  stone); both glow while burning. Smelting: copper / iron / silver / gold
  ores → bars (10 s), mythril (16 s) and adamantite (20 s) only in the
  blast furnace; sand → glass, cobblestone → stone, stone → smooth stone,
  clay → bricks. Fuels as decided.
* Tinker's table (iron bars, a workbench, planks): put a worn tool and
  1–3 pairs of material + binding in its grid. Bindings as decided; plant
  fibre drops 20 % from grasses and ferns, 35 % from vines, reeds and
  cattails; resin 10 % from logs; crystal sprouts drop a crystal shard.

Chosen while building (tell me if any should change): the chance numbers
above; clay → bricks; a furnace keeps cooking while you are anywhere in
the world; lit furnaces give light.
