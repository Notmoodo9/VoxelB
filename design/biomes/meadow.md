# Meadow (Milestone 10, part 17)

Status: **approved by the owner** (2026-10-10). Interview: 2026-10-10.

## Summary
Sunny highland meadows on the foothills of the temperate mountains, above
the plains and forests and below the bare peaks:
* fresh mint-green grass, knee-high and waving, with clover and short grass
  between;
* pastel flowers everywhere, in big same-colour drifts sweeping across the
  slopes: lavender, blue, pink and white lupins, buttercups and the older
  flowers lower down;
* higher up the meadow turns alpine: edelweiss, gentians and alpine asters
  take over;
* lone spruces and small clumps of birch keep the views open;
* mossy boulders, mostly small with a few big ones, and small clear ponds.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Placement | alpine foothills: the gentle slopes and plateaus at the foot of mountains (roughly Y 140–230), between the plains/forests below and the bare rock above |
| Palette | lush mint grass with pastel flowers (lavender, pink, white, pale yellow) |
| Flowers | everywhere, in large same-colour drifts with mixed patches between; on ~25–35% of the ground |
| New plants | lavender and lupins (2 tall); clover and buttercups (low); edelweiss, gentians and alpine asters |
| Lupins | blue, pink and white |
| Grass | knee-high tall grass between the drifts, short grass and clover elsewhere |
| Alpine flowers | higher up only: they take over toward the top of the meadow |
| Trees | very sparse lone spruces, and small birch clumps |
| Boulders | many small mossy rocks (1–2 high) half-sunk in the grass, rare big boulders 3–5 high |
| Features | small clear ponds; beehives (later, with bees); babbling streams (later, with flowing water) |
| Size | wide bands (200–600 blocks) on most temperate foothills, ~4–6% of land |

## How it is built (Claude's technical proposal)
* **Placement**: two biome entries with the same look:
  * `meadow`: the temperate climate (temperature ~0.30–0.68, humidity
    ~0.15–0.85) at surface heights ~140–180, priority 2, so it takes the
    upper slopes from the plains and forests;
  * `alpine_meadow`: the same climate at ~181–230, with the alpine flowers.
  * The biome blending makes the change from one to the other gradual.
  * The exact bounds are tuned with the survey to reach ~4–6% of land.
* **Colours**: grass 5CD69A (mint), foliage 4CB070.
* **Flowers**:
  * the existing meadow feature (flower drifts), with a small cell (64
    blocks) and a high chance, so the drifts cover most of the ground;
  * mostly single-colour drifts, some mixed;
  * plus scattered flowers between the drifts.
  * Lower meadow: lavender, the three lupins, buttercups, oxeye daisies,
    cornflowers, alliums and pink tulips.
  * Alpine meadow: edelweiss, gentians, alpine asters, with a few
    buttercups.
* **New blocks** (texgen):
  * 2-tall plants: `lavender`, `blue_lupin`, `pink_lupin`, `white_lupin`;
  * plants: `clover`, `buttercup`, `edelweiss`, `gentian`, `alpine_aster`.
* **Grass**: tall grass ~12%, short grass ~20%, clover ~10%.
* **Birch clumps**: a new biome feature, *groves*:
  * one candidate per 128 × 128 cell (`grove_chance`), a disc of
    `grove_radius`;
  * inside it, trees use `grove_density` and their own list (`grove_tree`).
  * The meadow puts small birch groves (radius 5–9) in about a third of the
    cells. The normal tree list gives the lone spruces (very sparse).
  * Other biomes can use groves later; this needs no change to them.
* **Boulders**: a new `meadow_stone` (stone with a mossy top, radius
  0.8–1.4, 1–2 high) as the common rock, plus the existing `mossy_boulder`
  and a new `big_mossy_boulder` (radius 2.5–3.5, 3–5 high), rare.
* **Ponds**: the pond feature, clear blue water, sandy or gravel floor.

## Deferred
* Beehives on the trees wait for bees (entity milestones, M19) and go in
  BACKLOG.
* Babbling streams wait for rivers and flowing water (M15) and go in
  BACKLOG.

## Open
* Nothing.

## As built (M10 part 17)
* Built as proposed. Meadow 4.3% and alpine meadow 1.7% of land near the
  origin (6.0% together).
* Tuning after the first look:
  * grass 68D884 (a little greener than 5CD69A, which read teal);
  * drifts: one per 64-block cell, radius 12–24 (10–20 alpine), density
    0.7; scattered flowers 10%;
  * birch groves in half the cells, radius 6–10 (alpine: 20%, 4–7).
* The upper band sits mostly on steeper ground, so the alpine flowers grow
  on its flatter steps and ledges.
* Seed 20261009:
  * flower drifts, spruces and boulders: `--pos -300 172 -180 --look 300 -25`;
  * over the meadow: `--pos -250 180 -192 --look 270 -35`;
  * from above: `--pos -300 330 -200 --look 0 -89`.
