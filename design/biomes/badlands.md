# Badlands (Milestone 10, part 9)

Status: **approved by the owner** (2026-10-10). Interview: 2026-10-10.

## Summary
A very rare, spectacular hot, dry wonder: flat-topped mesas and buttes
30–60 blocks high, with sheer cliffs striped in warm sunset bands, and
canyons and dry washes between them. The bands are red, orange,
terracotta, yellow, cream and brown, level across the whole region and
gently wavy. Below:
* red sand on the mesa tops and canyon floors, with sparse dry scrub;
* dead bushes, some cacti and rare bleached dead trees;
* rare striped arches and hoodoo spires.

Mesas rise sharply out of the surrounding desert. Gold ore is found much
higher than elsewhere, even exposed in the cliffs.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Terrain | mesas and canyons: flat-topped mesas and buttes, sheer striped cliffs, deep canyons and dry washes |
| Scale | mesas 30–60 high, canyons 20–40 deep |
| Stripes | warm sunset bands: red, orange, terracotta, yellow, cream, brown |
| Bands | level across the region, slightly wavy, 1–4 blocks thick |
| Ground | red sand with sparse scrub (dry grass) on mesa tops and canyon floors |
| Features | dead bushes and cacti; lone bleached dead trees; rock arches and spires; dry riverbeds |
| Arches and spires | both rare |
| Dead trees | bleached and twisted: pale grey-white bare trunks with crooked branches, 4–8 tall |
| Size | a very rare wonder: ~1–2% of land |
| Borders | cliffs rise from the desert: desert sand turns to red sand, then mesas rise sharply |
| Extra | gold-rich: gold ore much higher than elsewhere, even exposed in the cliffs |

## How it is built (Claude's technical proposal)
* **Rarity**: a pocket in the hot, dry climate (the desert and savanna
  box) at low weirdness, with the highest priority. This works the way
  the oasis does, so badlands always sit inside deserts and savannas.
* **Mesas**:
  * a new `mesas` noise field becomes a mask, which is turned into 2–3
    flat terraces with steep risers;
  * that is multiplied by the biome's blended `mesa_height` (~45) and
    added to the land;
  * low ground between mesas forms the canyons and washes.
* **Stripes**:
  * the biome lists its band blocks (`strata = ...`, using the existing
    terracotta colours plus red sand and sandstone tones) and a band
    thickness range;
  * a 128-entry band table is built from these at load, and seeded, so
    the bands are the same everywhere in the world;
  * every block of a badlands column from the top down to
    `strata_min_y` is chosen by world height, except the red-sand top;
  * a slow `strata` noise shifts the bands up and down by a few blocks:
    the gentle wave.
  * Steep surfaces show the bands instead of sand.
* **Washes**: on low ground away from the mesas, the crest lines of the
  ridged dune field become winding beds of gravel and red sand.
* **Vegetation**:
  * dead bushes, short dry grass (golden tint), some cacti;
  * rare dead trees, a twisted forked trunk with no leaves in a new
    bleached `dead_wood` log.
* **Arches and spires**: the existing `arch` and `rock` generators, with a
  new log value `strata` that colours each block by its height, so they
  are striped like the cliffs.
* **Gold**: a second gold ore record limited to badlands columns (a new
  ore setting `biome`):
  * from y 60 up to the mesa tops;
  * it can also replace band blocks (new ore setting `in_strata`), so gold
    shows in the cliffs.

## Deferred
* Abandoned mineshafts are left for the structures milestone (M23).
* Badlands animals wait for the entity milestones.

## Open
* Nothing.

## As built (M10 part 9)
* Climate: the desert box (temperature 0.62–1.00, humidity 0–0.42),
  weirdness 0–0.30, priority 3, heights 90–400. This gives ~2% of land
  near the origin.
* Mesas: `mesa_height = 54`, with the `mesas` noise at scale 200.
* Bands: red ×2, orange ×2, brown, yellow and white terracotta,
  sandstone and red sand; 1–4 thick, from y 60 up.
* The shore band is red sand too (`beach_block`), so low badlands near
  lakes stay red.
* Biome borders are now ragged for every biome (D66).
* Seed 20261009: a striped mesa cliff at
  `--pos -515 135 425 --look 355 -6`.
