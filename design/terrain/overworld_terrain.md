# Overworld terrain (Milestone 8)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09, 2 rounds.

## Summary
Seed-based, infinite terrain built from layered noise fields mapped
through tunable curves (splines) in `data/world/terrain.cfg`:
* rolling, varied lowlands;
* hills, mountains and high mountains at balanced rates;
* rare giant ranges of jagged alpine spires, long ridgelines and
  overhangs/arches, reaching Y ~900–1000;
* continents with about a third ocean;
* rivers carving valleys and gorges;
* mixed coasts;
* simple still water in oceans, lakes and rivers.

Surfaces follow height and slope until biomes (M10). Caves, ores and lava
are M9.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Lowlands | rolling and varied: gentle hills, meadows, some flat plains, valleys, occasional cliffs |
| Mountain tiers | balanced: hills common, mountains every few hundred blocks, high mountains in larger regions, giant ranges every few thousand blocks |
| Giant ranges | jagged alpine spires + overhangs and arches + long ridgelines with valleys and passes; never a lone peak |
| Surface | by height and slope: grass on gentle land, sand at shores, gravel/stone on steep slopes, snow high up, deep stone deep down |
| Ocean share | about a third: continents with oceans between, plus inland lakes |
| Water now | simple still water block (translucent, vibrant blue, animated surface); M15 upgrades it |
| Rivers | yes: winding rivers between oceans and through lowlands, carving valleys and gorges |
| Coasts | mixed: mostly sandy beaches, gravel shores and rocky sea cliffs where steep |

## Numbers (Claude's proposal, tunable in data/world/terrain.cfg)
| | |
|---|---|
| Sea level | 96 |
| Typical lowland height | 100–130 |
| Hills | up to ~170, every 100–300 blocks |
| Mountains | 200–350 |
| High mountains | 350–550, in regions ~1500 blocks across |
| Giant ranges | ridgelines rising to 800–1000, about 1 range per 4000×4000 blocks, each several hundred to 1500+ blocks long |
| Overhangs / arches | only in mountains and giant ranges, up to ~40 blocks of overhang |
| Snow line | ~Y 300 (± 20, noisy); bare stone where too steep for snow |
| Ocean depth | 20–50 blocks below sea level (deeper far from land) |
| Rivers | ~6–14 blocks wide, bed 3 blocks below sea level; valleys widen in lowlands |
| Beaches | sand from 2 below to 3 above sea level on gentle coasts; gravel on moderate slopes; stone cliffs on steep ones |
| Underground | grass → 3–4 dirt → stone; deep stone below Y 0 (wavy boundary); bedrock at the bottom (Y −256..−252) |

## Testing aids (engine)
* `data/world/world.cfg`: `seed`, `generator = terrain` (or `flat_test` for
  the block gallery).
* `--seed <n>` and `--flat` command-line options.
* The debug overlay shows the seed, the surface height and the noise
  values at the camera.

## Open
* Biome-specific surfaces, vegetation and trees: M10.
* Caves, ravines, aquifers, lava, ores: M9.
* Flowing water, water rendering: M15.
