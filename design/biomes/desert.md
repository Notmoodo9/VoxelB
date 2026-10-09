# Desert + oasis (Milestone 10, part 4)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Large hot deserts of warm golden sand with rolling dunes and flat basins,
sandstone underneath and in rocks: flowering cacti (some with arms), dead
bushes, sandstone boulders and spires, rare natural arches and half-buried
fossil skeletons. Very rarely, a lush oasis: a pool with grass, palms,
bushes and flowers.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Land | rolling dunes 5–20 high with flat sandy basins between |
| Sand | the existing warm golden sand; sandstone below |
| Size | large: often 1–3 km across, bordering savanna (later) and plains |
| Cacti | flowering cacti, some with arms |
| Features | cacti + dead bushes, oases, sandstone rocks, bones/fossils |
| Oases | very rare and lush: a bigger pool with palms, bushes and flowers |
| Rocks | sandstone boulders and spires scattered around, rare natural arches |

## New blocks
* `cactus` (green ribbed column, cube), `cactus_flower` (pink, plant shape,
  sits on top of a cactus)
* `dead_bush` (plant)
* `bone_block` (fossils)

## How it is built (Claude's proposal)
* **Dunes**: a ridged "dunes" noise field (crests ~90 blocks apart) adds up
  to `dune_height` (20) to the terrain, blended across the border like
  hills; basins where the field is low. Hills are flattened (×0.3).
* **Surface**: sand on top, sandstone below (and on steep slopes).
* **Cacti** (new tree kind `cactus`): 2–5 tall; 40% get 1–2 arms that step
  out one block and rise 1–3; 70% carry a pink flower on top. ~1 per 25×25
  blocks.
* **Dead bushes**: 1.5% of the sand.
* **Rocks** (new kind `rock`: stacked discs shrinking upward): boulders
  (radius 1.5–3, 2–4 high) ~1 per 60×60; spires (radius 1.5–2.5, 6–12
  high) ~1 per 120×120.
* **Arches** (new kind `arch`): a sandstone half-ring, radius 6–10,
  2 thick, legs down into the sand; ~1 per 400×400 blocks.
* **Fossils** (new kind `fossil`): a bone spine 6–10 long half-buried in
  the sand with arching ribs; ~1 per 300×300 blocks.
* **Oasis**: a rare pocket biome inside deserts (high weirdness), 60–150
  blocks: flat, grass, a pond in every 128-block cell (radius 5–6), palm
  trees (new kind `palm`: curved leaning trunk, drooping fronds), bushes,
  short/tall grass, flowers.

## Numbers in `data/biomes/40_desert.biome`, `41_oasis.biome`
| Item | Proposal |
|---|---|
| Climate | temperature 0.68–1.0, humidity 0.0–0.38; heights 98–200 |
| Colours | grass/foliage (for oases) bright 5DC93A / 3FAE2A |

## As built (M10 part 4)
* Climate box widened to temperature 0.62–1, humidity 0–0.42 after the
  first survey (desert 7.6% of land near the origin; oasis 0.1%).
* Oasis pools: one candidate per 64×64 cell; they may cut into sloping
  ground (`pond_slope = 12`).
* The terraced dune slopes show 1-block steps (no smooth slope blocks yet).

## Open
* Savanna and badlands (other hot biomes) are their own interviews.
