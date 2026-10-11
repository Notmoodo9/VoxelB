# River (Milestone 10, part 21)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Rivers get their own look, which changes with the land they cross:
* **River** (temperate): clear, bright blue-green water; lush grass right
  to the water's edge with reeds, cattails and tall grass; sand and gravel
  bars; willows leaning over the water; lily pads in calm stretches; long
  waving river weed on the bed; mossy stepping stones.
* **Frozen river** (cold): mostly iced over with dark open channels down
  the middle; snowy gravel banks; no plants.
* **Muddy river** (jungle and swamp): murky green-brown water; mud banks
  with big ferns and reeds; lots of lily pads; river weed.
* **Oasis river** (desert, savanna, badlands, steppe): a narrow ribbon of
  grass, reeds and palms along the water, against the sand.
* Fish come later with the entity milestones.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Variants | by climate: temperate, frozen, muddy (jungle/swamp), oasis strip (dry lands) |
| Banks (temperate) | lush grass to the edge, reeds, cattails, tall grass, sand/gravel bars, occasional willows |
| In the water | lily pads in calm bends, long waving river weed, mossy stepping stones; fish later |
| Water (temperate) | clear bright blue-green |
| Frozen | mostly frozen with open channels, snowy gravel banks, no plants |
| Muddy | murky brown-green, mud banks, big ferns, reeds, lots of lily pads |
| Dry lands | a green oasis strip with grass, reeds and palms |
| River weed | 1–2 block tall waving weed plus short tufts on the bed |

## How it is built (Claude's technical proposal)
* **Where**: the terrain already carves rivers from a river noise. The
  coarse terrain grid (every 4 blocks) keeps that river value, and every
  column gets a river class: *water* (the carved river) or *bank* (a strip
  beside it). It is world-aligned, so it matches across chunks.
* **Which variant**: each land biome names its river (`river_biome =
  frozen_river`); the default is `river`. River biomes are ordinary biome
  records that the climate never picks; only river columns use them.
* River columns take the river biome for everything per column: ground
  and shore blocks, plants, water plants, trees and water features. The
  water colour of the 4 × 4 tint cells over the river comes from it too.
  Grass and leaf colours stay the land's.
* **River weed**: new plants (`river_weed`, 2 tall, and `river_grass`
  tufts) on the riverbed under water. A new block setting `waterlogged`
  makes the mesher draw the cell as water around the plant, so there are
  no air pockets.
* **Stepping stones**: the iceberg candidate layer becomes a general
  *water feature* layer (`water_feature`, `water_feature_density`,
  `water_feature_depth`). Rocks grow from the riverbed and poke out of the
  water; icebergs keep floating at the surface.
* **Frozen rivers**: the frozen ocean's sea ice settings with small floes
  and channels.
* **Willows**: a new willow tree (drooping crown with hanging strands of
  willow leaves).
* **Survey**: logs the nearest river of each variant.

## Deferred
* Fish (entity milestones).
* Flowing water and currents (M15).

## Open
* Nothing.

## As built (M10 part 21)
* Built as proposed. River columns: the water under the sea level inside
  a river valley, plus banks (river value < 0.6, at most 4 above the
  sea).
* Changes after the first look:
  * palms and willows stood in the water, so own-shore biomes now put
    trees in water only with `trees_in_water` (swamp, muddy river);
  * lily pads halved in temperate rivers (0.02).
* Variants by land biome:
  * frozen: snowy taiga, snowy tundra, ice spikes, glacier, frozen ocean;
  * muddy: jungle, swamp;
  * oasis: desert, oasis, savanna, badlands, steppe;
  * every other biome: the temperate river.
* Seed 20261009:
  * temperate river: `--pos -128 118 -165 --look 0 -30`;
  * oasis river: `--pos -576 135 175 --look 0 -30`;
  * frozen river: `--pos -1408 140 -330 --look 0 -35`.
