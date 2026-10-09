# Forest (Milestone 10, part 2)

Status: **approved by the owner** (2026-10-09), with old-growth pockets added (see `old_growth_forest.md`). Interview: 2026-10-09.

## Summary
A large, common mixed oak forest in rich deep green: mostly oaks with some
tall slim birches and round maples (a quarter of them in autumn colours).
Dense, with touching canopies and occasional sunny clearings; ferns, grass,
leaf-litter patches near trunks, mushrooms in the shade, fallen logs and
mossy stumps.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Type | mixed oak forest: mostly oaks, some birch, a few maples |
| Density | dense: a tree every ~5–8 blocks, canopies touching; occasional clearings of grass and flowers |
| Floor | ferns + grass, forest_floor (leaf litter) patches near trunks, small red and brown mushrooms in shade, fallen logs and mossy stumps |
| Colour | rich deep green, darker and more saturated than plains |
| Birch / maple | birches tall and slim with a light crown; maples medium with wide round crowns, ~1 in 4 in autumn red/orange |
| Size | large and common: often several km across, bordering plains |
| Details | occasional: a clearing every ~150 blocks, a fallen log every ~30–40 blocks, mushroom patches in shade |
| Litter | patches near trunks, grass elsewhere and in clearings |

## New blocks
* `fern` (plant, grass-tinted), `red_mushroom`, `brown_mushroom` (plants).
* Fallen logs use the existing oak/birch logs lying sideways (needs log
  axis states: a log gets 3 states, upright / east-west / north-south, which
  also fixes the end grain on big-oak branches).
* Mossy stump: a 1–2 block oak log with moss; the existing
  `oak_mossy_planks`-style moss texture as a `mossy_oak_log` block.

## Numbers (Claude's proposal, tunable in `data/biomes/30_forest.biome`)
| Item | Proposal |
|---|---|
| Climate | temperate (0.35–0.70), humid (0.55–1.0); heights 98–220 |
| Size | large: a wide humidity band so it is the most common temperate biome |
| Colours | grass 3FA82E, foliage 2E8A22 |
| Trees | ~1 per 40 blocks²: oak 60% (small 40 / big 20), birch 25%, maple 15% (green 3 : autumn 1) |
| Clearings | one candidate per ~150×150 blocks, radius 8–16: no trees, grass + flowers |
| Floor | short grass 25%, fern 15%; litter within 2 blocks of trunks (70%); mushrooms 2% where litter |
| Fallen logs | 1 per ~1200 blocks², 3–6 long; stumps 1 per ~1500 blocks² |
| Hills | normal height (hill_scale 1.0) |

## As built (M10 part 2)
* Data in `data/biomes/30_forest.biome`, trees in `10_trees.biome`.
* Fallen logs lie along X or Z (new log axis states) and stop where the
  ground is not level.
* Litter is `forest_floor`, within 2 blocks of trunks (70%); ferns and
  mushrooms grow on it.

## Open
* Forest edge transition biome (from the biome system interview): later.
