# Crystal caves (Milestone 10, part 20)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Deep underground, some large cavern systems turn into glittering grottos:
* the rock darkens to near-black stone with thin glowing veins in the
  grotto's colour;
* crystal sprouts grow from the floors and hang from the ceilings;
* clumps of solid crystal, and giant crystal pillars rising from floor to
  ceiling;
* carpets of glowing moss and small glowing fungi between them;
* still, luminous pools in the grotto's colour;
* the rare star crystal ore is more common in their walls.
Each grotto is dominated by one colour (blue, purple, green, pink or
amber), so different caves feel different; rare grottos mix them all.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Look | glittering grottos: crystal clusters on walls, floors and ceilings, huge pillars, darker stone so the crystals pop |
| Colours | region-themed (one colour per grotto: blue, purple, green, pink, amber), rare rainbow mixes |
| Depth and rarity | deep (below about Y 0), in roughly 1 in 8–10 large cave regions |
| Features | giant crystal pillars, glowing pools, more crystal ore, glowing moss and fungi |
| Rock | dark rock with crystal veins in the grotto's colour, plus the existing deep stone |
| Clusters | crossed-shard crystal sprouts on floors and hanging from ceilings, plus solid crystal clumps |
| Pools | glow in the grotto's colour |
| Size | large: whole cavern systems (50–150 blocks across) |

## How it is built (Claude's technical proposal)
* **A cave-biome system** (engine, reusable for future cave biomes):
  * new records `[cave_biome <name>]` in `data/biomes/`, with a depth
    range and a range of a 3D *cave region* noise (~120 blocks across);
  * the region field and a second *theme* field are evaluated on a coarse
    grid (every 4 blocks) per section and interpolated, only for sections
    in the depth range;
  * themes are lists of blocks in the data: crystal, sprout, veined stone
    and pool, per colour. The theme field picks one per area, and a
    `rainbow` share of areas mixes them per block.
* **Decoration pass**, after the existing cave decoration, in each section
  inside a region:
  * stone and deep stone become the theme's veined stone;
  * floors (air over solid): glowing moss patches; crystal sprouts
    (pointing up), glowcaps, crystal clumps (1–3 blocks), and pools (the
    floor's top two blocks become the theme's glowing pool block);
  * ceilings: crystal sprouts (pointing down) and short crystal
    stalactites;
  * star crystal ore in the walls at a set chance.
* **Giant pillars**: per 16 × 16 cell in a chunk, with a chance, a
  vertical column (radius 1.5–3) where all cave air inside the region
  becomes crystal. In a cavern that is a pillar from floor to ceiling.
  The disc stays inside the chunk. A pillar may also plug a tunnel that
  passes through it; it can be mined.
* **New blocks** (texgen):
  * per colour: `<colour>_crystal_sprout` (the spike shape, so it points up
    or down; the crystal's own glowing texture);
  * `<colour>_veined_stone` (near-black with glowing veins);
  * `<colour>_glow_pool` (a still, translucent, glowing liquid).
  * The pools are blocks, not flowing water, until fluids come (M15).
* **Survey**: logs the nearest crystal grotto air.
* Real light from the crystals comes with M13; the glow layers make them
  read bright now.

## Deferred
* Real emitted light: M13.
* Pools as a real liquid (swimming, flowing): with fluids (M15/M16).
* Cave mobs: hostile-mob milestone.

## Open
* Nothing.

## As built (M10 part 20)
* Built as proposed. Regions take 6.4% of the volume at y −16 to −176
  within 1 km of the origin (depth −220 to 0, region noise 0.42–1).
* Theme scale 600 (one colour per grotto; 220 gave 2–3 colours in one
  grotto). Rainbow cells 6%.
* The veins were redrawn as 2–3 wandering cracks per block, because
  straight lines tiled into a lattice.
* `pool_chance` became `pool_threshold` (a noise threshold, 0.45).
* Seed 20261009: a grotto right under spawn, seen from a cave below it:
  `--pos 64 -70 0 --look 0 25`.
