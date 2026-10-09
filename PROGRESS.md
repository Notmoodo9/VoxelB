# Progress

## Current state
**Milestone 10 (part 3): 🎨 DESIGN — Birch grove: DONE** (Windows CI: see below)

Next: **Milestone 10, part 4: the next biome**. Candidates are dark
forest, meadow, river, or the first hot/dry or cold biome
(`design/BACKLOG.md`). It starts with its design interview.

---

## Milestone 10, part 3 — done (2026-10-09)

### Design interview
Two rounds plus approval: `design/biomes/birch_grove.md`.
* Small, bright and airy birch groves (100–300 blocks) inside about one in
  every few forests.
* Tall white birches every 6–9 blocks with light yellow-green leaves.
* A sunlit flowery floor, rare bluebell carpets, mushrooms and fallen
  birch logs.

### What was built
* **Biome** `data/biomes/32_birch_grove.biome`: a rare pocket in the
  forest's climate (low weirdness, priority 1), on ~0.9% of land near the
  origin.
* **Three new flowers** (texgen): `lily_of_the_valley`, `bluebell`,
  `wood_anemone`.
* **Bluebell carpets** (D60): meadows got a per-biome cell size and flower
  list (`meadow_cell`, `meadow_flowers`).
* **Fallen birch logs** (`fallen_birch` in `10_trees.biome`).

### How to see it (seed 20261009)
* A birch grove from above: `voxelb.exe --pos 640 175 1130 --look 0 -25`.
* Its floor (bluebells, white flowers, mushrooms):
  `voxelb.exe --pos 640 150 1088 --look 20 -30`.

### Verified
* Debug and release headless tests pass.
* Screenshots:
  * the grove from above;
  * the floor with bluebells, white flowers, a red mushroom and a fallen
    birch log;
  * bluebell carpets, checked with the carpet chance and radius raised
    temporarily.

### Performance
Same as part 2 (columns ~11–13 ms to generate, ~10–11 ms to mesh; ~3–4
FPS on software GL in forest views).

### Known issues
* The survey's "nearest meadow" only knows 512-block meadows, so it does
  not point at bluebell carpets.

---

## Milestone 10, part 2 — done (2026-10-09)

### Design interview
Three rounds plus approval: `design/biomes/forest.md` and
`design/biomes/old_growth_forest.md`.

Forest:
* a large, common mixed oak forest in rich deep green;
* oaks with tall slim birches and round maples (some in autumn colours);
* dense, with clearings;
* ferns, leaf litter near trunks, mushrooms, fallen logs and mossy stumps.

At approval the owner added old growth: "massive old growth trees with
huge trunks… rarer but magnificent", realistic giants that taper ("a giant
trunk then it gets to a 3x3 … and then branches"). The design:
* rare old-growth hearts inside about 1 in 6 forests;
* giant oaks over an understorey of smaller trees;
* moss and ferns, huge roots, mushroom rings, a dim feel.

### What was built
* **Log axis states** (D57): logs lie along X or Z. Fallen logs, roots and
  branches use them, which fixes part 1's end-grain branches.
* **Rare pockets** (D58): a third climate field (weirdness) and a biome
  `priority`.
* **Giant trees** (D59, `kind = giant`):
  * tapering disc trunks with a flared base;
  * arching roots;
  * heavy branches with leaf clusters, and a crown;
  * 30–65 tall.
* **Fallen logs and stumps** (`kind = fallen | stump`).
* **Forest floor**:
  * leaf-litter patches near trunks with shade plants (ferns, mushrooms);
  * clearings without trees, with flowers;
  * mushroom rings;
  * top patches (moss).
* **New blocks**: `fern` (grass-tinted), `red_mushroom`, `brown_mushroom`,
  `moss_block`, `mossy_oak_log`.
* **Data**: `data/biomes/30_forest.biome`,
  `31_old_growth_forest.biome`, and new trees in `10_trees.biome`
  (birch, maple, autumn maple, fallen oak, mossy stump, giant oak, fallen
  giant). Everything is documented in DATA_FORMAT.md.
* `--survey` also gives the nearest place well inside each biome.
* The heightmap border grew to 22 blocks (trees reach 20 blocks).

### How to see it (seed 20261009, the default)
* Forest next to spawn: `voxelb.exe --pos -64 175 60 --look 330 -30`.
  Oaks, white birches and red autumn maples, litter patches.
* Forest floor: `voxelb.exe --pos -90 142 40 --look 300 -45`.
* Old-growth giants on a coast:
  `voxelb.exe --pos 790 200 640 --look 330 -18`.
* Under the giants (roots, flared trunks):
  `voxelb.exe --pos 780 132 600 --look 320 5`.
* `voxelb.exe --survey` for other seeds.

### Bugs found and fixed while testing
* The first giants had thin, short branches and narrow crowns. Branch
  length, count, start height, leaf clusters and base radius were raised.
  The tree reach and heightmap border grew with them, so crowns are not cut
  at chunk borders.
* The survey's "nearest sample" landed on thin biome slivers. It now
  needs the neighbouring sample to be the same biome.
* Moss looked like grass; the moss block is now yellow-olive.
* The new biome choice code used xmm6, a callee-saved register; changed to
  a stack slot.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* Debug and release headless tests pass, with clean exits and no warnings.
* Screenshots:
  * the forest from above;
  * the forest floor (ferns, litter, birch bark);
  * old-growth giants from the air and from the ground (flared trunks,
    roots, branches, wide canopies);
  * moss ground.

### Performance (release, llvmpipe, render distance 16)
| | |
|---|---|
| Column generation | avg 11–13 ms (max ~60 ms in old-growth) |
| Column meshing | avg 10–12 ms |
| Spawn view | ~4 FPS (software GL) |
| Old-growth view | ~3 FPS, ~450k quads drawn |

### Known issues
* Mushroom rings are rare to stumble on; their chance is per 128×128
  cell, inside old growth only.
* Mist in old-growth waits for fog (M14).
* Over half the land is still "none" until more biomes exist.

### Deferred
* Forest edge transition biome; other temperate, hot, cold and fantasy
  biomes: later M10 parts, one interview each.

---

## Milestone 10, part 1 — done (2026-10-09)

### Design interview
Three rounds plus approval, recorded in `design/biomes/biome_system.md` and
`design/biomes/plains.md`.

Biome system:
* sizes set per biome (mostly medium-small, some massive);
* vanilla-like smooth borders with vegetation thinning over 30–60 blocks,
  occasional transition biomes, sharp edges at rivers and cliffs;
* layout by climate + height.

Plains:
* bright spring-green grass with waving short and tall grass;
* the classic flowers (poppy, dandelion, cornflower, oxeye daisy, allium,
  four tulips) in small clusters;
* rare meadows (single-colour and rainbow);
* very sparse varied oaks (small round, occasionally big branching);
* plain and flowering bushes;
* occasional small ponds;
* gentle hills.

