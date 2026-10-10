# Data file format

All game data under `data/` uses one simple, line-based text format. It is
parsed by our own assembly code, so it stays small and strict.

## Syntax (v1, Milestone 3)

```
# comment until end of line
name = value            # trailing comments are allowed
name = value1, value2   # some names take a comma-separated list
```

* One `name = value` pair per line. Blank lines are ignored.
* Names are case-insensitive identifiers (`move_forward`). Values are trimmed.
* Numbers: `[-]digits[.digits]`, e.g. `12`, `0.12`, `-3.5`.
* Unknown names, unknown values and malformed lines are **logged as warnings**
  in `voxel.log` and skipped. They never crash the game.
* Files are UTF-8/ASCII; only ASCII is meaningful to the parser today.

### Records (v2, Milestone 7)

Registry files (blocks today; biomes, items, … later) group settings into
records. A line `[kind name]` starts a record; the `name = value` lines
below it belong to that record until the next header:

```
[block stone]           # a record of kind "block" named "stone"
render = opaque
```

Lines before the first header, unknown record kinds and unknown settings are
warnings, as above.

## Files

| File | Read by | Contents |
|---|---|---|
| `data/config/controls.cfg` | `src/platform/input.asm` | key bindings (actions → up to 2 keys) and mouse/fly settings |
| `data/config/graphics.cfg` | `src/core/settings.asm` | graphics settings (render distance, opaque leaves) |
| `data/blocks/*.blocks` | `src/world/block.asm` | the block registry: every block, its textures and render settings |
| `data/world/world.cfg` | `src/world/world.asm` | world seed and generator (`terrain` or `flat_test`) |
| `data/world/terrain.cfg` | `src/world/terrain.asm` | the terrain generator: noise fields, splines, heights, surface blocks |
| `data/world/caves.cfg` | `src/world/terrain.asm` (used by `caves.asm`) | caves, ravines, shafts, aquifers, lava, cave decoration |
| `data/biomes/*.biome` | `src/world/biome.asm` | climate fields, tree generators, biomes (colours, terrain, plants, flowers, meadows, trees, ponds) |
| `data/world/ores.cfg` | `src/world/terrain.asm` (used by `caves.asm`) | ores: blocks, heights, cluster sizes and counts |
| `data/world/flat_test.cfg` | `src/world/world.asm` | **debug** test world: layers, block gallery, test structures |
| `assets/textures/blocks/*.png` | `src/render/block_textures.asm` | block textures (16×16, animated strips, glow layers) |

### `controls.cfg`

Actions: `move_forward`, `move_back`, `move_left`, `move_right`, `move_up`,
`move_down`, `sprint`, `toggle_debug_overlay`, `toggle_vsync`,
`reload_shaders`, `menu`. Each takes one or two key names (the list of
names is at the top of the file).

Settings: `mouse_sensitivity` (degrees per mouse count), `invert_mouse_y`
(0/1), `fly_speed` (blocks/s), `fly_sprint_multiplier`.

### `graphics.cfg`

| Key | Value | Meaning |
|---|---|---|
| `render_distance` | `2`–`48` (default 16) | full-detail view distance in chunks. Columns are generated one ring further out (so edge chunks can be meshed against their neighbours) and unloaded three rings beyond it |
| `opaque_leaves` | `0`/`1` (default 0) | `1` draws cut-out blocks (leaves) as solid cubes: faster on weak GPUs |

## Block files (`data/blocks/*.blocks`)

Every `*.blocks` file in `data/blocks/` is read at start-up in file-name
order (`00_terrain.blocks` before `10_wood.blocks`), so block ids are always
the same. A new block, or a whole new file, needs **no assembly changes**.
Four record kinds exist.

### `[block <name>]`

Defines a block, or changes one defined earlier (the later settings win).

