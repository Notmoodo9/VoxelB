# Sky islands (Milestone 10, part 14)

Status: **approved by the owner** (2026-10-11, interview answers; built
straight from them). Interview: 2026-10-11.

## Summary
A rare region of lush, vivid-green flower meadow on gentle hills, with an
archipelago of floating islands above it:
* the islands float between Y 200 and 320, mostly 10–30 wide, rarely up
  to 50;
* one every ~40–60 blocks, at varied heights, so they layer into the
  distance;
* their tops are meadow with flowers and a few trees;
* their undersides are inverted cones of stone and dirt, with exposed
  ores and blue crystals and roots hanging below.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Placement | over their own rare biome (~2–3% of land), with a lush meadow below |
| Height and size | Y 200–320, 10–50 wide (mostly 10–30), inverted-cone undersides |
| Tops | lush meadow and trees (oak, birch, flowering bushes), flowers |
| Undersides | hanging roots, exposed ores and crystals; waterfalls later (M15) |
| Count | a scattered archipelago: one every ~40–60 blocks at varied heights |
| Ground below | a lush flower meadow on gentle hills |
| Grass | vivid spring green with lots of colourful flowers |

## How it is built
* **Biome** `sky_islands`: the plains climate inside the `rarity` field
  (0.72–1.00), priority 2, heights 98–170, grass 4CDC3C. Dense flowers
  and flower meadows.
* **Islands** (D71): one candidate per 48×48 cell, kept where the blended
  biome at its centre sets `island_chance` (0.9 here, × the density
  there), so islands thin out at the region's edges. Per cell:
  * radius 5–25 (small ones common), centre height 200–320;
  * top: a low dome (+2.5 at the centre);
  * underside: an inverted cone, 0.9·r·(1−t)^1.5 deep, ragged by a block;
  * the rim wobbles with the detail noise.
* **Blocks**:
  * the biome's top block on top, 3 of filler below it, then stone with
    `island_ore` (coal 2%, iron 1.2%, blue crystal 0.6%);
  * `island_roots = hanging_roots, 0.12`: strands 2–5 long under the
    underside.
* **Island tops**: trees from the biome's tree list (0 to r/7 per island,
  within half the radius of the centre) and plants and flowers from its
  plant rules.

## Deferred
* Waterfalls off the island edges wait for flowing water (M15).

## Open
* Nothing.

## As built (M10 part 14)
* ~2.8% of land near the origin.
* The pocket nearest spawn is narrow (between a mountain, the steppe and
  the tundra), so its islands are few and small. Larger regions further
  out show the full archipelago. `--survey` logs the nearest floating
  island.
* Seed 20261009:
  * the nearest pocket: `--pos -640 250 -390 --look 0 -4`;
  * looking up from its meadow: `--pos -640 170 -480 --look 0 20`.