### What was built
* **Biome engine** (`src/world/biome.asm`, D53):
  * data-driven registry: `data/biomes/*.biome` with `[climate]`,
    `[noise …]`, `[tree …]` and `[biome …]` records (DATA_FORMAT.md);
  * temperature/humidity climate fields; biomes picked by climate box and
    height;
  * a blurred per-chunk blend map that drives hills, colours and
    vegetation density.
* **Biome colours** (D54): a world-space tint map (one texel per 4×4
  blocks, linearly filtered), filled per column. Blocks opt in with
  `tint = grass | foliage [, faces]`: grass block tops, oak leaves, grass
  plants.
* **Plants** (D55): new `plant` (crossed planes) and `tall_plant` shapes
  that bend in the wind from the ground. 12 new blocks: `short_grass`,
  `tall_grass`, nine flowers and `flowering_oak_leaves`, with textures in
  `tools/texgen/texgen.py`.
* **Flora** (`src/world/flora.asm`, D56), consistent across chunk borders:
  * ponds dug into the terrain with grassy banks and mud floors;
  * ground cover, flower clusters and meadows;
  * trees and bushes from data-driven generators (`round`, `branching`,
    `bush`).
* **Terrain**: the heightmap border grew from 1 to 16 blocks; biomes scale
  the hills; biomes may override top and filler blocks.
* **Debug overlay**: a `biome` line (name, temperature, humidity).
  `--survey` also logs biome shares and the nearest meadow and pond.

### How to see it (seed 20261009, the default)
* Start the game: you spawn on a plains coast with grass, flowers and a
  bush or two.
* A rainbow flower meadow next to a river:
  `voxelb.exe --pos -95 110.5 -70 --look 30 -25`.
* A small pond: `voxelb.exe --pos 56 116 -80 --look 330 -45`.
* A plains / unbiomed border from above (colours and vegetation fade):
  `voxelb.exe --pos 0 260 80 --look 0 -35`.
* `voxelb.exe --survey` lists biome shares and places for other seeds.
* Lone trees are deliberately rare (about one per 100×100 blocks). To see
  many at once, raise `tree_density` in `data/biomes/20_plains.biome`
  (e.g. to 0.004) and restart.

### Bugs found and fixed while testing
* A register clobbered by a macro gave a worker crash (stack overflow in
  Wine) on the first pond. Found with Wine's `+seh` trace and the
  disassembly at the faulting address.