| Setting | Value | Meaning |
|---|---|---|
| `textures` | `face: texture, …` or `texture` | which texture each face uses. Faces: `all`, `side` (the 4 vertical faces), `top`, `bottom`, `end` (top + bottom), `north` (−Z), `south` (+Z), `east` (+X), `west` (−X). Later entries override earlier ones. A face without a texture uses the texture named like the block |
| `render` | `opaque` (default), `cutout`, `translucent` | `cutout`: alpha-tested, pixels are fully see-through or solid (leaves). `translucent`: blended (glass, ice); faces between two equal translucent blocks are hidden |
| `light` | `r, g, b` (0–15 each) | coloured light the block emits (used from Milestone 13) |
| `sway` | `0`/`1` | the block waves in the wind (leaves; plants bend from the ground) |
| `tint` | `grass` / `foliage` / `none` [`, faces…`] | the faces (default all) take the biome's grass or foliage colour, blended across biome borders |
| `shape` | see below (default `cube`) | a non-cube shape. **Must be the first setting of a new block** (in a template: the first line after `name`), because it reserves one block id per state |
| `upper_textures` | like `textures` | door shapes only: textures of the upper half |

Shapes and their states (each state is its own block id, base id + state;
every setting applies to all states):

| Shape | States | Automatic from neighbours |
|---|---|---|
| `slab` | bottom, top | |
| `stairs` | 4 facings × bottom/upside-down | inner/outer corners next to perpendicular stairs |
| `fence` | 1 | joins fences, fence gates and solid blocks |
| `fence_gate` | 4 facings × closed/open | |
| `door` | 4 facings × lower/upper × closed/open × hinge left/right | |
| `trapdoor` | 4 facings × bottom/top × closed/open | |
| `ladder`, `wall_sign` | 4 facings | |
| `sign` | 4 rotations | |
| `pressure_plate` | up, pressed | |
| `wall` | 1 | joins walls and solid blocks; no post on a straight run |
| `pillar` | 1 | base / shaft / capital when stacked |
| `pane` | 1 | joins panes, walls and solid blocks |
| `spike` | hanging (from above), standing (from below) | base / middle / tip by the spikes it touches (dripstone) |
| `plant` | 1 | two crossed planes, seen from both sides (grass, flowers) |
| `tall_plant` | lower, upper | two blocks high; the upper half uses `upper_textures` |
| `stalk` | 1 | a thin upright post (4/16 wide) that joins nothing (bamboo) |
| `axis` | upright, east-west, north-south | a cube log: the `end` texture faces along its axis (logs lying in fallen trees and branches) |

Faces of a shape take the block's textures by direction, projected like
a cube's (so a slab shows the lower half of its texture).

The simplest block is one line: `[block stone]` uses `stone.png` everywhere.

### `[template <name>]` and `[family <name>]`

Many blocks share their settings and differ only in textures (16 woods ×
8 variants). A template holds block settings in which `{}` stands for a
member name; its `name` setting is the block-name pattern. A family applies
templates to members:

```
[template planks]
name     = {}_planks
textures = all: {}_planks          # (the default anyway)

[template log]
name     = {}_log
textures = side: {}_log, end: {}_log_top

[family woods]
templates = log, planks
members   = oak, birch              # -> oak_log, oak_planks, birch_log, birch_planks
```

Templates can be used by any later file. Blocks created by a family can be
changed afterwards with a `[block …]` record (e.g. to give one wood light).

### `[texture <name>]`

Settings of one texture file:

| Setting | Value | Meaning |
|---|---|---|
| `frame_ms` | `1`–`60000` (default 100) | animation speed, milliseconds per frame |
| `interpolate` | `0`/`1` | blend smoothly between frames |
| `glow` | texture name | drawn on top at full brightness (alpha = strength); same frame count as the texture, or one frame |

### Textures

