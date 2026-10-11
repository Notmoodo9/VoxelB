# Frozen ocean (Milestone 10, part 18)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
The cold seas freeze over:
* a patchwork of broken pack ice: floes of packed ice, many with snow on
  top, separated by dark channels of deep teal-blue water;
* low pressure ridges where floes meet;
* the ice is most solid in the cold heart and opens up toward the warmer
  edges;
* icebergs rise from the pack: many small ones, some tall jagged ones
  15–30 high, and rare giant flat-topped (tabular) bergs, in packed ice
  with blue-ice streaks and snow on top;
* the shores are snow-dusted gravel and stone, with ice frozen along the
  shoreline;
* the sea floor is cold gravel and clay with stony patches.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Order | frozen ocean first; glaciers get their own interview next |
| Surface | broken pack ice: floes with open-water channels; solid in the cold heart, open near warmer edges |
| Icebergs | varied: many small, some tall jagged 15–30 high, rare giant tabular ones; packed ice with blue-ice streaks, snow on top |
| Water | deep cold teal-blue |
| Extent | all cold seas (next to tundra, snowy taiga, ice spikes), fading to open water toward warmer seas |
| Shores | snowy gravel and stone, with shore-fast ice along the shoreline |
| Floes | a mix of snow-covered and bare packed ice, with small pressure ridges |
| Sea floor | gravel and clay with stony patches, no plants |

## How it is built (Claude's technical proposal)
* **Placement**: a biome for ocean heights (sea floor up to the shore,
  height ≤ 99) in the cold climates (temperature 0–0.36, any humidity).
  Mushroom islands (priority 3) keep their pockets.
* **Water colour**: `water_color` deep teal-blue (~2A6A8A).
* **Pack ice** (new biome settings, `sea_ice*`):
  * floes are Voronoi cells (~14 blocks across) at the sea surface;
  * the 1–2 block band where two cells meet stays open water (the
    channels);
  * each floe is frozen with a chance (`sea_ice_cover`) scaled by the
    biome's blend weight, so the pack thins out toward the warmer border;
  * a share of floes is snow-covered, the rest bare packed ice;
  * pressure ridges: packed ice one block above the surface in places
    along floe edges;
  * shore-fast ice: shallow water near the shore is always frozen.
* **Icebergs**: a new tree kind `iceberg`, placed by a new biome list
  (`iceberg`, `iceberg_density`) on deep water only:
  * a body of packed ice with blue-ice streaks above and below the
    water, and snow on the flat parts of the top;
  * jagged bergs: a peaked, noisy profile; tabular bergs: a flat top
    with steep sides;
  * data entries: small (3–8 high), tall jagged (15–30), rare giant
    tabular (10–16 high, 12–20 wide).
* **Shores**: `beach_block = gravel` with a new `beach_patch` setting
  (snow dusting, and stone in places).
* **Sea floor**: new settings `seabed_block = gravel`, and
  `seabed_patch = stone`; the clay patches stay.

## Deferred
* Seals, polar bears, walruses and other arctic animals come with the
  entity milestones.
* Floes that drift or break, and ice that melts or freezes with the
  seasons, would need simulation (later milestones).

## Open
* Nothing.

## As built (M10 part 18)
* Built as proposed. 21% of the sea within 2 km of the origin is frozen.
* Changes after the first look:
  * the floes looked like tiles: their edges are now frayed by the detail
    noise, and the channel width varies per floe (0.5–1.5×);
  * ridges were scattered single blocks: they now run as short lines
    along the edge between two floes (30% of floe pairs);
  * the shores of a frozen sea mostly belong to the cold land biomes, so
    snowy tundra, snowy taiga and ice spikes also got the snowy gravel
    shore (`beach_block = gravel`, `beach_patch = snow, 0`).
* The pack ice is one block thick (at the sea level).
* Mushroom islands can appear inside a frozen sea; they are rare and keep
  their own look.
* Seed 20261009:
  * over the pack ice and icebergs: `--pos 300 150 60 --look 330 -25`;
  * at sea level among the floes: `--pos 330 110 120 --look 320 -5`;
  * the snowy gravel shore and shore-fast ice: `--pos 192 200 60 --look 0 -40`.