* Plant planes read the texture entry of the *next* block (face codes 6/7
  index past the block's 6 faces), so flowers showed other blocks'
  textures. Plants now use face 0's texture.
* `glTextureStorage3D` got its depth in the wrong argument slot (GL debug
  error); fixed.
* Pond rims turned to stone (the steep-slope rule saw the dug hole);
  pond neighbours are now ignored when choosing slope blocks.
* Bush crowns could hang over ponds; trees keep a wider distance and ponds
  are listed further out.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* Debug and release headless tests pass, clean exits, no GL errors.
* Screenshots:
  * plains at spawn;
  * a dense rainbow meadow;
  * flowers up close (all nine distinct);
  * a pond;
  * round and branching oaks and flowering bushes (with density raised
    for the test);
  * the colour blend at a biome border.

### Performance (release, llvmpipe, render distance 16)
| | |
|---|---|
| View complete at spawn | 7.4 s (M9: 7.1 s) |
| Column generation | avg 11–12 ms (M9 ~10–12; blend map + flora + wider border) |
| Column meshing | avg 11 ms |
| Spawn view | ~450 sections, ~300k quads drawn; 4 FPS on software GL (M9: 7) |
| `stream_update` | avg 40–90 µs |

Plants add many two-sided cutout quads (meadows especially), and software
GL fills them slowly. GPU-driven rendering (M11) and LOD (M12) are the
planned performance work. A plant-density setting in graphics.cfg could
follow if needed.

### Known issues
* Most land is still "none" (plain terrain) until more biomes are
  designed. Plains covers ~23% of land near the origin.
* Logs have no axis states yet, so big-oak branches show end grain on
  their sides.
* Ponds need a flat rim; on terraced hills few qualify.

### Deferred
* Other biomes, transition biomes and biome-specific trees: the next M10
  parts, one interview each.
* Reeds/sugar cane at pond edges, berries on bushes (later items/farming).

---

## Milestone 9 — done (2026-10-09)

### Design interview
Three rounds plus approval, recorded in `design/terrain/underground.md`:
* a rich underground: huge caverns (bigger and hotter deeper), winding
  tunnels, narrow passages, vertical shafts;
* cave mouths in hillsides and valleys, rare dramatic ravines, and every so
  often a massive cavern open to the sky;
* underground lakes and deep lava lakes;
* stalactites, stalagmites, pillars, varied floors;
* classic + fantasy ores with deep variants, mountain emeralds, a cave-wall
  bonus, deep-only rarities.

Later, with their own interviews (in `design/BACKLOG.md`): underground
fantasy biomes and underground structures.

### What was built
* **Blocks** (`data/blocks/05_underground.blocks`, 17 new):
  * `lava`: animated, glowing;
  * `dripstone_block`, and `pointed_dripstone` with the new `spike` shape
    (hanging/standing; base, middle and tip chosen automatically);
  * 14 ores: coal, copper, iron, silver, gold (each with a deep variant
    where they reach deep stone), emerald, diamond, mythril, adamantite,
    and a glowing star crystal.
  * Textures come from `tools/texgen/texgen.py`.
* **Cave generator** (`src/world/caves.asm`, D48), all numbers in
  `data/world/caves.cfg`:
  * caverns from 3D noise with a height spline, bigger deeper; natural
    pillars;
  * tunnels and narrow passages;
  * cave mouths where the entrance field allows;
  * ravines (rare, 30–80 deep, narrowing);
  * round vertical shafts (D50);
  * sky caverns: an open bowl up to 140 deep over a pillared cavern (D50);
  * aquifer regions with lake levels; flooded caves under the sea; lava
    levels below Y −90;
  * a rock barrier wherever fluids would stand as a wall (D49);
  * dripstone, and gravel/clay/mud floor patches.
* **Ores** (`data/world/ores.cfg`, D52): clusters per section by height
  with a peak, large veins, mountain-only emerald, bonus attempts on cave
  walls, deep-stone variants, deep-only rarities.
* **Cave culling** (D51): the mesher stores which faces of each section
  are connected through open space. The renderer walks visible sections
  from the camera, Minecraft-style, so caves hidden in rock are not drawn
  (spawn view: 262k of 4.0M quads).
* `--survey` also logs the nearest sky cavern, ravine and shaft.
* Streaming: the number of jobs in flight scales with frame time.
* Tests: section connectivity self test (straight and bent tunnels).
  Smoke-test autoclose is now 20 s (the view needs ~7 s on software GL).

### How to see it (seed 20261009, the default)
* Sky cavern, from above: `voxelb.exe --pos -1010 260 -64 --look 0 -89`.
* From its rim: `voxelb.exe --pos -896 135 40 --look 0 -25`.
* On the cavern floor (dripstone forest, pillars, gravel/clay/mud):
  `voxelb.exe --pos -1000 0 -64 --look 120 -10`. Fly down from there
  (Shift) and east for the deep lava lakes around Y −150.
* Ravine running into the sea: `voxelb.exe --pos -288 135 -330 --look 0 -35`.
* Shaft (3 wide, near the spawn): `voxelb.exe --pos 137 160 -68 --look 0 -89`
  (the plus-shaped hole right of centre).
* `voxelb.exe --survey` lists them for other seeds.

### Bugs found and fixed while testing
* The visibility walk first over-culled. A section remembered only the
  first entry face and path, so a second path that could see further was
  ignored. It now keeps all entry faces and allowed directions (D51). A
  Python re-check of dumped sections confirmed the mesher's connectivity
  bits.
* Some test views showed "holes" only because the camera was inside rock
  (seeing through it). The test positions now start in open air.
* Aquifer water stood as walls at region borders; now rock barriers (D49).
* Shafts were long thin cracks and sky caverns were small pits; reworked
  (D50).
* Edge cells evaluated noise for neighbours outside the chunk (gen spikes
  to 223 ms); now a precomputed ring of edge columns (max ~40 ms).

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* Debug and release headless tests pass (self tests including section
  connectivity, clean exits).
* Screenshots: the sky cavern bowl from above and from its rim; a cavern
  floor with dripstone, pillars and floor patches; deep lava lakes; a
  ravine; a shaft; the spawn view unchanged.

### Verified on Windows (GitHub Actions run #18)
* Debug and release build and smoke tests pass (self tests including
  section connectivity, terrain generator loaded, view complete, clean
  exit).

### Performance (release, llvmpipe, render distance 16, 3 workers)
| | |
|---|---|
| View complete at spawn | ~7.1 s (M8: 1.3 s) |
| Column generation | avg 9.4–12.7 ms (max ~40 ms) |
| Column meshing | avg 11–14 ms |
| Spawn view | 446 sections, 262k quads drawn of 4.0M; 7 FPS (140 ms) |
| Sky cavern view | 543 sections, 332k quads; 4 FPS |
| Cavern floor view | 223 sections, 206k quads; 6.5 FPS |
| `stream_update` | avg 40–55 µs |

Software GL is the limit (frame time is linear in drawn quads, about 0.45
µs per quad on llvmpipe). Underground sections are now all real voxels,
which multiplied generation and meshing work by ~5. Both run on the
workers, so the main thread stays smooth, but the first view takes longer.
GPU-driven drawing with Hi-Z occlusion (M11) and LOD (M12) are the
planned answers.

### Known issues
* A camera inside solid rock sees through it (no faces between solid
  blocks) and shows culling holes. This is normal for a spectator-like
  view.
* Ores are sparse with the design's numbers (~0.2% of rock); tune
  `per_section` if they feel too rare.
* Natural pillars under sky caverns end flat at the bowl's depth.
* Lava and star crystal glow only through their textures until lighting
  (M13).
* Fluids are static (flowing water/lava: M15).

### Deferred
* Underground fantasy biomes and underground structures (own interviews).
* Cave lighting and darkness (M13), cave ambience (M24).
* Ore uses and tool tiers (M18).

---

## Milestone 8 — done (2026-10-09)

### Design interview
Two rounds plus approval, recorded in `design/terrain/overworld_terrain.md`:
* rolling, varied lowlands;
* balanced mountain tiers;
* giant ranges with jagged alpine spires, overhangs and arches, and long
  ridgelines;
* surfaces by height and slope;
* about a third ocean;
* simple still water now;
* rivers carving valleys;
* mixed coasts.

### What was built
* **Noise** (`src/core/noise.asm`, D44): seeded 2D/3D gradient noise and
  fractal sums (plain and ridged), exact far from the origin.
* **Terrain generator** (`src/world/terrain.asm`, D45):
  * 11 noise fields and 6 splines from `data/world/terrain.cfg`;
  * oceans, coasts, lowlands, hills, mountains, high mountains and rare
    giant ridgelines up to ~1000 with jagged spires;
  * river valleys and gorges;
  * 3D overhangs in mountains;
  * surfaces by height and slope: grass/dirt, sand beaches, gravel shores
    and scree, stone cliffs, snow above ~300 with full snow caps higher;
    a sand/gravel/clay sea bed;
  * stone, deep stone below ~0 (wavy), and a bedrock floor;
  * water up to sea level.
* **Speed** (D46): coarse-grid sampling plus per-block detail (4.6 → 2.2
  ms per column); uniform sections are skipped.
* **World settings**: `data/world/world.cfg` (`seed`, `generator`).
  Command-line options:
  * `--seed <n>`;
  * `--flat` (the block gallery world);
  * `--survey` (logs the shares of ocean, hills, mountains and so on, and
    the coordinates of the highest point, the nearest giant range and the
    nearest river).
* **Spawn**: the camera starts above land near the origin.
* **Debug overlay**: a `terrain` line shows the seed, the surface height
  and the noise values (continentalness, erosion, peaks, giant, river) at
  the camera.
* **Water block** with an animated texture (D47); lighter distance fog.
* Smoke tests check that the terrain generator loads.

### How to see it (seed 20261009, the default)
* Start the game: you spawn on a coast near the origin, with rolling
  hills, a beach and the sea.
* River valley: `voxelb.exe --pos -64 140 20 --look 0 -25`.
* Giant range (highest point 993 at x 1408, z 2816):
  * `voxelb.exe --pos 1300 760 2990 --look 10 -12` — inside a pass between
    snowy spires;
  * `voxelb.exe --pos 1408 1180 3350 --look 0 -38` — from above.
* `voxelb.exe --survey`, then read `voxel.log` for other places. Try other
  seeds with `--seed <n>`.

### Bugs found and fixed while testing
* terrain.cfg records read a 32-bit index as a 64-bit one (garbage
  pointer, a crash) when parsing `[noise]` and `[spline]` records.
* Splines assumed noise in −1..1, but fractal sums sit mostly in
  −0.5..0.5, so mountains were almost absent (0.1%). The splines were
  rescaled, and the survey now confirms the planned shares.
* Giant spires had no snow because every slope counted as steep. Snow now
  holds on steeper slopes high up, and everything 200 above the snow line
  is snow.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* Debug and release headless tests pass; `--flat` still gives the
  gallery; clean exits.
* Screenshots: the spawn coast (beach, grass terraces, sea, distant
  mountain); a river valley with sandy banks; a giant ridgeline with a deep
  pass and snowy spires; jagged spires from above.

### Verified on Windows (GitHub Actions run #16, Mesa llvmpipe GL 4.6)
* Debug and release smoke tests pass: terrain generator loaded, clean
  exit.
* Release:
  * the spawn view (797 columns, 344k quads) completes in 1.76 s;
  * meshing averages 2.6 ms per column;
  * `stream_update` averages 36–39 µs;
  * about 16 FPS on software GL.

### Performance (release, llvmpipe, render distance 16)
| | |
|---|---|
| View complete at spawn | 1.29 s |
| Column generation | avg 2.2 ms (max 13 ms) |
| Column meshing | avg 1.5 ms |
| FPS flying over lowland (`--flytest`) | 19–21 (48–53 ms; 367k quads) |
| Inside a giant range | ~3 FPS on software GL (1.85M quads in range) |
| `stream_update` | avg 37–45 µs |

Software rendering is the limit here. Mountains have many more faces than
the flat world. GPU-driven rendering (M11) and LOD (M12) are the planned
answer.

### Known issues
* The loaded world ends at 512 blocks: from high peaks you see the edge
  (M12 adds LOD terrain beyond it, M14 real fog).
* Without lighting (M13) cliffs are flat grey; snow and stone read mainly
  through texture.
* The overlay's `surface` value is the exact height; the generated
  terrain interpolates the large-scale fields every 4 blocks (differences
  of a block or two).

### Deferred
* Biome-specific surfaces, vegetation and trees: M10. Caves, ores, lava:
  M9.
* Flowing water and water rendering: M15. Fog and sky: M14.

---

## Milestone 7b — done (2026-10-09)

### Design interview
Two rounds plus approval, recorded in `design/blocks/shaped_blocks.md`.
* All 19 woods get 10 shapes: slab, stairs, fence, fence gate, door,
  trapdoor, ladder, sign, wall sign, pressure plate.
* The 8 stone-family materials get slab, stairs, wall and a stacking
  pillar.
* The 16 terracottas get slab and stairs.
* 18 glass panes.
* Stair corners are automatic.
* Each wood has a unique door and trapdoor design.
* Later: signs show typed text; pressure plates open doors and feed a
  future mechanism system.

### What was built
* **Block states** (D41): `shape = …` reserves one id per state. There are
  272 new shaped blocks, 2075 block ids in all. `upper_textures` sets the
  door's upper half.
* **Shape geometry** (`src/render/shapes.asm`, D42): boxes in 1/16 units,
  rotated by facing. Neighbour-dependent parts are worked out at mesh time:
  stair inner/outer corners, fence/wall/pane connections, walls without a
  post on straight runs, and pillar base/shaft/capital.
* **Model quads** in the same quad stream and shader as the cubes. Faces
  are culled against opaque neighbours. Sections without shapes skip the
  pass.
* **Textures**: 98 new ones (19 unique door designs as top and bottom
  halves with glow layers where needed, 19 trapdoors, 19 ladders, 8 pillar
  side/top pairs). 415 textures in all.
* **Data**: `data/blocks/60_shapes.blocks` (templates and families).
* **Gallery** shows every state and connection (D43). It now starts at
  z 440, and the start position moved to z 462.

### How to see it
Start the game and fly north over the gallery. Rows 17–28 hold the wood
shapes, then stone shapes, terracotta and panes. Close views:
* `voxelb.exe --pos 4 104 357 --look 0 -30` — wood shapes (doors,
  fences, ladders, trapdoors, stairs);
* `voxelb.exe --pos 6 106 311 --look 0 -32` — walls, pillars and stair
  corners;
* `voxelb.exe --pos 6 104 289 --look 0 -30` — terracotta stairs and
  glass panes.

### Bugs found and fixed while testing
* Shaped blocks were marked opaque (their layer is opaque), which culled
  the ground's top face under them. Only full cubes are opaque now.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* Debug and release headless tests pass: 2075 blocks, 415 textures, none
  missing, no warnings (except the GL 4.5 fallback), clean exit.
* Screenshots: doors (open/closed, both hinges, upper halves), fences
  joining in a T, gates, trapdoors, ladders, signs, plates; stair corners
  forming; walls without posts on straight runs; pillars with base, shaft
  and capital; translucent connected panes.

### Performance (release, llvmpipe, render distance 16)
| | |
|---|---|
| FPS flying (`--flytest`) | 129–136 (7.4–7.8 ms) |
| Column meshing | avg 1.25 ms (shapes included) |
| Column generation | avg 0.5–0.8 ms |
| `stream_update` | avg 57–157 µs |

### Known issues
* Ladders, wall signs and doors in the gallery stand on their own (they
  are meant to be attached to walls; placement rules come with M16).
* Inside faces between boxes of one shaped block are drawn (a little
  overdraw, invisible).

### Deferred
* Placing, opening doors and gates, typing on signs, pressure plates: M16+.
* A mechanism/wiring system for plates: its own design later.

---

## Milestone 7 — done (2026-10-09)

### Design interview
Four rounds plus approval, recorded in `design/blocks/block_set.md`:
* 16×16 textures in a vibrant, shaded pixel-art style. Claude draws them;
  the owner can repaint any PNG.
* A very broad set of 262 cube blocks:
  * 16 woods × 9 blocks (classic six, six real-world woods, four fantasy
    woods), each with one seasonal leaf variant;
  * 3 mushroom woods × 8 blocks;
  * soils, the stone family, glass and ice;
  * 16 colours × terracotta, stained glass and wool;
  * a lamp, 16 coloured lamps, 5 crystals and glowstone.
* Animated: emberwood, crystalwood and crystals, glowwood and the glowing
  mushroom, swaying leaves. Fantasy blocks give off coloured light (from
  M13).
* See-through leaves, with an `opaque_leaves` option.
* Shaped blocks moved to M7b.

### What was built
* **Block registry** (`src/world/block.asm`): reads every
  `data/blocks/*.blocks` file in name order. Records are `[block]`,
  `[template]` (with a `{}` member placeholder), `[family]` and
  `[texture]` (D36). Per-face textures, render layer, light, sway. Adding
  blocks needs no asm.
* **Section headers** in the shared cfg parser (`cfg_parse_ex`).
* **PNG decoder** in asm (`src/core/png.asm`): inflate plus every
  non-interlaced colour type, depth and filter (D37). Self test with 5
  reference images.
* **Texture array** (`src/render/block_textures.asm`): 317 PNGs make 479
  layers with mipmaps. Animated strips, glow layers, a magenta checker for
  missing files. Texture info and block faces go to the GPU as SSBOs.
* **Hot reload** of PNGs: about one second.
* **Render layers** (D38): the mesher orders quads into opaque / cutout /
  translucent ranges. Glass hides faces between equal blocks. The draw
  runs three passes, with the translucent sections sorted back to front.
* **Shaders**: per-face UVs that tile across greedy quads (`GL_REPEAT`),
  animation frames with blending, glow layers, leaf sway, and an alpha
  test that keeps its coverage at distance.
* **Settings module** (`src/core/settings.asm`) reads graphics.cfg before
  the world loads (`render_distance`, `opaque_leaves`).
* **Faster mesher skip** for buried all-opaque sections (D39).
* **Flat test world**:
  * real blocks: bedrock, deep stone, stone, dirt, grass;
  * a **block gallery** (every block as a 3×3×3 cube in id order) in front
    of the start position;
  * terracotta hills and wool pillars.
* **Texture generator** `tools/texgen/texgen.py` (D40). The PNGs are
  committed.
* **`--pos x y z` and `--look yaw pitch`** command-line options.
* **Smoke tests** check the block registry and that no texture is missing.

### How to see it
Start the game: the gallery is right in front of you. Rows run north in
id order:
* terrain;
* the 16 woods (oak first; fantasy woods in rows 7–9);
* seasonal leaves;
* mushrooms;
* glass and ice;
* the colours;
* the lights.

Closer views:
* `voxelb.exe --pos 14 105 193 --look -10 -22` — glass, ice and the lamps;
* `voxelb.exe --pos -12 105 214 --look 0 -25` — the woods up close.

### Bugs found and fixed while testing
* The PNG self test hashed from the width value instead of the pixel
  pointer (an infinite loop under Wine). Fixed in the test.
* Polling 4 texture files per frame was too slow at low frame rates (a
  full pass took 8 s at 10 FPS). Raised to 32 per frame.
* Buried mixed sections made meshing 3.5× slower (D39).
* Upload rollback bug from M6: after a full GPU buffer, a retry would have
  read GPU offsets as CPU offsets. Sections now keep `cpu_first`
  separately.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe, 4-core Xeon)