`assets/textures/blocks/<name>.png`: 16 pixels wide. A texture taller than
16 pixels is an animation: a vertical strip of 16×16 frames (up to 32),
played top to bottom. Any PNG a paint program saves works (RGBA, RGB, grey,
palette, 8 or 16 bits; not interlaced). Transparent pixels matter only for
`cutout` and `translucent` blocks. A missing or invalid file shows a
magenta/black checkerboard and logs a warning naming it.

Edit a PNG while the game runs and it is reloaded within a second (a
changed frame count needs a restart). `tools/texgen/texgen.py` regenerates
the built-in textures (see BUILD.md); it overwrites repainted files only if
you run it.

### `world.cfg`

| Key | Value | Meaning |
|---|---|---|
| `seed` | unsigned number | the world seed: same seed, same world (`--seed <n>` overrides) |
| `generator` | `terrain` (default) / `flat_test` | the real terrain, or the debug gallery world (`--flat` forces it) |

### `terrain.cfg` (Milestone 8)

Top-level settings (all optional, defaults in `src/world/terrain.asm`):

| Key | Meaning |
|---|---|
| `sea_level` | water fills air at or below this height |
| `land_start`, `land_ramp` | continentalness where land begins, and over how much of it mountains fade in |
| `giant_height`, `jag_height` | height of a full giant ridge, and of the extra spires on it |
| `detail_height` | small bumps everywhere (blocks) |
| `river_width`, `river_widen`, `river_bed`, `gorge_max` | river core width (in noise units), valley widening in lowlands, riverbed height, highest terrain a river still cuts |
| `overhang_amplitude`, `overhang_start` | blocks of 3D overhang in mountains, and the height where it starts |
| `max_height` | highest possible surface |
| `snow_line`, `snow_line_variation`, `snow_cap_above` | snow above this height (± noise), and full snow cover this far above it |
| `beach_low`, `beach_high` | top-block heights that count as shore (sand / gravel) |
| `steep_slope`, `scree_slope`, `scree_min_y` | height steps to a neighbour that make bare stone, or gravel (on shores, or above `scree_min_y`) |
| `deep_stone_y` | deep stone below about this height |
| `top_block`, `filler_block`, `stone_block`, `deep_block`, `bedrock_block`, `beach_block`, `gravel_block`, `snow_block`, `water_block`, `seabed_clay_block` | the blocks used (names from `data/blocks/`) |

`[noise <field>]` records set a noise field: `scale` (blocks per feature),
`octaves`, `persistence`, `ridged` (0/1), `salt`. Fields: `continentalness`,
`erosion`, `peaks`, `high`, `giant`, `ridges`, `jag`, `rolling`, `river`,
`detail`, and `overhang` (3D).

`[spline <name>]` records map a noise value to a number with
`point = input, output` lines (ascending inputs; piecewise linear; clamped
at the ends; up to 16 points). Splines: `base_height` (continentalness →
height), `mountain_factor` (erosion → 0..1), `peaks_height` (peaks →
blocks), `high_factor` (high → extra multiplier), `giant_mask` (giant →
0..1), `rolling_height` (rolling → blocks). Noise values are within −1..1
but mostly within −0.5..0.5.

How they combine is described at the top of `src/world/terrain.asm`. Run
`voxelb.exe --survey` to log what a change does: the ocean/height shares
and places worth visiting.

### `caves.cfg` (Milestone 9)

Caves, ravines, shafts, aquifers, lava and cave decoration
(`design/terrain/underground.md`). Same record format as `terrain.cfg`; all
settings optional (defaults in `src/world/terrain.asm`).

