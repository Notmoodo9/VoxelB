# Dark forest (Milestone 10, part 12)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Mysterious pockets deep inside the wet temperate forests: tall, gnarled
dark-oak giants 20–30 high whose thick trunks twist and lean as they rise
and split into crooked, sprawling branches. Their dense, very dark crowns
close a roof over the forest. Smaller dark oaks and dark bushes fill the
gaps. Below lies a dim floor of deep green grass and dark leaf litter,
with ferns, small mushrooms, moss patches, exposed roots and fallen logs.
Rare clusters of softly glowing mushrooms grow near the roots.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Trees | tall gnarled giants: 20–30 tall, thick 2×2 to 3×3 trunks that twist and lean, 3–5 long crooked branches, knotted roots |
| Density | giants every ~12–15 blocks, smaller dark oaks and dark bushes between, so the canopy closes |
| Darkness | very dim: closed canopy, dark leaves (real darkness comes with lighting in M13) |
| Floor | small mushrooms and ferns on dark leaf litter; moss patches, exposed roots and logs; rare glowing fungi |
| Glowing fungi | rare small clusters, every ~40 blocks |
| Palette | deep green and brown: very dark emerald leaves, dark brown trunks, deep green grass (rich, not grey) |
| Placement | pockets of 200–500 blocks inside wet temperate forests, ~3–4% of land |

## How it is built (Claude's technical proposal)
* **Placement**: the forest's climate box at mid-low weirdness
  (0.21–0.40, between the birch groves and the main forest), priority 1.
  This works like the old-growth and birch-grove pockets.
* **Colours**:
  * grass 2E7A2A (deep green);
  * foliage 1E6A22 (very dark emerald) on `dark_oak_leaves`, which
    becomes foliage-tinted;
  * the `dark_oak` wood exists already.
* **Gnarled giant**: a new tree kind `gnarled`:
  * the trunk is a disc of radius `base_radius` (1.0–1.6) tapering
    upwards, whose centre drifts: it turns every few blocks, so the trunk
    twists and leans;
  * 3–5 knotted roots arch out at the base;
  * 3–5 branches leave between 55% and 85% of the height and change
    direction every 2 blocks (crooked), rising slowly for 6–10 blocks,
    each ending in a dense crown cluster;
  * plus a top crown.
* **Understorey**: smaller dark oaks (`branching`, 6–9 tall), dark-oak
  bushes, fallen dark-oak logs and mossy stumps.
* **Floor**:
  * dark leaf litter around trunks (the existing litter feature, with
    ferns and red and brown mushrooms on it);
  * moss patches (`top_patch = moss_block`);
  * ferns and short grass elsewhere.
* **Glowing fungi**:
  * a new plant `glowcap`: small pale-blue glowing mushrooms, with a glow
    layer so they read bright now and give real light in M13;
  * placed in small clusters with the meadow feature (32-block cells,
    radius 1.5–2.5).
  * The clusters are not tied to roots: on the dim floor near giants they
    read the same, and it keeps them data-driven.

## Deferred
* Real darkness under the canopy, and light from the glowcaps, come with
  M13 (lighting).
* Mobs that like the dark (later hostile-mob milestone).

## Open
* Nothing.

## As built (M10 part 12)
* Built as proposed; ~3.1% of land near the origin.
* Glowcaps also grow in the leaf litter around trunks (`shade_plant`,
  1.2%), because litter covers most of the dense floor; that puts them
  near the roots.
* Seed 20261009: a dark forest pocket at `--pos 512 160 1080 --look 200 -25`.
