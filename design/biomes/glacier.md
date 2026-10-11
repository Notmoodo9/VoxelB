# Glacier (Milestone 10, part 19)

Status: **approved by the owner** (2026-10-11). Interview: 2026-10-11.

## Summary
Thick ice caps smother the high cold mountains, and tongues of ice flow
down their valleys:
* snow fields up high; bare packed ice and glowing blue ice lower down
  and on steep parts;
* crevasse fields across the flowing ice, with blue walls;
* sheer blue-ice cliffs at the glacier's snout and edges;
* jumbled serac towers where the ice is steep (icefalls);
* a few glowing blue ice caves inside the thick ice;
* gravel and boulder moraines along the sides and the foot, and small
  milky-turquoise meltwater lakes.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Shape | ice caps on the high cold mountains (above ~Y 200) with tongues flowing down the valleys |
| Surface | snow fields up high, bare packed and blue ice lower down and on steep parts |
| Features | crevasses, blue-ice cliffs, seracs, ice caves |
| Edges | moraines (gravel ridges with boulders) and meltwater lakes |
| Scale | 5–8 blocks on peaks and ridges; valleys filled 20–30 deep so the surface is broad and smooth; tongues reach 40–60 blocks below the cap |
| Hazards | crevasses in fields (1–2 wide, up to ~15 deep) on the steeper, flowing parts; ice caves uncommon, a few per glacier |
| Rarity | on most cold high mountains, ~2–4% of land |
| Lakes | milky turquoise |

## How it is built (Claude's technical proposal)
* **Placement**: a `glacier` biome in the cold climates (temperature
  ~0–0.25) above ~Y 200, priority 2.
  * **Tongues**: the biome can be picked by the *smoothed* surface height
    (the average over ~32 blocks around) instead of the local one (new
    setting `smooth_height`). In a valley between high ridges the
    smoothed height stays high, so the glacier biome, and its ice,
    reaches down the valley. At the mountain's foot it drops, and the
    tongue ends.
* **Ice** (new biome settings `ice_*`), per column:
  * the ice surface is the higher of the ground + 5–8 (the cap) and the
    smoothed height minus a little, so valleys fill with ice up to a
    broad, smooth surface (20–30 deep);
  * the ice ends abruptly a little inside the biome border: a sheer wall
    at the snout and edges (the blue cliffs);
  * the top layers are packed ice, deeper ice is blue ice, so cliffs and
    crevasse walls show blue; snow on top above a snow line;
  * seracs: where the ice surface is steep, it breaks into blocks with
    random heights (towers and steps).
* **Crevasses**: a ridged noise stretched across the flow gives narrow
  lines in bands; where it peaks, a 1–2 wide slot is cut 6–15 deep into
  the ice (never through it).
* **Ice caves**: 3D noise tunnels and hollows inside ice at least ~10
  thick, uncommon, so there are a few per glacier.
* **Moraines**: a band just outside the ice edge is raised by 1–3 blocks
  of gravel, with stone and mossy boulders on it.
* **Meltwater lakes**: the pond feature in the moraine band, with
  milky turquoise water (`water_color` ~4AD0C8).

## Deferred
* Real glacier flow, melting and calving would need simulation (later).
* Light from the blue ice in caves comes with the lighting milestone (M13).

## Open
* Nothing.

## As built (M10 part 19)
* Built as proposed. 3.1% of land near the origin; temperature
  0–0.33, smoothed height 160 and up (widened from 0.25 and 200, which
  gave only 0.4%). Snow on the ice above 190.
* Ice: cap 5–8, valleys filled to 3 below the smoothed height (at most 40
  thick); blue ice from 3 below the surface; edge at blend weight 0.5
  with a 0.14 moraine band 3 high.
* Seed 20261009:
  * over the glacier: `--pos 256 330 -330 --look 0 -35`;
  * its flank with seracs and crevasses: `--pos 256 215 -385 --look 340 -12`.