| Key | Meaning |
|---|---|
| `cave_bottom_y` | nothing is carved at or below this height |
| `cave_crust`, `entrance_threshold` | caves stay this many blocks below the surface, except where the `entrance` field is above the threshold (cave mouths) |
| `tunnel_width`, `passage_width` | tunnels / narrow passages: where two 3D fields are both within this of zero (noise units) |
| `pillar_width` | `pillar` field above this: a natural pillar (no cavern there) |
| `sky_cavern_threshold`, `sky_cavern_depth`, `sky_cavern_openness` | where the `sky_cavern` field is above the threshold: an open bowl from the surface down to the depth (deepest in the middle), and the cavern threshold drops by the openness. No lakes there |
| `ravine_threshold`, `ravine_width`, `ravine_depth_min`, `ravine_depth_max` | ravines are zero lines of the `ravine` field inside the `ravine_mask` field (above the threshold); they narrow with depth |
| `shaft_spacing`, `shaft_chance`, `shaft_radius_min`, `shaft_radius_max`, `shaft_depth_min`, `shaft_depth_max` | one possible shaft per cell of `shaft_spacing` blocks, present in `shaft_chance` of cells: a round vertical pipe from the surface down |
| `aquifer_size`, `lake_chance`, `lake_min_y`, `lake_max_y` | regions of this many blocks; this share holds a lake with a level in the range (open cave cells at or below it are water) |
| `lava_region_top_y`, `lava_min_y`, `lava_max_y` | below the top, each region has a lava level in the range |
| `dripstone_chance` | per open cave floor / ceiling block: a stalagmite / stalactite of 1–4 blocks |
| `floor_patch_threshold` | gravel / clay / mud patches on cave floors where the `detail` field is beyond this |
| `ore_wall_bonus` | extra ore attempts (share) that must touch a cave |
| `lava_block`, `dripstone_block`, `mud_block` | the blocks used |

Caves under the sea (surface at most sea level + 3) flood up to sea level.
Where a neighbouring column would hold a different fluid (another lake or
lava level, the coast) at the same height, the rock stays as a barrier, so
water never stands as a wall against open air.

`[spline cavern_threshold]` maps height → cavern threshold (`cheese` noise
above it is open; lower = bigger caverns). Noise records: `cheese`,
`tunnel_a`, `tunnel_b`, `passage_a`, `passage_b` (3D), and `pillar`,
`entrance`, `sky_cavern`, `ravine`, `ravine_mask` (2D).

### `ores.cfg` (Milestone 9)

One `[ore <name>]` record per ore (up to 32):

| Key | Meaning |
|---|---|
| `block`, `deep_block` | the ore in stone / in deep stone (`deep_block` optional: same block) |
| `min_y`, `max_y`, `peak_y` | height range; most common at `peak_y` (omit for an even spread) |
| `size_min`, `size_max` | blocks per cluster (a random walk) |
| `per_section` | clusters per 32³ section inside the range |
| `mountain_only` | 1: only inside mountains (y ≥ 180, 8+ blocks below the surface) |
| `strata` | 1: only in columns with banded rock (badlands), and it may replace band blocks (gold in the cliffs) |
| `mountain_bonus` | extra share of clusters where the surface is 250+ |
| `deep_only` | 1: only in deep stone |
| `vein_chance`, `vein_size` | chance per section of one long vein of this many blocks |

Ores replace only stone and deep stone. Placement is a hash of world seed,
section and ore, so it is the same every time.

## Biome files (`data/biomes/*.biome`, Milestone 10)

Read in file-name order (`design/biomes/`). Trees must be defined before the
biomes that use them. Records:

`[climate]` — `grass_reference`, `foliage_reference` (RRGGBB): the average
colour of the grass / oak leaf textures (a biome colour equal to these leaves
the texture unchanged); `contrast` (climate noise spread, default 1).

`[noise temperature]`, `[noise humidity]`, `[noise weirdness]`, `[noise dunes]`, `[noise plateaus]`, `[noise mesas]`, `[noise strata]` — the climate fields, the dune shape, the plateau mask, the mesa mask and the band wave (`ridged = 1` allowed) (`scale`,
`octaves`, `persistence`, `salt`); larger scale = larger biomes.
Temperature and humidity are 0..1.

`[tree <name>]` — a tree or bush generator:

