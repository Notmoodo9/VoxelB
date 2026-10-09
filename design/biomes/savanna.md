# Savanna (Milestone 10, part 6)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Hot, golden, sun-baked grassland between plains and desert: wide flat
plains of dry golden grass with tall grass waving, scattered flat-topped
acacias, reddish termite mound spires, rare huge baobabs, and rare raised
flat-topped plateaus with cliff sides.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Feel | golden dry grass: warm yellow-olive, sun-baked |
| Terrain | flat plains + rare flat-topped plateaus (15–30 high, cliff sides, acacias on top) |
| Acacias | scattered: one every ~20–30 blocks |
| Termite mounds | earthy reddish-brown spires 3–6 tall, wider at the base, ~1 per 40×40 |
| Baobabs | rare and huge: ~1 per 150×150, fat bottle trunk 3–5 wide, 10–16 tall, crown of stubby branches |

## How it is built (Claude's proposal)
* **Plateaus**: a `plateaus` noise field; where it is above 0.55 the
  terrain is raised by `plateau_height` (22) through a steep ramp (cliffs,
  shown as the steep-slope block `coarse_dirt`); blended at biome borders.
* **Acacia** (new kind `acacia`): a trunk that splits into 2 diagonal
  forks, each ending in a flat leaf pad (radius 2.5–3.5, one layer with a
  smaller layer on top).
* **Baobab** (new kind `baobab`): a fat trunk (radius 1.5–2.5) bulging in
  the middle and narrowing at the top, then 5–8 short stubby branches with
  small leaf tufts.
* **Termite mound**: `rock` kind of a new `termite_mound` block, radius
  1.2–2, 3–6 tall (it narrows to a spire).
* Grass: golden tint (D2B55A), short grass 25%, tall grass 15%, a few
  dead bushes.

## Numbers in `data/biomes/45_savanna.biome`
| Item | Proposal |
|---|---|
| Climate | temperature 0.55–0.85, humidity 0.0–0.55 (below desert's priority: desert is drier and hotter) |
| Heights | 98–220 |
| Hills | ×0.4 |

## Open
* Savanna wildlife: entity milestones.

## As built (M10 part 6)
* Climate: temperature 0.52–0.85, humidity 0–0.58. Desert (priority 1) and
  oasis (priority 2) win where the boxes overlap. Savanna covers ~9% of land
  near the origin.
* Plateaus: `plateau_height = 22` on a rare `plateaus` noise mask (D63).
  Their steep sides are coarse dirt.
* Acacias (weight 40) and baobabs (weight 1), tree density 0.0019; termite
  mounds at 0.000625 per block².
* The golden grass colour needed a tint fix that also brought every earlier
  biome's colours to life (D63).
* Seed 20261009:
  * golden savanna with acacias: `--pos -280 140 -20 --look 250 -15`;
  * a plateau: `--pos -470 150 192 --look 90 -8`
    (`--survey` logs the nearest plateau top).
