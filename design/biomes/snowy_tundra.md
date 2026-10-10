# Snowy tundra (Milestone 10, part 8)

Status: **approved by the owner** (2026-10-10). Interview: 2026-10-10.

## Summary
Large, bright, wind-swept snowy plains in the cold, dry climate. The land
is flat to gently rolling under a full cover of dazzling white snow, with
small bare patches of gravel and frozen dirt. Scattered across it:
* low twiggy shrubs, some with red berries;
* very rare stunted snowy spruces;
* snow-capped boulders with small snow drifts;
* scattered small frozen ponds with icy blue tops.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Terrain | flat and wind-swept: wide plains, gentle rolls, occasional low hills |
| Snow | full cover, with a few bare patches of gravel and frozen dirt a few blocks wide |
| Mood | bright, crisp white with icy blue ponds: clean and vibrant |
| Shrubs | low brown twiggy dwarf shrubs, some with red berries (lingonberry-like) |
| Trees | stunted snowy spruces 4–7 tall, very sparse (one every ~60–80 blocks) |
| Boulders | grey stone/cobble 2–4 wide with a snow cap, ~1 per 50×50; rare big ones up to 6 wide |
| Ponds | small, 3–7 wide, every ~100 blocks, fully iced over (ice top, water below) |
| Special | snow drifts: small wind-shaped snow mounds |
| Size | large regions filling the cold, dry climate (~8–12% of land), next to the snowy taiga |

## How it is built (Claude's technical proposal)
* **Climate**: temperature 0.00–0.35, humidity 0.00–0.38, the cold and
  dry corner. The snowy taiga and taiga keep the wetter side.
* **Terrain**: heights 98–150, hills ×0.3, so it is flat with gentle rolls.
* **Surface**: `top_block = snow` over dirt.
  * Bare patches come from the detail noise: `top_patch = gravel`, plus a
    new second patch setting `top_patch2 = coarse_dirt` at a slightly
    different level, so the two kinds sit side by side.
* **Shrubs**: two new plant blocks, `dwarf_shrub` (brown twigs) and
  `lingonberry_shrub` (twigs with red berries), as ground plants
  (about 4% and 1.5%).
* **Spruces**: a `stunted_spruce` tree (the `conifer` kind, spruce log
  with snowy spruce needles, 4–7 tall, crown radius 1.2–1.8), ~1 per
  70×70.
* **Boulders**:
  * `tundra_boulder`: the `rock` kind in stone, with a snow upper half for
    the cap, radius 1–2;
  * a rare `big_tundra_boulder` in cobblestone, radius 2.5–3.
  * Together ~1 per 50×50.
* **Snow drifts**: `snow_drift`, a low, wide `rock` mound of snow (radius
  2–3.5, 1–2 tall), placed as bushes.
* **Frozen ponds**:
  * the pond feature, with a chance of ~1 per 100×100, radius 1.5–3.5,
    depth 2, floor gravel;
  * a new biome setting `pond_top = ice`, which turns the top water layer
    into ice.
* No grass colour is needed: everything is white.

## Deferred
* Ice spikes, glaciers and the frozen ocean are separate biomes for later.
* Cold, wind and temperature effects come in Milestone 28.
* Tundra animals wait for the entity milestones.

## Open
* Nothing.

## As built (M10 part 8)
* Climate: temperature 0.00–0.38, humidity 0.00–0.42. It was widened from
  the proposal to reach ~8.6% of land near the origin.
* Shrubs at 2% (dwarf) and 0.8% (lingonberry): half the proposal, so the
  snow reads as a full cover.
* Patches: gravel above 0.5, frozen dirt (`coarse_dirt`) below −0.5.
* Seed 20261009: the tundra with frozen ponds, patches, boulders and
  spruces: `--pos 53 175 -285 --look 0 -50`.