| Key | Meaning |
|---|---|
| `kind` | `round` (trunk + round crown), `branching` (trunk, diagonal branches with leaf clusters, crown), `bush` (log stub + low leaf clump), `giant` (tapering flared trunk, arching roots, heavy branches with leaf clusters, crown), `fallen` (a log lying on level ground, length = `height`), `stump` (a short upright log), `cactus` (column of `height`, `branches` arms, `leaves` = flower on top with `chance`), `rock` (discs shrinking upward from `radius`, `height` tall; `leaves` = optional block on its upper half), `arch` (a half-ring of `radius` with legs in the ground), `fossil` (a half-buried spine `height` long with ribs, of `log`), `palm` (curved trunk of `height`, 8 drooping fronds of `radius`), `conifer` (trunk of `height`, tiers of `leaves` shrinking from `radius` to a tip), `acacia` (trunk of `height` splitting into 2 forks and 2–4 limbs, each ending in a flat leaf pad of `radius`), `baobab` (bottle trunk of `base_radius` bulging in the middle, `height` tall, `branches` stubby branches with leaf tufts of `radius`), `kapok` (jungle giant: `roots` buttress fins, a bare round trunk of `base_radius`, `height` tall, `branches` thick branches from 72–86% of the height ending in wide flat clusters of `radius`), `stone_ring` (`branches` standing stones of `log`, `height` tall and 1–2 wide, evenly on a ring of `radius`, `leaves` = their top block), `grove` (a disc of `radius` with a `log` stalk on a share `chance` of the columns, `height` tall, each with a `leaves` tuft on top: bamboo groves) |
| `log`, `leaves` | blocks |
| `height` | trunk height range `a, b` |
| `radius` | crown radius range |
| `branches` | branch count range (branching) |
| `leaf_gaps` | chance that an edge leaf is left out (irregular crowns) |
| `base_radius` | giant: trunk radius range at the ground (it tapers to 3×3 at 55% of the height) |
| `roots` | giant: root count range |
| `chance` | cactus: flower chance; grove: share of columns with a stalk |
| `vines` | `block, chance`: per trunk side, a run of this block (ladder shape) hanging down the trunk from below the crown |
| `hanging_vines` | `block, chance`: per leaf, a strand of this block (plant shape) hanging down, stopping above the ground |
| `log = strata` | rocks and arches in the band of the biome they stand in (striped hoodoos and arches) |
| `lean` | round and branching trees: blocks east per block of height (wind-bent trunk and crown) |
| `vine_length` | length range of vine runs and strands (default 2–8) |
| `fungus` | `block, chance`: per trunk side, one of this block somewhere on the trunk (shelf fungi) |
| `pods` | `block, chance`: per tree, 1–3 of this block (ladder shape) on the lower trunk (cocoa) |

`[biome <name>]`:

