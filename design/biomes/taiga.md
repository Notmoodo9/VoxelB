# Taiga + snowy taiga (Milestone 10, part 5)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Large, dense, cool-green spruce forests: tall conical spruces in shrinking
tiers, ferns and grass, red berry bushes, mossy cobblestone boulders and
brown needle litter around the trunks. In the colder parts it turns into a
snowy taiga: snow-covered ground, spruces with snowy needles, fewer plants.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Look | classic taiga with a snowy variant in colder areas |
| Size / density | large and dense: a spruce every ~5–7 blocks, darker inside |
| Spruces | tall conical, layered: 8–16 tall, tiers shrinking to a pointed tip |
| Floor | ferns + grass, red berry bushes, mossy boulders, needle litter |
| Colours | cool deep green (slightly blue-green grass, dark needles) |
| Snow | a separate colder snowy taiga: snow-covered ground, snowy spruce leaves, fewer plants |
| Berries | red berry bushes (decoration now, food later) |

## How it is built (Claude's proposal)
* **Spruce** (new tree kind `conifer`): trunk 8–16; needles start ~1/4 up
  in tiers: each tier is a disc of leaves whose radius shrinks toward the
  top (2.5–3 at the bottom tier to 0 at the tip), every second layer
  slightly smaller so the edges look layered; a single needle block tip.
* **Needle litter**: new block `spruce_needle_floor` (brown needles over
  dirt) within 2 blocks of trunks, 70%.
* **Berry bush** (new block `berry_bush`, plant shape): a low leafy bush
  with red berries, 1.5% of the floor.
* **Mossy boulders**: `rock` kind of cobblestone with mossy patches
  (`mossy_cobblestone` on the upper discs), radius 1.5–2.5, 2–3 high,
  ~1 per 50×50 blocks.
* **Snowy taiga**: snow top block, spruces with `spruce_snowy_leaves`
  (exists), ferns rarer, berries rare, a thin snow layer on everything is
  not yet possible (no snow layer block) — the snow block covers the
  ground only.

## Numbers in `data/biomes/50_taiga.biome`, `51_snowy_taiga.biome`
| Item | Taiga | Snowy taiga |
|---|---|---|
| Climate | temperature 0.15–0.38, humidity 0.35–1.0 | temperature 0.0–0.20, humidity 0.35–1.0 |
| Heights | 98–260 | 98–300 |
| Colours | grass 4E9E5A, foliage 2F6E3E | grass 6AA88A, foliage 3C7050 |
| Trees | spruce ~1 per 36 blocks² | ~1 per 50 blocks² |
| Floor | fern 20%, grass 15%, berry 1.5% | fern 4%, berry 0.3% |

## As built (M10 part 5)
* Taiga covers ~20% of land near the origin, snowy taiga ~7%.
* The snow ground switches at the biome border (the biome with the larger
  blend weight decides the top block), so it is a sharp line; a softer
  snow edge can come with snow layers (M25).

## Open
* Snow layers on leaves and ground plants: with weather (M25).
* Berries as food: items milestone (M18).
