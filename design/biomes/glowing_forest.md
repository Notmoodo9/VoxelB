# Glowing forest (Milestone 10, part 13)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Rare, magical pockets inside the temperate forests, glowing cyan and
teal like a bioluminescent sea:
* tall, slender glowwood trees with weeping curtains of glowing leaves;
* an airy layout with open glades, over dark blue-green grass and
  luminous moss;
* glowing bellflowers and star-flowers, glow ferns and glowcaps on the
  floor;
* small pools of cyan water and blue crystal clusters poking out of the
  ground.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Glow colour | cyan and teal: the existing glowwood look (teal bark, cyan-green luminous leaves, blue fungi) |
| Ground | dark blue-green grass and moss so the glow pops, with glowing moss patches |
| Trees | elegant, tall and drooping: slender glowwoods 10–18 tall with weeping, glowing branches like willows of light |
| Density | airy and open: a tree every ~8–10 blocks, with glades |
| Floor | glow flowers (cyan bellflowers, teal star-flowers), glowcaps, glow ferns, glowing moss patches |
| Features | glowing pools (cyan water), blue crystal clusters; fireflies later |
| Rarity | rare magical pockets of 200–400 blocks inside forests, ~1–2% of land |

## How it is built (Claude's technical proposal)
* **Placement**: a narrow weirdness band (~0.44–0.52) of the forest
  climate, priority 1, like the other forest pockets (birch groves, dark
  forests, old growth).
* **Colours**: grass 2A6A5A (deep blue-green). The glowwood leaves keep
  their own cyan colours (not tinted). Water colour 2AD8D0 (glowing cyan)
  for the pools.
* **Weeping glowwood**:
  * the existing round tree kind, with a tall slender trunk (10–18) and a
    wide crown (radius 3–4.5);
  * its `hanging_vines` are glowwood leaves themselves: curtains of
    glowing leaves 3–8 long hanging from the crown, which reads as a
    weeping willow made of light.
  * No new generator is needed.
  * Some trees use the blooming glowwood leaves for variety.
* **New blocks** (texgen, all with glow layers):
  * `glow_bellflower` (cyan bells) and `star_bloom` (teal stars);
  * `glow_fern` (a fern with glowing tips);
  * `glow_moss` (a luminous moss block, used as `top_patch`).
* **Floor**: glow ferns, short grass, glowcaps; flowers in patches
  (meadow clusters) and scattered.
* **Pools**: the pond feature at a moderate chance, with the cyan water
  colour.
* **Crystal clusters**: small `rock`s of `blue_crystal` (1–3 high).
* The glow layers make all of this read bright now. Real light (the
  forest lighting up the night) comes with M13.

## Deferred
* Fireflies (drifting light particles) wait for the particle milestone
  (M14 or later) and are recorded in BACKLOG.
* Real emitted light waits for M13.

## Open
* Nothing.

## As built (M10 part 13)
* Placement: a new independent `rarity` field (0.70–1.00, priority 2)
  instead of a weirdness band, which would have broken up the forests
  (D70). ~1.2% of land near the origin.
* The weeping curtains were first far too dense (solid walls of light).
  They are now 4.5% of crown leaves, 2–6 long.
* Seed 20261009: a glowing forest right next to spawn:
  * from above: `--pos -64 175 20 --look 180 -25`;
  * inside: `--pos -64 128 64 --look 160 -5`.