* Debug and release headless tests pass:
  * every self test passes, including the PNG decoder;
  * 262 blocks and 317 textures load, with none missing;
  * no warnings except the GL 4.5 fallback;
  * clean exit.
* Screenshots: the textured gallery; see-through glass, tinted glass and
  ice with no inner faces; glowing lamps; bookshelves; carved and mossy
  planks; terracotta hills.
* Hot reload: a repainted `stone.png` was re-uploaded within about 0.4 s.
  Restoring it reloaded again.
* `opaque_leaves = 1` loads and runs cleanly.

### Verified on Windows (GitHub Actions run #13, AMD EPYC 7763 × 4, Mesa llvmpipe GL 4.6)
* Debug and release smoke tests pass:
  * every self test, including the PNG decoder;
  * 262 blocks and 317 textures load (479 layers, none missing);
  * clean exit.
* Release:
  * full view complete after 1.26 s;
  * the texture array is built in 0.31 s;
  * meshing averages 2.2 ms per column;
  * `stream_update` averages 33–215 µs;
  * about 19 FPS looking at the gallery and hills (109k quads) on software GL.

### Performance (release, llvmpipe software rendering, render distance 16)
| | |
|---|---|
| Full view (797 columns) | 1.5 s after start |
| FPS flying (`--flytest`) | 76–81 (12.3–13 ms) |
| Column generation | avg 0.6 ms |
| Column meshing | avg 1.3 ms (was 1.7 ms in M6) |
| `stream_update` | avg 170–210 µs |
| Block + texture loading | 262 blocks in 2 ms; 317 PNGs decoded and uploaded in 0.5 s (debug, llvmpipe) |
| Texture array | 479 layers, about 2 MB with mipmaps |

