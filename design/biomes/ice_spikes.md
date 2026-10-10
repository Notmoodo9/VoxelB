# Ice spikes (Milestone 10, part 16)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Rare pockets inside the snowy tundra where a forest of ice spires rises
from the snow:
* many short spikes, scattered tall ones and rare giants, each tapering to
  a point;
* pale packed ice with deep blue-ice cores and tips;
* snow ground with patches of packed ice, and frozen ponds.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Spikes | a mixed forest: many short (4–10 tall), scattered tall (15–30), rare giants (35–50), one every ~10–15 blocks |
| Material | packed ice with blue-ice cores and tips (vibrant icy blues) |
| Ground | snow with packed-ice patches and frozen ponds |
| Rarity | rare pockets of 150–400 blocks inside snowy tundras, ~1% of land |

## How it is built (Claude's technical proposal)
* **Placement**: the snowy tundra's climate in the `rarity` field
  (0.72–1.00), priority 2, like the other rare pockets.
* **Ground**:
  * snow on top, with `top_patch = packed_ice`;
  * frozen ponds, using the tundra's `pond_top = ice`.
* **Spikes**: a new tree kind `spike`:
  * a stack of discs whose radius falls from the base radius to a point,
    as (1 − t)^1.3 for a slim spire;
  * the centre column, and the whole upper 30%, are the core block
    (TREE.leaves); the rest is TREE.log;
  * the base sinks 2 blocks into the ground.
  * Three data entries:
    * `small_ice_spike`: radius 1–1.6, 4–10 tall;
    * `tall_ice_spike`: radius 1.8–2.6, 15–30 tall;
    * `giant_ice_spike`: radius 3–4, 35–50 tall, rare.
* **New block**: `blue_ice` (deep vivid blue, texgen).
* No plants, apart from a few dwarf shrubs.

## Deferred
* Glittering particles, if wanted, come with the particle milestone.

## Open
* Nothing.

## As built (M10 part 16)
* Built as proposed; ~1.1% of land near the origin.
* Seed 20261009:
  * among the spires: `--pos -400 120 -600 --look 0 12`;
  * over the pocket: `--pos -384 170 -560 --look 0 -12`.