| Key | Meaning |
|---|---|
| `temperature`, `humidity` | climate box `lo, hi`: the biome whose box contains the climate wins (nearest box centre when they overlap); nothing matches → "none" (plain terrain) |
| `height` | surface height range where it may appear |
| `hill_scale` | hills (height above the base) × this; blended across borders |
| `grass_color`, `foliage_color` | RRGGBB biome colours (blended) |
| `top_block`, `filler_block` | override the terrain's grass / dirt on flat ground |
| `plant` | `block, chance`: ground cover on grass (repeat; chances add up) |
| `flowers`, `flower_chance` | flower blocks; share of grass in small same-colour clusters |
| `meadow_chance`, `meadow_radius`, `meadow_density`, `meadow_mixed` | chance per 512×512 cell of a flower meadow; radius range; flower share inside; share of mixed (rainbow) meadows, the others are one colour |
| `tree`, `tree_density` | `tree name, weight` (repeat); trees per block² |
| `bush`, `bush_density` | the same for bushes |
| `pond_chance`, `pond_radius`, `pond_depth`, `pond_floor` | chance per 64×64 cell; radius range (max 6); deepest water; floor block; `pond_slope`: how uneven the ground may be (default 3); `pond_top`: block for the top water layer (ice: frozen ponds) |
| `weirdness`, `priority` | rare pockets: a weirdness range; where several boxes match, the highest priority wins (old-growth inside forest) |
| `litter_block`, `litter_radius`, `litter_chance` | ground block near tree trunks (leaf litter), radius, share |
| `shade_plant` | `block, chance` on litter (ferns, mushrooms) |
| `clearing_chance`, `clearing_radius`, `clearing_flower_chance` | treeless clearings: chance per 160×160 cell, radius range, flower share |
| `ring_chance`, `ring_radius`, `ring_plants` | mushroom rings: chance per 128×128 cell, radius range, blocks |
| `top_patch` | `block, level`: replaces the top block where the detail noise is above `level` (moss) |
| `mesa_height` | mesas: the `mesas` noise, cut into 3 flat terraces with steep risers, × this is added to the land (blended across borders) |
| `strata`, `strata_thickness`, `strata_min_y` | striped rock: band blocks (up to 16, repeats weight a colour), band thickness range, lowest banded y. Bands are picked in seeded random order into a 128-block table, so cliffs line up; the `strata` noise shifts them a few blocks. Every block of the column from the second down to `strata_min_y` is banded |
| `steep_block = strata` | (and any tree `log = strata`) the band at that block's height |
| `wash_block` | dry washes: winding beds (the dune field's crest lines) on low ground off the mesas |
| `dry_ponds` | `block, share`: this share of the biome's ponds are dry hollows: a flat pan one below the rim, no water, `block` on top (salt flats) |
| `beach_block` | the shore band block (default the world's beach sand) |
| `top_patch_low` | `block, level`: replaces the top block where the detail noise is below `level` (a second kind of patch, e.g. frozen dirt beside gravel) |
| `dune_height` | dunes: the `dunes` noise × this is added to the height (blended across borders) |
| `plateau_height` | plateaus: where the `plateaus` noise is high, this many blocks are added to the land (a steep ramp to a flat top; blended across borders) |
| `steep_block` | top block on steep slopes (default stone) |
| `meadow_cell`, `meadow_flowers` | meadow candidate cell size (power of two, default 512); flowers used in meadows instead of `flowers` (bluebell carpets) |

The `bush` list holds the second layer of a biome: bushes, the understorey,
fallen logs and stumps. Trees and the second layer can reach 20 blocks into
neighbouring chunks.

Vegetation thins out towards biome borders (blend weight 0.85 → 0.5). Trees
grow only on flat dry land away from ponds. Everything is placed from hashes
of world seed and position, so neighbouring chunks agree.

### `flat_test.cfg` (debug layout, Milestones 5–7)

The world is infinite: every column gets the layers; the gallery and the
test structures are near the start position. Blocks are named as in
`data/blocks/`.

| Key | Value | Meaning |
|---|---|---|
| `layer` | `block, top_y` | bottom-up layers; each fills up to `top_y` (inclusive) |
| `gallery` | `0`/`1` | show every registered block as a cube, in id order |
| `gallery_origin` | `x, y, z` | first cube (bottom-west-north corner); rows run towards −Z |
| `gallery_columns` | `1`–`64` (default 16) | cubes per row |
| `gallery_size` | `1`–`64` (default 3) | cube edge in blocks |
| `gallery_gap` | `0`–`64` (default 2) | space between cubes |
| `test_structures` | `0`/`1` | banded hills and pillars around the origin |
| `structure_blocks` | `block, block, …` | hill bands, bottom to top (up to 8) |
| `pillar_block` | `block` | block used for the pillars |

The parser is shared (`src/core/cfg.asm`). Every reader reports problems as
`<file>: <message>` warnings and keeps going.