### Known issues
* Quads inside one translucent section are not sorted (D38). Overlapping
  glass of different colours within one 32³ section can blend in the wrong
  order.
* Leaves sway as whole greedy quads (the vertices are at the quad
  corners). It is subtle at this amplitude.
* Grass and leaves are not biome-tinted yet (M10).

### Deferred
* Shaped blocks: M7b.
* Block light from the `light` values: M13. Biome tinting: M10.
* Block properties for gameplay (hardness, tool, sounds, drops): with
  items, M18. Sounds: M24.

---

## Milestone 6 — done (2026-10-09)

### What was built
* **Infinite world.** Columns are generated, meshed, uploaded and unloaded
  around the camera on worker threads (D32). The flat test world now
  covers every column; the debug hills and pillars stay around the origin.
* `src/world/stream.asm`: the per-frame streamer (spiral priority,
  neighbour-gated meshing, busy counters, unload hysteresis, a 2 MB/frame
  upload budget, an in-flight cap), plus periodic `stream:` stats in the
  log.
* `src/world/world.asm`: a column pool, a column hash map (backward-shift
  deletion), and `gen_column_job`.
* `src/render/gpu_alloc.asm`: a buddy allocator over a 128 MB quad SSBO
  (D33).
* The camera position is kept in doubles; rendering is camera-relative in
  double (D34).
* `data/config/graphics.cfg`: `render_distance` (default 16).
* `--flytest` flag: flies straight ahead at 60 blocks/s, to stress
  streaming.
* Debug overlay: `world` (columns/ready/sections/MB/render distance),
  `stream` (in-flight gen/mesh, upload KB/frame, update µs), and `gpu`
  (quads, buffer use, CPU meshes waiting).
* Workers run at below-normal priority (D35).
* Self tests: a column hash (3000 keys, with deletion) and the GPU buddy
  allocator (2000 blocks, full re-merge).
* Smoke tests now check `stream: view complete` (the default autoclose is
  now 8 s on CI, 6 s locally).

### Bugs found and fixed while testing
* The hash self test overwrote the lookup result with a division result.
* `gpu_alloc_init` was not idempotent (the self test runs it first).
* push/pop inside PROC bodies (buddy allocator, upload rollback) broke the
  fixed frame. Replaced with saved registers.
* Throughput was limited by frame rate (4 jobs per thread in flight).
  Raised to 16: the full view now loads in 1.2 s instead of 3.7 s.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe, 4-core Xeon)
* Debug and release headless tests pass. Every self test passes, the
  screenshot shows the world, and the exit is clean.
* `--flytest` release, 12 s at 60 blocks/s:
  * the full view (797 columns) completes 1194 ms after start;
  * steady state: 1001 loaded / 932 ready;
  * GPU quads fall from 107k to 932 once the hill area is left, so
    unloading frees GPU memory;
  * no errors and a clean exit.

### Verified on Windows (GitHub Actions run #11, AMD EPYC 7763 × 4, Mesa llvmpipe GL 4.6)
* Debug and release smoke tests pass; every self test passes; clean exit.
* Release: full view (797 columns) complete after 1068 ms. `stream_update`
  averages 44–181 µs per frame, with a 568 µs maximum while loading.
  Uploads take at most 77 µs per frame. Meshing averages 1.9 ms per
  column, generation 0.25 ms.
* About 21 FPS while looking at 107k quads on software GL.

### Performance (llvmpipe software rendering, render distance 16)
| | |
|---|---|
| FPS while flying (release) | 74–96 |
| Frame time, near the hills (debug, 106k quads) | 57 ms (17 FPS; software raster) |
| `stream_update` average | 70–170 µs per frame |
| `stream_update` worst | under 1.5 ms without CPU oversubscription (D35) |
| Column generation | avg 0.25 ms, max 3.7 ms |
| Column meshing | avg 1.3–1.7 ms, max 9.5 ms (on workers) |
| Upload | 2 MB/frame budget, ≤0.2 ms per frame measured |

