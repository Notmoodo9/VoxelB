# Mushroom fields (Milestone 10, part 15)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Rare islands far out in the ocean, carpeted in purple-grey mycelium with
pink spore speckles:
* giant mushrooms grow everywhere: red domes with white spots, wide flat
  brown caps and some glowing blue ones;
* very rarely, a colossal mushroom 15–25 tall with a cap 15+ wide;
* shelf fungi cling to the giant stems, and round white puffballs dot the
  ground;
* sandy beaches ring each island.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Placement | rare islands in the ocean (a lucky find) |
| Ground | purple-grey mycelium with pink spore speckles |
| Giant mushrooms | classic red domes, flat brown caps, rare colossal ones, some glowing blue |
| Extras | shelf fungi on the stems, puffballs, spore haze later |

## How it is built (Claude's technical proposal)
* **Placement**:
  * the biome covers only ocean-floor heights (below sea level), in the
    rare end of the `rarity` field (0.80–1.00), any climate;
  * it lifts its own ground out of the sea with the existing `flatten`
    setting (level 104, full pull), so each pocket of the rarity field
    becomes an island with a natural shoreline;
  * islands are a few hundred blocks across with gentle hills.
* **Ground**: a new `mycelium` block (purple-grey top with pink specks,
  dirt sides with a purple fringe) as the top block, over dirt. The shores
  keep beach sand.
* **Giant mushrooms**: a new tree kind `mushroom`:
  * a stem (TREE.log) of `base_radius` (1 block, or 2–3 for colossal),
    `height` tall;
  * a cap (TREE.leaves) of `radius`;
  * `chance` picks the cap shape: a dome (red, glowing) or a flat wide
    disc (brown);
  * a gills ring under the cap (the existing `*_gills` blocks).
  * Kinds in data: red (6–12 tall, cap 3–5), brown (6–10, flat cap 4–7),
    glowing (5–9, dome 3–4), and colossal red and brown (15–25 tall, caps
    7–10, stems 2–3 wide, very rare).
* **Shelf fungi**: the existing `fungus` tree setting on the giant stems.
* **Puffballs**: a new `puffball` plant (round white), plus small red and
  brown mushrooms, as ground cover.
* **Survey**: logs the nearest mushroom island.

## Deferred
* The spore haze (floating particles) is recorded in BACKLOG for the
  particle milestone.
* Mooshroom-like animals, if wanted, come with the entity milestones.

## Open
* Nothing.

## As built (M10 part 15)
* Placement: ocean floor up to height 86, rarity 0.66–1.00, priority 3,
  flatten 110 / 0.9. Smaller pockets were lost in the biome blending
  (D72). Islands are a few hundred blocks long with beaches all round.
* Seed 20261009: a mushroom island near spawn:
  * from above: `--pos 192 320 256 --look 0 -89`;
  * among the mushrooms: `--pos 230 125 300 --look 220 -8`.
