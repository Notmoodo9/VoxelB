# Biome system (Milestone 10)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Biomes are picked by climate (temperature, humidity) and height, defined
entirely in data files (`data/biomes/*.biome`). They blend smoothly and
vary in size per biome. Individual biomes are interviewed and built one
at a time, plains first.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Size | mostly medium-small (~300–1000 blocks), set **per biome**: some biomes are much smaller, some are massive |
| Borders | smooth terrain transitions like vanilla; trees and plants thin out gradually over 30–60 blocks; occasional transition biomes (forest edge, desert scrubland); sharp borders allowed where geography explains it (rivers, cliffs) |
| Layout | climate + height: temperature and humidity maps choose the climate family; height and slope pick mountain/alpine and coast variants; desert never touches snow; fantasy biomes are rare pockets |

## How it works (engine, Claude's proposal)
* **Climate fields:** large-scale noise for temperature and humidity (plus
  a "weirdness" field for rare fantasy pockets), in `data/world/biomes.cfg`.
* **Biome choice:** each biome file declares its climate box
  (temperature/humidity ranges), allowed heights, and a size factor. The
  biome nearest to the sample's climate wins. A per-biome size factor
  scales the climate noise locally so some biomes form bigger or smaller
  areas.
* **Blending:** colours (grass, leaves, water, fog later) blend over a
  ~32-block radius. Terrain shape changes per biome (e.g. flatter plains)
  blend the same way. Vegetation density fades across the border band.
* **Sharp borders:** a river or a steep cliff between two biomes cuts the
  blend.
* **Tinting:** grass, leaves and water get per-column biome colours (a
  per-column colour map sent with the chunk), so blends cost nothing at
  draw time.
* **Vegetation and trees:** each biome lists its ground cover, flowers and
  tree types with densities. Tree shapes are data (generator kind +
  parameters). Placement is hash-based so chunks stay deterministic.

## Still to design (one at a time, see BACKLOG)
Forest, birch forest, dark forest, meadow, river; then hot/dry, cold and
fantasy biomes; transition biomes.