### Known issues
* Under heavy CPU oversubscription (software GL plus workers on 4 cores),
  `stream_update` can show rare 4–12 ms spikes from OS preemption (D35).
* The buddy allocator wastes up to 2× in the quad buffer. That's fine at
  render distance 16; M11 replaces it.

### Deferred
* Saving and reloading modified columns: M17 (columns are regenerated).
* LOD beyond the render distance: M12. Persistent buffers/MDI/GPU culling: M11.
* Real terrain: M8. The real block set: M7 (needs a design interview).

---

## Milestone 5 — done (2026-10-09)

### What was built
* **Sections** (`src/world/section.asm`, D27): 32³ palette-compressed
  storage: uniform (no data), 1/2/4/8-bit palette, or raw 16-bit. Build from
  an array, get, set (with palette growth), decode, and free. All storage
  comes from lock-free pools.
* **World** (`src/world/world.asm`): a column hash map, and a fixed test
  world of (2·radius)² columns × 40 sections (Y −256…1023). Generation and
  meshing run as parallel jobs (`job_dispatch`), with timing stats.
  `world_block_at` and `world_section_at` queries.
* **Debug test world** (`data/world/flat_test.cfg`, D30): placeholder
  `debug_*` blocks with flat colours, layers stone/dirt/grass (surface at
  y 100), radius 12 chunks (768 × 768 blocks), and debug hills and pillars
  that cross section borders. **Not game content**: the real blocks come
  from the M7 design interview.
* **Greedy mesher** (`src/render/mesher.asm`, D28): 34³ padded volume with
  neighbour borders, 6 directions × 32 slices, greedy rectangles, 8-byte
  packed quads, and a skip for enclosed uniform sections.
* **World rendering** (`src/render/world_render.asm`, `shaders/chunk.*`,
  D29): one quad SSBO, vertex pulling, CPU frustum culling (5 planes ×
  bounding sphere), back-face culling, flat block colours with per-block
  jitter and edge lines (so single blocks show inside merged quads), face
  shading and distance fog.
* Debug block table (`src/world/block.asm`), replaced by the registry in M7.
* Shared data-file parser (`src/core/cfg.asm`, D31); controls.cfg now uses
  it too.
* `arena_alloc_shared` (thread-safe bump allocation) for mesh staging.
* Overlay: world (columns, sections + MB, sections with geometry, quads,
  GPU MB), draw (visible sections and quads), gen and mesh times (wall, avg,
  max), chunk coordinates and the ground block below the camera.
* Self test: sections (all bit widths, get/decode round trips, 3000
  random sets growing 0 → 16 bit) and the mesher (6 cases with exact
  quad counts, including real neighbour sections). The M3 test scene is
  removed.

### Bugs found and fixed while testing
* `arena_alloc_shared` returned `VirtualAlloc`'s page-rounded address
  instead of base + offset, so mesh jobs overwrote each other's quads and the
  world rendered with holes. The mesher unit tests proved the mesher right,
  and dumping the quad contents led to the allocator. Fixed, and covered by
  a self-test check.
* Debug text disappeared once back-face culling was on: its screen-space
  quads wind clockwise. Text now draws with culling off.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe)
* 0 errors and 0 warnings in both configs. The headless test passes for both
  (now also requires the world upload). The self test passes (arenas incl.
  shared allocs, jobs, pools, sections, mesher).
* Screenshots from 4 viewpoints (start, flown forward, turned 90°, low among
  the hills): continuous grass ground, banded hills with correct sides and
  steps, pillars spanning several sections, no missing or inverted faces.
  The overlay reads `ground below: debug_grass at y 99` at the start point.
* Clean exit (code 0).

### Verified on Windows (GitHub Actions, AMD EPYC 7763 × 4, Mesa llvmpipe GL 4.6)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37862551347 is
  green. Both smoke tests require the self test (now including sections and
  the mesher) and the world upload.
* The same world as locally (107,924 quads, 1750 sections with geometry):
  generation **27 ms** wall (189 µs/column avg), meshing **489 ms** wall
  (275 µs/section avg, max 12.4 ms), about 20 FPS on llvmpipe, clean exit.
* Fixed afterwards: the "block registered" debug lines also appeared in
  release logs (a hand-built log line without a debug-only guard).

### Performance (4-core Xeon 2.8 GHz; rendering on llvmpipe, no GPU)
| Measure | Value |
|---|---|
| World | 576 columns, 7074 stored sections (6.6 MB), 1750 with geometry |
| Quads | 107,924 (0.84 MB on the GPU, 8 bytes each) |
| Generation | 40–46 ms wall for all columns; avg 275–316 µs, max 1.6–11.7 ms per column |
| Meshing | 284–370 ms wall for all sections; avg 159–208 µs, max 2.0–6.8 ms per section |
| Frame (start view, ~970 visible sections, ~107k quads) | 16–19 FPS, 52–61 ms on llvmpipe |
Software rasterisation of about 640k vertices per frame is the whole frame
cost here. A real GPU draws this in well under a millisecond (still to be
confirmed on your PC).

### Known issues
* (M6) The owner has since run it on real hardware with integrated
  graphics and reports that it runs well.
* Meshing a detailed section costs up to a few ms (scalar greedy). Fine on
  workers, and the binary greedy / AVX2 variant stays available if M6
  streaming needs it.

### Deferred
* The real block set, textures and registry: M7 (design interview).
* Streaming and unloading: M6. The world is fixed-size and generated at
  start-up.
* Persistent buffers, MDI and GPU culling: M11. Light/AO-aware merging: M13.
* Binary greedy meshing with AVX2: an optimisation, only if needed.

---

## Milestone 4 — done (2026-10-08)

### What was built
* **Memory** (`src/core/memory.asm`, D23): virtual-memory **arenas**
  (reserve big, commit in 64 KB steps, bump allocation, mark/reset) and
  lock-free fixed-size **pools** (`cmpxchg16b` Treiber stack with an ABA
  tag, atomic bump for fresh blocks). Global arenas: perm 1 GB, frame 64 MB
  (reset every frame), scratch 256 MB (mark/reset temporaries), plus 64 MB
  scratch per worker. The committed total is tracked.
* **Jobs** (`src/core/jobs.asm`, D24): worker threads (CPUs − 1, or
  `--workers N`), a lock-free MPMC job queue, `job_submit`,
  `job_dispatch` (parallel-for), counters, and `job_wait`, where the main
  thread helps. Idle workers spin, then sleep on a semaphore. Wake-ups are
  claimed and batched. Threads are named.
* **CPU detection** (`src/core/cpu.asm`, D25): requires SSE4.2, detects AVX2
  (CPU + OS), logs the brand and thread count.
* **Self test** (`src/core/selftest.asm`, D26): arenas, parallel compute
  (checked against a serial run, speed-up logged), and a concurrent pool
  storm. It runs in debug builds and with `--selftest`; CI and the headless
  test require "selftest: PASS".
