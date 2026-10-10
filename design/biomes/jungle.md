# Jungle (Milestone 10, part 7)

Status: **approved by the owner** (2026-10-10). Interview: 2026-10-10.

## Summary
A hot, wet, very dense rainforest on rugged hills, the most saturated
green biome in the game. It has three layers:
* rare kapok-style giants towering over everything;
* a closed canopy of tall mid trees;
* a floor packed with leaf bushes, some ferns and bright tropical flowers.

Vines hang everywhere. Shelf fungi grow on the big trunks, and cocoa pods
on some trunks. Melon patches, bamboo groves and small pools in the
hollows are scattered through it. Jungles are medium patches in the hot,
wet climate.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Terrain | hilly and rugged: steep rolling hills, so the canopy undulates in layers |
| Density | very dense: closed canopy, dim floor, hard to walk through |
| Palette | saturated emerald and lime greens, the most vibrant biome |
| Trees | rare giant emergent trees, common mid-canopy trees, jungle bushes (no palms or tree ferns) |
| Giant trees | kapok style: 2×2–3×3 trunk with buttress roots, a tall bare trunk, a wide umbrella crown of leaf clusters on thick branches, 30–45 tall |
| Vines | lots: hanging from canopy edges and down trunk sides, some reaching the ground |
| Floor | jungle bushes plus a moderate layer of ferns and grass, so the floor is never bare |
| Flowers | heliconia (red/yellow, 2 tall), orchid (pink/purple), bird of paradise (orange/blue), hibiscus (red) |
| Fungi | shelf fungi on the sides of big trunks |
| Features | cocoa pods, bamboo groves, pools in hollows, melons |
| Cocoa and melons | uncommon: pods (1–3) on about 1 in 4 mid-canopy trunks; a melon patch every ~100 blocks |
| Bamboo | occasional groves 15–40 blocks wide every few hundred blocks; stalks 6–14 tall, tightly packed |
| Wood | mossy brown bark: the existing `jungle` wood |
| Size | medium patches, several hundred blocks across, ~6–8% of land |

## How it is built (Claude's technical proposal)
* **Climate**: temperature 0.70–1.00, humidity 0.62–1.00, the hot and
  wet corner that no biome covers yet.
* **Terrain**: heights 100–200, hills ×1.4, so it is more rugged than the
  forest.
* **Colours**: grass 2FD13F, foliage 1FB52A (emerald). Jungle leaves are
  tinted with the foliage colour.
* **Giant tree**: a new kind `kapok`:
  * a round trunk of radius 1–1.5, with 4–6 buttress fins flaring out at
    the base;
  * bare up to ~75% of its height;
  * then 4–7 thick branches spreading outward and up, each ending in a
    wide, flattish leaf cluster, plus a top cluster.
  * About 1 per 40×40 blocks.
* **Mid-canopy trees**: the existing `branching` kind in jungle wood,
  12–20 tall, crown radius 3.5–5, dense enough that the crowns touch.
* **Bushes**: the `bush` kind with jungle leaves, very common.
* **Vines**, two new blocks:
  * `vine`: a flat panel against a trunk face (the `ladder` shape,
    4 facings), in runs down the sides of big trunks;
  * `hanging_vine`: a crossed-plane strand hanging down from the
    underside of leaves, 2–12 long, sometimes reaching the ground.
* **Shelf fungi**: a new `shelf_fungus` block, a thin plate sticking out
  from trunk sides (the trapdoor plate shape), on kapoks and big trunks.
* **Cocoa pods**: a new `cocoa_pod` block on trunk sides (the `ladder`
  shape with a pod texture), 1–3 on about 1 in 4 mid trees.
* **Melons**: a new `melon` block (cube). Patches of 3–8 on the ground,
  using the meadow feature (one patch candidate per ~100×100 blocks).
* **Bamboo**: a new `bamboo` block, a thin stalk. Groves use a
  clearing-like disc feature, 15–40 wide, with dense stalks 6–14 tall and
  a few leaves at the top.
* **Flowers**:
  * `heliconia` (tall plant, 2 high);
  * `orchid`, `bird_of_paradise` and `hibiscus` (plants);
  * all new pixel-art textures in texgen.
* **Ground cover**: fern ~12%, short grass ~10%, tall grass ~4%, flowers
  ~1.5%. Jungle bushes on top of that.
* **Pools**: the pond feature with a higher chance and `pond_slope`, so
  pools sit in the hollows between hills.

## Deferred
* **Waterfalls**: they need flowing water (Milestone 15). Pools come now.
* **Cocoa and melons as food**: items, Milestone 18.
* **Jungle animals and mobs**: entity milestones.

## Open
* Nothing.

## As built (M10 part 7)
* Climate: temperature 0.55–1.00, humidity 0.50–1.00. It was widened from
  the proposal to reach ~6% of land near the origin.
* Everything above is built as proposed. Melon patches have radius 2–3.5
  and density 0.6.
* Seed 20261009: the canopy from above `--pos -150 230 60 --look 250 -20`;
  the jungle floor `--pos -150 128 60 --look 160 -8`.
