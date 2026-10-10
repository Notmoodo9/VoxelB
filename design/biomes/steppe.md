# Steppe (Milestone 10, part 10)

Status: **approved by the owner** (2026-10-10). Interview: 2026-10-10.

## Summary
A wide-open, gently rolling grassland that fills the cool, dry temperate
band, the last undesigned climate. Its cool silver-green grass carries
golden tips. Tall silvery feather grass waves everywhere, among patches of
steppe wildflowers and low grey-green shrubs. The land is almost treeless,
apart from rare lone wind-bent birches. Low rocky outcrops break the
grass, and very rare ancient stone circles stand on it. Small ponds and
white salt flats sit in the hollows.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Type | steppe: open rolling grassland, big skies |
| Terrain | gently rolling: long swells, wide views, occasional low rocky ridges |
| Palette | cool sage, silver-green grass with golden-tan dry tips: vibrant, but distinct from the plains' bright green |
| Plants | tall feathery silver feather grass (signature), wildflowers in patches, low grey-green shrubs, lone trees |
| Flowers | a new steppe set: blue sage spikes, yellow yarrow clusters, pink-purple pasqueflowers |
| Trees | almost none: a lone wind-bent birch every few hundred blocks |
| Features | low rocky outcrops; stone circles (rings of 6–10 grey stones 3–5 high, ~1 per 600×600) plus occasional single menhirs; rare small ponds and white salt flats in hollows |

## How it is built (Claude's technical proposal)
* **Climate**: temperature 0.36–0.58, humidity 0.00–0.25: the gap between
  the plains, the savanna and the tundra.
* **Terrain**: heights 98–170, hills ×0.6.
* **Colours**: grass A8C46A (sage with a golden hint), foliage 8AAA60.
* **New blocks** (texgen):
  * `feather_grass` (2 tall, silvery plumes);
  * `sagebrush` (grey-green shrub);
  * flowers `blue_sage`, `yarrow`, `pasqueflower`;
  * `salt` (white crust).
* **Ground cover**: feather grass ~12%, short grass ~15%, sagebrush ~1.5%;
  wildflowers in small clusters.
* **Lone birches**: the `round` tree kind with birch wood, plus a new tree
  setting `lean` (blocks per block of height), so trunk and crown bend
  away from a prevailing east wind.
* **Outcrops**: low, wide `rock`s of stone and cobblestone.
* **Menhirs**: tall, narrow stone `rock`s.
* **Stone circles**: a new kind `stone_ring`: 6–10 stones of 1–2 blocks,
  3–5 high, evenly spaced on a ring of radius 5–8. Each stands on its own
  column's ground.
* **Ponds and salt flats**: the pond feature at a low chance, plus a new
  biome setting `dry_ponds = salt, 0.5`. Half the hollows stay dry: no
  water, with salt as the floor's top.

## Deferred
* Steppe animals (horses, herds) wait for the entity milestones.
* The stone circles have no gameplay yet. A structures or magic milestone
  can give them a purpose later.

## Open
* Nothing.

## As built (M10 part 10)
* Built as proposed. The steppe covers ~6.8% of land near the origin;
  "none" land is down to ~9.5%.
* Seed 20261009: steppe with feather grass, a salt flat, an outcrop and a
  wind-bent birch: `--pos -470 112 -560 --look 200 -6`.