* The M3 static buffers now use arenas: controls.cfg, shader sources and
  compiler logs, and the font file are loaded into the scratch arena
  (`file_load`, sized from the file, so no fixed cap). The glyph buffer is
  in perm, and the overlay text is in the frame arena.
* Overlay: new **memory** line (committed MB, perm MB, frame KB and peak)
  and **jobs** line (workers, completed, queued).

### Verified (Wine 9 + Xvfb, 4-core Xeon, AVX2)
* 0 errors and 0 warnings in both configs. The headless test passes for both.
* **10 of 10** repeated self-test runs pass with 1–4 workers. Parallel
  results always equal serial.
* **Scaling** (release, 4096 jobs ≈ 15 µs each, 61 ms serial):

  | Threads (workers + main) | 2 | 3 | 4 | 5 (oversubscribed) |
  |---|---|---|---|---|
  | Speed-up | 1.96–2.12× | 2.25–2.91× | 3.46–3.62× | 3.46–3.59× |
* **Pool storm**: 8192 jobs × 8 blocks, submitted one by one: 11–32 ms,
  no corruption, 0 blocks in use afterwards. Only 10–31 fresh blocks were
  ever needed, so the free list recycles under contention.
* A bug found and fixed while testing: one semaphore wake per submitted job
  made the parallel run 8× *slower* than serial under Wine. Claimed,
  batched wake-ups fixed it (D24).
* Memory at run time: 0.6 MB committed. Arena peaks: perm 256 KB, frame
  4 KB, scratch 32 KB.

### Verified on Windows (GitHub Actions, AMD EPYC 7763, 4 logical CPUs)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37859514598 is
  green. Both smoke tests require "selftest: PASS".
* **Speed-up 3.94× with 4 threads** (61.3 ms serial → 15.6 ms parallel),
  which is close to ideal. Results match serial.
* Pool storm: 8192 jobs in 12.2 ms, no corruption, no leaks, 32 fresh
  blocks.
* Even load: main + 3 workers ran 3031 / 3149 / 3058 / 3050 jobs.

### Performance
Frame cost is unchanged from M3 (rendering is still the llvmpipe-bound test
scene). The job system is idle during frames until M5/M6 give it chunk
work.

### Known issues
* Not yet seen on a real GPU (CI uses software GL).

### Deferred
* Job priorities / distance-ordered scheduling: with chunk streaming (M6).
* A per-thread frame arena for workers (each worker has a per-job scratch
  arena today, which covers the planned uses).

---

## Milestone 3 — done (2026-10-08)

### What was built
* **Input** (`src/platform/input.asm`): key/button state, a per-frame
  "pressed" latch, **Raw Input** mouse deltas, mouse capture (hide + clip
  cursor, released on focus loss), and an **action** layer with up to 2 keys
  per action loaded from **`data/config/controls.cfg`**. The parser has
  `#` comments, case-insensitive names and a named key table (A–Z, 0–9,
  F1–F12, arrows, modifiers, Mouse1–3, …), plus mouse sensitivity, invert
  Y, fly speed and sprint multiplier. Bad lines are warned about and
  skipped. Format documented in **DATA_FORMAT.md**.
* **Fly camera** (`src/render/camera.asm`): mouse look (pitch clamped to
  ±89°), WASD/arrows, Space/Shift up/down, Ctrl ×5, frame-rate independent
  (dt clamped). Reverse-Z infinite projection, camera-relative rendering
  (DECISIONS.md D20).
* **Shaders** (`src/render/shader.asm`): programs loaded from `shaders/`,
  **hot reload** on file change (250 ms poll) plus F5. A failed compile
  keeps the old program; errors go to the log and the overlay.
* **Debug text overlay** (`src/ui/debug_overlay.asm`, `src/render/text.asm`):
  our own bitmap font (misc-fixed 8×13 → `assets/fonts/debug_8x13.vxf` via
  `tools/make_font.py`), drawn from SSBO glyph records. Shows FPS and frame
  times, vsync, GL version and renderer, position, yaw/pitch/facing, mouse
  state, shader status and the live key bindings. F3 toggles it.
* **Debug test scene** (`shaders/test_scene.*`): 32×32 coloured block
  columns on a checkered ground, generated in the vertex shader (removed
  in M5).
* Files and paths (`src/platform/file.asm`): finds the data root (release
  or dev layout), whole-file reads, file timestamps.
* `SETARGS` now catches call-argument register clobbers at assemble time
  (D21). It caught one real bug.
* GL loader: 49 functions. New string helpers: case-insensitive compare,
  float parse, signed fixed-point formatting, string-builder appends.

### Verified (Wine 9 + Xvfb + Mesa llvmpipe, scripted with xdotool)
* 0 errors and 0 warnings in both configs. The headless test passes for both
  (window, GL context, shaders + text renderer, perf line, clean exit).
* Start view as designed (yaw 0, pitch −20°). Holding **W** for 1 s moved
  the camera 12.8 blocks (12 blocks/s). **Mouse** motion turned it to
  yaw 36°, pitch −24.9°. Positions are shown live in the overlay.
* **F3** hides and shows the overlay, **F8** toggles vsync, **Esc** releases
  the mouse, and **Esc** again quits cleanly (exit code 0).
