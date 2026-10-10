# Swamp (Milestone 10, part 11)

Status: **approved by the owner** (2026-10-10). Interview: 2026-10-10.

## Summary
A moody bayou of tall cypresses in the warm, wet lowlands. Flared trunks
rise from shallow, murky olive-green water and carry flat, layered crowns
draped in hanging moss. Cypress knees poke out of the water around them.
The land is a maze of shallow pools and channels between low muddy,
grassy islands. Lily pads float on the water, some with white or pink
flowers, and reeds and cattails line the edges. The colours are dark
olive and teal: gloomy, but rich.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Type | bayou / cypress swamp |
| Water | half water, half land: shallow pools and channels (1–2 deep) between muddy islands |
| Mood | murky olive and teal: dark olive grass and leaves, murky green-brown water |
| Plants | lily pads, reeds and cattails, hanging moss |
| Cypress | flared trunks (2–3 wide at the water line), tall straight trunks 10–18 high, flat layered moss-draped crowns, knees poking out of the water around them |
| Density | medium, gloomy: a tree every ~8–10 blocks, broken canopy, open water lanes |
| Ground | mud and olive grass mixed, with ferns and small mushrooms near trunks |
| Water colour | murky green-brown (a biome water colour); other biomes keep blue water |
| Lilies | most pads plain, ~1 in 6 with a white or pink flower |
| Size | medium lowland patches, several hundred blocks across, ~4–6% of land, between forest and jungle |
| Extra | a witch hut, left for the structures milestone (M23) |

## How it is built (Claude's technical proposal)
* **Climate and place**:
  * temperature 0.50–0.80, humidity 0.55–1.00, priority 2;
  * only where the land is low (biome heights 90–112), so swamps take the
    wet lowlands and the forest and jungle keep the higher ground.
* **Terrain**: a new biome setting `flatten = 96.6, 0.9` pulls the land
  towards just above sea level (blended across borders). The existing
  ±2-block detail bumps then make the half-water, half-land maze: pools
  1–2 deep, filled to sea level, and low islands.
* **Shores**:
  * a new setting `own_shore = 1` makes the shore band use the biome's
    own ground, olive grass with mud patches (`top_patch = mud`), instead
    of beach sand;
  * pool floors under water are mud.
* **Water colour**:
  * water gets a third tint layer (`tint = water`), next to grass and
    foliage;
  * biomes set `water_color` (swamp 4E6A3A, murky olive);
  * every other biome keeps the reference blue.
* **Colours**: grass 5E7A3A, foliage 4E7032 (dark olive).
* **Cypress**: a new tree kind `cypress`:
  * a trunk flared at the base (radius ~1.7 tapering to a single block
    over 3 blocks), 10–18 tall;
  * 2–3 flat, layered leaf pads near the top;
  * 3–6 knees (1–2 high log stubs) around it;
  * hanging moss: the existing `hanging_vines` with a new `spanish_moss`
    block.
* **Water plants**: a new biome list `water_plant = lily_pad, 0.10` and
  `water_plant = flowering_lily_pad, 0.02`. They float on the water
  surface (pools, ponds and the sea inside the biome), using the thin
  plate shape.
* **Shore plants**: `cattail` (2 tall) and `reeds` (new), plus fern,
  short grass and a few brown mushrooms.

## Deferred
* The witch hut is left for the structures milestone (M23) and goes in
  BACKLOG.
* Fireflies and fog wait for the particle and atmosphere milestones
  (M14).
* Swamp animals and mobs wait for the entity milestones.

## Open
* Nothing.

## As built (M10 part 11)
* Climate: temperature 0.50–0.80, humidity 0.62–1.00, heights 90–104
  (narrowed from 0.55 and 112 to reach ~4.6% of land near the origin).
* Foliage 59861A: dark olive on the cypress needles (`mangrove_leaves`,
  now foliage-tinted). Cypress wood is `mangrove_log`. Knees: 1–3 per tree.
* Swamp water 4E6A3A, applied as a hue with the water's own brightness.
* Seed 20261009:
  * among the cypresses: `--pos 0 100 192 --look 200 -5`;
  * from above: `--pos 0 125 150 --look 180 -20`.
