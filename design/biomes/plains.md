# Plains (Milestone 10, first biome)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Open, gentle grassland in bright spring green: waving short and tall grass,
classic wildflowers, very sparse lone oaks and bushes, occasional small
ponds, and rare flower meadows.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Ground cover | waving fields: ~35% short grass, patches of 2-block tall grass, swaying in the wind |
| Flowers | classic set: poppy (red), dandelion (yellow), cornflower (blue), oxeye daisy (white), allium (purple), tulips (red, orange, white, pink) |
| Meadows | rare sub-areas 40–100 blocks across: some single-colour fields, some mixed rainbow |
| Trees | very sparse: about one lone tree per ~100 blocks |
| Oak shape | varied natural oaks: mostly small round oaks 5–7 tall, occasionally big branching oaks 10–14 tall with irregular leafy crowns |
| Bushes | both plain leaf clumps (1–2 high on a log stub) and flowering bushes; a bit more common than trees |
| Ponds | occasional: a small pond 5–15 across, 1–3 deep, every few hundred blocks (edge plants later) |
| Terrain | gentle hills, flatter than the generic lowland |
| Grass colour | bright spring green: saturated, slightly yellow-green |

## New blocks
* `short_grass`, `tall_grass` (2 blocks): a new crossed-plane "plant" shape,
  tinted by the biome, swaying in the wind.
* Flowers (plant shape): `poppy`, `dandelion`, `cornflower`, `oxeye_daisy`,
  `allium`, `red_tulip`, `orange_tulip`, `white_tulip`, `pink_tulip`.
* `flowering_oak_leaves` for the flowering bushes (oak leaves with small
  blossoms).

## Numbers (Claude's proposal, tunable in `data/biomes/plains.biome`)
| Item | Proposal |
|---|---|
| Climate | temperate (temperature 0.4–0.7 of the range), medium humidity; heights from just above the beach to ~150 |
| Size factor | 1.0 (medium) |
| Terrain | hills scaled to ~50% of the generic lowland |
| Short grass | 30% of grass blocks; tall grass 5% |
| Flowers | 3% outside meadows, in small same-colour clusters |
| Meadows | ~1 per 600×600 blocks; 60% coverage; half single-colour |
| Trees | 1 per ~10,000 blocks² (about one per 100×100): 80% small oak, 20% big oak |
| Bushes | 1 per ~4,000 blocks²: half plain, half flowering |
| Ponds | 1 per ~300×300 blocks |

## As built (M10)
* All numbers live in `data/biomes/20_plains.biome`; tree shapes in
  `data/biomes/10_trees.biome`.
* Small oaks have 4–6 log trunks with a round crown (5–8 tall in all);
  big oaks have 8–11 log trunks, 2–4 diagonal branches with leaf clusters
  and a crown (10–14 tall).
* Ponds need a fairly flat rim, so on terraced hills they are rarer than
  the chance alone suggests.

## Open
* Reeds or sugar cane at pond edges, berries on bushes: later (items/farming).