* **Hot reload**: editing `test_scene.frag` reloaded within about 1 s, and
  the tint was visible. Appending invalid GLSL logged both compiler errors
  and kept the previous program ("reload failed, keeping the previous
  version"). Restoring the file reloaded again.
* **Bad config lines** (unknown action, a third key, an unknown key name,
  a line without `=`, a non-number) each give one warning; the game runs
  normally.
* The **release zip layout** (exe + data/shaders/assets in one folder) finds
  its data next to the exe. A lone exe shows "data folder not found" and
  exits.

### Verified on Windows (GitHub Actions, Mesa 26.2.4 llvmpipe, GL 4.6 core)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37852698522 is
  green. Both smoke tests pass, and they now fail on any ERROR line in the
  log. The game root was found in the dev layout, all 11 bindings loaded,
  49 GL functions resolved, both shader programs built, the text renderer
  started, the mouse was captured, and it exited cleanly with code 0.
* The "Latest build" release was republished from this commit.

### Performance (software rendering via llvmpipe; no GPU here)
| Scene (1280×720, test field ≈ 37k vertices) | FPS | Frame avg |
|---|---|---|
| Windows CI start view (1028×720, llvmpipe) | 36–38 | 26.1 ms |
| Start view, vsync on (Xvfb, no vblank) | 51–57 | 17.5–19.6 ms |
| Inside the field, most of the screen covered | 26–29 | 34–39 ms |
On llvmpipe, the frame time is all CPU rasterisation of the test scene.
On a real GPU this scene costs well under 1 ms. Chunk gen/mesh times start
in M5.

### Known issues
* Not yet seen on a real GPU (CI uses software GL).

### Deferred
* Rebinding from inside the game (settings menu, M17). For now, edit
  `controls.cfg` and restart.
* Pause menu (M17). Until then, Esc with the mouse free quits.
* Static buffers (shader source 256 KB, config 64 KB, font 64 KB) become
  arena allocations in M4.
* SDF font for the in-game UI (M17). The debug overlay keeps the bitmap
  font.

---

## Milestone 2 — done (2026-10-08)

### What was built
* `src/render/gl_context.asm`: WGL bootstrap (a hidden dummy window and
  legacy context to fetch the ARB entry points), `wglChoosePixelFormatARB`
  (RGBA8 / D24S8, double buffered, full acceleration preferred), a
  **4.6 core** context with a 4.5 core fallback, a debug context in debug
  builds. Also the GL loader driven by `src/include/gl_funcs.inc` (12
  functions so far), `KHR_debug` messages routed into the log, vsync via
  `WGL_EXT_swap_control`, swap, and shutdown.
* `src/render/renderer.asm`: viewport tracking on resize; clears to a vivid
  sky blue each frame.
* `src/core/timing.asm`: QPC frame timer with 0.5 s stats windows (FPS, and
  avg/min/max frame time).
* `src/core/entry.asm`: frame loop (pump → requests → render → swap →
  timing), FPS and frame times in the title bar, a `perf:` log line every
  2 s, a run summary on exit, and `--novsync`.
* Window: `WM_CLOSE` is now a request, so GL is released before the window
  is destroyed. F8 toggles vsync. Minimised windows don't render.
* `str_copy`, `fmt_decimal` string helpers.
* CI: Mesa llvmpipe is installed for the GPU-less runner's smoke test, the
  smoke test checks for the GL context and the perf line, and game logs are
  printed at the end of every run.

### Verified (Wine 9 + Xvfb + Mesa 25.2 llvmpipe)
* 0 errors and 0 warnings in both configs.
* Context: llvmpipe offers no 4.6, so the logged warning and the 4.5 core
  fallback worked as designed. Pixel format 3, all 12 functions resolved,
  debug output enabled, vsync set.
* The window shows the clear colour: pixel sampled as rgb(84,158,250), which
  is exactly (0.33, 0.62, 0.98). The title shows live stats.
* F8 toggles vsync off/on (logged and shown in the title). Resizing the
  window to 800×500 updated the viewport. `--novsync` works. The release
  build runs, and both configs exit cleanly with code 0.

### Verified on Windows (GitHub Actions `windows-latest`, Mesa 26.2.4 llvmpipe)
* CI run https://github.com/Notmoodo9/VoxelB/actions/runs/37849222432 is green:
  build.bat debug and release, and both smoke tests passed.
* Got an **OpenGL 4.6 core** context (pixel format 123, GLSL 4.60), with
  debug output on in the debug build.
* **Vsync on gave 62–63 FPS** (16.0 ms average), so vsync really caps the rate.
* Per-monitor-v2 DPI awareness succeeded. Closing took about 4 ms (the 2 s
  delay seen under Wine is Wine-only). Exit code 0.
* The runner's screen is 1024×768, so Windows shrank the window to a
  1028×720 client area. That is expected; the window isn't clamped to the
  screen yet (see Deferred).

### Performance (software rendering; no GPU in this environment)
| Case | FPS | Frame time avg (min / max) |
|---|---|---|
| 1280×720, vsync off (llvmpipe) | ~333–391 | 2.6–3.0 ms (1.5 / 7.5) |
| 800×500, vsync off (llvmpipe) | ~893 | 1.12 ms (0.70 / 2.67) |

Xvfb has no vblank, so "vsync on" doesn't cap the rate here. On a real GPU,
expect a locked refresh rate with vsync on and thousands of FPS with it off
for a clear-only frame. Chunk gen/mesh timings start in M5.

### Known issues
* Not yet run on a real GPU (CI uses software GL). Please run the game on
  your PC and read the title bar.

### Deferred
* Debug text overlay: M3 (stats are in the title bar until then).
* F8/Esc become rebindable bindings in M3.
* Fit the default window size to small screens (currently Windows clips
  it). This will come with window settings in M17.
* Multisampling and an sRGB back buffer are intentionally not used (HDR
  pipeline in M14, DECISIONS.md D12).

---

## Milestone 1 — done (2026-10-08)

### What was built
* `build.bat`: debug/release/clean/run; checks that NASM and lld-link are
  present; builds import libs from `tools/implib/*.def` (no Windows SDK
  needed); assembles every `src/**/*.asm`; links with lld-link.
* `src/include/macros.inc`: Win64 ABI `PROC`/`RETURN`/`ENDPROC`, `INVOKE`,
  `API`, `IMPORT`, `ASSERT` (debug only, reports the call site's file:line).
* `src/include/win32.inc`: Win32 constants and struct layouts.
* `src/core/log.asm`: thread-safe logger writing to `voxel.log`, the console
  and the debugger, with timestamps and levels; `log_fatal`; `assert_fail`.
* `src/core/str.asm`: `str_len`, `str_find`, `str_parse_u64`, `fmt_u64`,
  `fmt_hex64`.
* `src/platform/window.asm`: window class and window (1280×720 client,
  centred, DPI-aware), non-blocking message pump, WndProc (close, destroy,
  size, Esc, activate, DPI change, autoclose timer), clean teardown.
* `src/core/entry.asm`: entry point, command-line parsing (`--autoclose
  <ms>`), main loop, shutdown, `ExitProcess` with the `WM_QUIT` code.
* `tools/build.sh` (Linux mirror of build.bat) and `tools/test_headless.sh`
  (Wine + Xvfb smoke test).

### Verified
* Debug and release both build from clean with **0 errors, 0 warnings**
  (NASM 2.16.01, LLD 18.1.3). Exe size: 8.0 KB debug, 7.5 KB release.
* Under Wine 9 + Xvfb: the window appears with a 1280×720 client area
  (screenshot checked). Esc closes it, and so does `--autoclose`. The log
  shows the full shutdown sequence. Exit code is 0 for both configs.
* Assertion path (tested on a throwaway patched copy): the message box
  appears, the log line names `src/platform/window.asm:86`, and the exit
  code is 3.
* Missing-tool check and usage error of `build.bat` were checked under
  Wine's `cmd`, and the commands it generates match `tools/build.sh`.

### Performance
No rendering yet. The idle main loop runs about 270–450 iterations/s under Wine (1 ms
`Sleep` per iteration), with negligible CPU use. Frame-time/FPS measurement
starts in M2.

### Known issues
* Under Wine/Xvfb (no window manager), `DestroyWindow` takes about 2 s.
  This is Wine-only; on Windows CI it takes about 4 ms.
* Since confirmed on real Windows by CI (window, Esc/autoclose path, exit
  code 0).

### Deferred
* SEH unwind info (`.pdata`) for our procedures; see DECISIONS.md D4.
* Rebindable keys: M3. Esc-to-quit is hardwired until the input system
  exists. Once there is a pause menu, Esc will open it instead.
* Window settings (size, fullscreen) from a config file: settings menus (M17).
