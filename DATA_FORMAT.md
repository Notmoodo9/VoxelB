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
| `data/config/graphics.cfg` | `src/core/settings.asm` | graphics settings (render distance, LOD, effects) |
| `data/config/game.cfg` | `src/core/settings.asm` | field of view, autosave, HUD |
| `data/blocks/*.blocks` | `src/world/block.asm` | the block registry: every block, its textures and render settings |
| `data/world/world.cfg` | `src/world/world.asm` | world seed and generator (`terrain` or `flat_test`), day length, clouds, gravity |
| `data/entities/player.cfg` | `src/sim/player.asm` | the player's body size and movement speeds (walking, swimming, climbing, flying) |
| `data/world/terrain.cfg` | `src/world/terrain.asm` | the terrain generator: noise fields, splines, heights, surface blocks |
| `data/world/caves.cfg` | `src/world/terrain.asm` (used by `caves.asm`) | caves, ravines, shafts, aquifers, lava, cave decoration |
| `data/biomes/*.biome` | `src/world/biome.asm` | climate fields, tree generators, biomes (colours, terrain, plants, flowers, meadows, trees, ponds) |
| `data/world/ores.cfg` | `src/world/terrain.asm` (used by `caves.asm`) | ores: blocks, heights, cluster sizes and counts |
| `data/world/flat_test.cfg` | `src/world/world.asm` | **debug** test world: layers, block gallery, test structures |
| `assets/textures/blocks/*.png` | `src/render/block_textures.asm` | block textures (16×16, animated strips, glow layers) |
| `data/items/*.items` | `src/world/items.asm` | items beyond the blocks, item settings, the Creative inventory's tabs |
| `data/items/mining.cfg` | `src/world/mining.asm` | how blocks are mined (hardness, tool, tier) and what they drop |
| `assets/textures/items/*.png` | `src/render/item_icons.asm` | item pictures (16×16), for items that are not blocks |
| `data/ui/menu.cfg` | `src/core/game.asm` | the main menu's background: world seed, time, the camera's path |
| `data/version.cfg` | `src/ui/menu.asm`, CI | the game's version (`version = 0.<milestone>.<part>`) and its `title`: shown in the main menu; each new version gets its own release |
| `data/ui/credits.txt` | `src/ui/menu.asm` | the Credits screen: plain text, one line per line (the first is the heading) |
| `assets/fonts/ui_sdf.png`, `ui_sdf.cfg` | `src/ui/ui_draw.asm` | the menus' / HUD's SDF font (made by `tools/make_sdf_font.py`) |

### `controls.cfg`

Actions: `move_forward`, `move_back`, `move_left`, `move_right`, `move_up`,
`move_down`, `sprint`, `toggle_debug_overlay`, `toggle_vsync`,
`reload_shaders`, `menu`, `toggle_held_light`, `time_forward` (hold: the clock runs 240× faster),
`break_block` (Mouse1), `place_block` (Mouse2: the item in hand),
`pick_block` (Mouse3: brings the targeted block's item to hand),
`inventory` (E), `hotbar_1` … `hotbar_9` (1–9; the mouse wheel also steps
through the hotbar), `recipe_book` (R: the recipe book page next to a
crafting grid), `swap_hands` (F: the main and the off hand trade items),
`dodge` (V, Milestone 21: a dodge roll the way you move, back when
standing; a double tap of `move_left` / `move_right` / `move_back` rolls
too; holding `place_block` with a shield in the off hand raises it);
holding break or place repeats it every 0.25 s. Each takes one or two key names (the list of
names is at the top of the file).

Settings: `mouse_sensitivity` (degrees per mouse count), `invert_mouse_y`
(0/1). (The flying speeds moved to `player.cfg` in milestone 16.)

Movement (milestone 16): `move_up` jumps, swims up, climbs and flies up;
pressing it twice within 0.3 s starts or stops flying (Creative).
`move_down` sneaks (never walking off an edge), dives and flies down.
`sprint` runs forward.

The settings screen (milestone 17) writes `controls.cfg`, `graphics.cfg`
and `game.cfg` back when it closes: only the values of the keys it
manages are replaced; comments, blank lines, other keys and their order are
kept (`src/core/cfg_write.asm`). An unbound key slot is written as nothing
(`pick_block =`).

### `graphics.cfg`

| Key | Value | Meaning |
|---|---|---|
| `render_distance` | `2`–`48` (default 16) | full-detail view distance in chunks. Columns are generated two rings further out (so edge chunks can be meshed and lit against all 8 neighbours) and unloaded four rings beyond it |
| `lod_distance` | `0`–`256` (default 64) | distant terrain (LOD tiles) out to this many chunks; `0`, or a value not beyond `render_distance`, turns it off. 64 is the default; 128–256 for strong PCs |
| `opaque_leaves` | `0`/`1` (default 0) | `1` draws cut-out blocks (leaves) as solid cubes: faster on weak GPUs |
| `gpu_culling` | `0`/`1` (default 1) | `1` culls the draws in a compute shader (exact frustum test) and lets the GPU write the indirect commands; `0` draws everything the CPU's visibility walk found |
| `bloom` | `0`/`1` (default 1) | glowing blocks and the sun bleed light into their surroundings |
| `height_fog` | `0`/`1` (default 1) | mist that gathers in low ground, thinning with height |
| `shadows` | `0`/`1` (default 1) | cascaded shadow maps from the sun and moon |
| `shadow_resolution` | 512, 1024, 2048, 4096 (default 2048) | shadow map size: sharper but slower |
| `shadow_distance` | 32–512 blocks (default 160) | how far shadows reach |
| `clouds` | `0`/`1` (default 1) | the drifting cloud layer |
| `water_quality` | `0`–`2` (default 2) | 0 simple see-through water, 1 refraction, depth colour and foam, 2 also reflections |
| `smooth_lighting` | `0`/`1` (default 1) | `1` mixes each face's 4 corner lights smoothly; `0` lights a face flat |
| `ambient_occlusion` | `0`/`1` (default 1) | `1` darkens inner corners and edges |
| `held_light` | `r, g, b` (0–15, default 14, 11, 6) | colour of the held light (`toggle_held_light`), a stand-in for held torches until items |
| `occlusion_culling` | `0`/`1` (default 1) | `1` also skips sections hidden behind the previous frame's depth (Hi-Z); needs `gpu_culling` |

### `game.cfg` (Milestone 17)

| Key | Value | Meaning |
|---|---|---|
| `fov` | `50`–`110` (default 70) | vertical field of view in degrees |
| `autosave_minutes` | `0`–`1440` (default 5; `0` = only when leaving the world) | how often the world being played is saved (moved here from `world.cfg`) |
| `show_hud` | `0`/`1` (default 1) | `0` hides the crosshair and the held block's name |
| `recipe_book` | `0`/`1` (default 1) | the recipe book page is open next to crafting grids (the game writes the player's last choice) |

### `assets/textures/ui/journal.cfg` (Milestone 18 part 5)

The journal UI's pieces in `journal.png` (both written by
`tools/texgen/uigen.py`; edit or replace them to reskin the UI):
`<piece> = x, y, w, h, border, scale` — the piece's rectangle in the atlas
(pixels), its 9-slice border (atlas pixels: kept, the middle repeats; 0 =
the whole picture is stretched) and its size on screen (UI units per atlas
pixel). Pieces: `leather`, `page`, `slot`, `slot_hi`, `seal`,
`corner_tl/tr/bl/br`, `ribbon`, `button`, `button_hi`, `field`, `book`,
`check_off`, `check_on`, `knob`, `strip`, `strip_slot`, `tip`, `page_tile`.
Missing files: plain rectangles.

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
| `light` | `r, g, b` (0–15 each) | coloured light the block emits; it spreads up to 15 blocks, losing 1 level per block |
| `light_filter` | `0`–`15` | extra light lost per block passed for non-opaque blocks (water 1). Default: 1 for cut-out cubes (leaves), else 0. Opaque blocks stop light |
| `sway` | `0`/`1` | the block waves in the wind (leaves; plants bend from the ground) |
| `tint` | `grass` / `foliage` / `water` / `none` [`, faces…`] | the faces (default all) take the biome's grass, foliage or water colour, blended across biome borders |
| `waterlogged` | `1`: the block is drawn inside water (river weed): the mesher treats its cell as water for faces |
| `shape` | see below (default `cube`) | a non-cube shape. **Must be the first setting of a new block** (in a template: the first line after `name`), because it reserves one block id per state |
| `upper_textures` | like `textures` | door shapes only: textures of the upper half |
| `collision` | `none` / `full` | what the player bumps into. Default: cubes are solid, shapes collide as their parts (fences, fence gates and walls 1.5 blocks high), plants, signs, pressure plates and liquids not at all |
| `climbable` | `0`/`1` | ladders and vines can be climbed (default: `1` for the `ladder` shape) |
| `liquid` | `none` / `water` / `lava` | the player swims in it (lava slows more); liquids have no collision |
| `source` | a block name | a flowing liquid (`shape = fluid`): the source block it flows from. That source then spreads as this block (milestone 16) |
| `flow_range` | `1`–`7` (default 7) | a flowing liquid: how many blocks it spreads sideways from a source (water 7, lava 3) |
| `flow_delay` | `1`–`100` ticks (default 5) | a flowing liquid: time per step of spreading (1/20 s; water 5, lava 30) |

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
| `fluid` | levels 1–7, falling | flowing liquid: a box as high as its level (14/16 down to 2/16; falling and liquid-covered: full), with the sides drawn where neighbouring liquid is lower. Needs `source` |
| `axis` | upright, east-west, north-south | a cube log: the `end` texture faces along its axis (logs lying in fallen trees and branches) |
| `facing` | front north, east, south, west | a cube whose `north` texture is its front; placing turns the front towards the player (chests) |
| `headstone` | front north, east, south, west | a gravestone (Milestone 20): a plinth (x 4–12, z 4–12), the stone (4–12 wide, 2–12 high) with a cap, and a satchel at its foot (x 6–10, z 0–4); the side textures turn with the front like `facing` |

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
| `day_length` | minutes (default 20) | length of one day and night |
| `start_time` | hour 0–24 (default 8) | time of day at the start (`--time <hour>` overrides) |
| `cloud_cover` | 0–1 (default 0.45) | share of the sky the cloud layer covers |
| `cloud_height` | world y (default 230) | bottom of the cloud layer (48 blocks thick) |
| `gravity` | blocks/s² (default 32) | how fast the player falls |

### `player.cfg` (Milestone 16)

The player's body and movement. All values are numbers ≥ 0; speeds are
blocks per second.

| Key | Default | Meaning |
|---|---|---|
| `width`, `height` | 0.6, 1.8 | the body's box |
| `eye_height`, `sneak_eye_height` | 1.62, 1.27 | eyes above the feet |
| `walk_speed`, `sprint_speed`, `sneak_speed` | 4.317, 5.612, 1.31 | on foot (sprint: forward only) |
| `jump_velocity` | 8.95 | upward speed of a jump (≈1.25 blocks with gravity 32) |
| `ground_accel`, `air_accel` | 0.5, 0.08 | share of the gap to the wanted speed closed per tick (20 per second) |
| `terminal_speed` | 78 | fastest fall |
| `step_height` | 0.6 | walks up slabs and stairs without jumping |
| `swim_speed`, `swim_sprint_speed` | 2.2, 4.0 | in water |
| `swim_up_speed`, `sink_speed` | 3.5, 1.5 | rising with `move_up` (diving with `move_down`), sinking otherwise |
| `water_accel` | 0.2 | like `ground_accel`, in liquids |
| `lava_slowdown` | 0.5 | swim speeds are multiplied by this in lava |
| `climb_speed`, `climb_down_speed` | 2.35, 3.0 | ladders and vines: up, and the slowest slide down |
| `fly_speed`, `fly_sprint_multiplier` | 12, 5 | Creative flight |
| `fly_vertical` | 0.6 | share of the flight speed for going up and down |
| `fly_accel` | 0.35 | like `ground_accel`, flying |
| `reach` | 5 | how far away (from the eyes) blocks can be broken and placed |
| `flytest_speed` | 60 | `--flytest` (streaming test): flies north through everything |

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

`[climate]` — `grass_reference`, `foliage_reference`, `water_reference` (RRGGBB): the average
colour of the grass / oak leaf textures (a biome colour equal to these leaves
the texture unchanged); `contrast` (climate noise spread, default 1).

`[noise temperature]`, `[noise humidity]`, `[noise weirdness]`, `[noise dunes]`, `[noise plateaus]`, `[noise mesas]`, `[noise strata]`, `[noise rarity]` — the climate fields, the dune shape, the plateau mask, the mesa mask, the band wave and the rarity field (`ridged = 1` allowed) (`scale`,
`octaves`, `persistence`, `salt`); larger scale = larger biomes.
Temperature and humidity are 0..1.

`[tree <name>]` — a tree or bush generator:

| Key | Meaning |
|---|---|
| `kind` | `round` (trunk + round crown), `branching` (trunk, diagonal branches with leaf clusters, crown), `bush` (log stub + low leaf clump), `giant` (tapering flared trunk, arching roots, heavy branches with leaf clusters, crown), `fallen` (a log lying on level ground, length = `height`), `stump` (a short upright log), `cactus` (column of `height`, `branches` arms, `leaves` = flower on top with `chance`), `rock` (discs shrinking upward from `radius`, `height` tall; `leaves` = optional block on its upper half), `arch` (a half-ring of `radius` with legs in the ground), `fossil` (a half-buried spine `height` long with ribs, of `log`), `palm` (curved trunk of `height`, 8 drooping fronds of `radius`), `conifer` (trunk of `height`, tiers of `leaves` shrinking from `radius` to a tip), `acacia` (trunk of `height` splitting into 2 forks and 2–4 limbs, each ending in a flat leaf pad of `radius`), `baobab` (bottle trunk of `base_radius` bulging in the middle, `height` tall, `branches` stubby branches with leaf tufts of `radius`), `kapok` (jungle giant: `roots` buttress fins, a bare round trunk of `base_radius`, `height` tall, `branches` thick branches from 72–86% of the height ending in wide flat clusters of `radius`), `stone_ring` (`branches` standing stones of `log`, `height` tall and 1–2 wide, evenly on a ring of `radius`, `leaves` = their top block), `spike` (discs from `radius` at the base to a point at `height`, slimming as (1 − t)^1.3; the centre column and the top 30% are `leaves`, the core; the base sinks 2 into the ground), `mushroom` (a stem of `log`, `base_radius` wide, `height` tall; a cap of `leaves` with `radius`, a dome when `chance` ≥ 0.5 else a flat disc; `underside` = a gills ring under the cap; `fungus` on the stem), `gnarled` (a trunk of `base_radius` tapering upwards whose centre drifts, turning every 4 blocks so it twists and leans, `height` tall; `roots` knotted roots; `branches` crooked branches from 55–85% of the height ending in crowns of `radius`; a top crown), `cypress` (trunk flared to `base_radius` at the ground tapering over 3 blocks, `height` tall, 3 flat layered crowns of `radius`, `roots` knees poking out of the water), `grove` (a disc of `radius` with a `log` stalk on a share `chance` of the columns, `height` tall, each with a `leaves` tuft on top: bamboo groves), `iceberg` (placed by a biome's `iceberg` list on deep water: `branches` lobes, the first centred with `radius` and `height` above the sea, the others smaller, lower and off-centre; peaked, or flat-topped (tabular) with `chance`; a body of `log` with streaks of `leaves`, `top_block` on its gentle top; it reaches 0.6 × its height under the surface, never into the sea floor) |
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
| `underside` | mushroom: the block of the ring under the cap (gills) |
| `top_block` | iceberg: the block on its top (snow) |
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
| `rarity` | `lo, hi`: the biome only where the `rarity` field (0..1, independent of temperature, humidity and weirdness) is in this range: rare pockets that overlap any weirdness band (default 0–1) |
| `island_chance` | floating islands: chance per 48×48 cell (× the vegetation density at the island's centre) |
| `island_radius`, `island_height` | island radius range (max 25) and centre height range (Y) |
| `island_ore` | `block, chance` (repeatable, up to 8): blocks in the islands' stone (ores, crystals) |
| `island_roots` | `block, chance`: strands (2–5 long) hanging under the islands, chance per column |
| `grove_chance`, `grove_radius`, `grove_density` | tree groves (clumps): chance per 128×128 cell, radius range, trees per block² inside a grove (instead of `tree_density`) |
| `grove_tree` | `tree, weight` (repeatable, up to 8): the trees of the groves (instead of the `tree` list) |
| `water_color` | RRGGBB: the biome's water colour (a third tint layer; water keeps its texture's brightness and takes this hue). Default: `water_reference` (`[climate]`, the texture's own colour) |
| `flatten` | `level, pull`: pulls the land towards `level` by `pull` (0..1, blended). With the small detail bumps, a level just above the sea makes a maze of pools and islands (swamps) |
| `own_shore` | 1: the shore band uses the biome's own ground (top, patches) above the sea and its `pond_floor` (else mud) below it, instead of beach sand |
| `water_plant` | `block, chance` (repeatable, up to 8): plants floating on the water surface of ponds and the sea over low ground (lily pads) |
| `beach_block` | the shore band block (default the world's beach sand) |
| `beach_patch` | `block, level`: on the shore band above the water, where the detail noise (−1..1) is above `level` (snow on frozen shores) |
| `seabed_block`, `seabed_patch` | the sea floor block (default beach sand) and its high patches (default gravel); clay patches stay |
| `sea_ice` | frozen sea: the floe block at the sea surface over open water (pack ice; 0 = none) |
| `sea_ice_floe` | `size, channel`: floes are Voronoi cells of `size` blocks; where two meet, `channel` (× 0.5–1.5 per floe) of open water |
| `sea_ice_cover` | `share, fade`: share of the floes frozen; it fades to 0 over the warmest `fade` of the biome's temperature range |
| `sea_ice_snow` | `block, share`: share of the floes covered with this block instead |
| `sea_ice_ridge` | `block, share`: pressure ridges, one block high, along the edges of this share of floe pairs |
| `sea_ice_shore_depth` | water no deeper than this is always frozen (shore-fast ice) |
| `smooth_height` | `1`: the biome's `height` range is tested against the smoothed surface height (the mean of the height and 4 samples 24 blocks away), so it reaches down valleys between high ground (glacier tongues) |
| `ice_block` | glacier: the ice laid on the ground (0 = none); the ice ends where the blended weight of such biomes drops below `ice_edge` |
| `ice_deep`, `ice_snow` | `block, depth`: the ice this deep below the surface and lower (blue ice); `block, height`: the top above this height (snow, jittered like the snow line) |
| `ice_cap`, `ice_fill` | thickness range on ridges (varies smoothly); `offset, max`: the ice fills up to the smoothed height minus `offset`, at most `max` thick |
| `ice_edge` | `weight, band`: the ice ends (a sheer wall) at this blend weight; the `band` below it is a moraine ridge |
| `moraine_block`, `moraine_height` | the moraine's top block and ridge height |
| `crevasse` | `threshold, depth`: ridged-noise lines above `threshold` (0..1, inside crevasse fields) are cut up to `depth` into the ice |
| `ice_caves` | 3D noise threshold for caves inside ice at least 10 thick (0 = none) |
| `serac` | `slope, jitter`: where the smoothed height slopes more than `slope` blocks per block, the ice breaks into 3×3 blocks ± `jitter` high |
| `river_biome` | the biome its river columns take (the river water and a strip of low bank beside it); default: the biome named `river`. River biomes get an impossible `height` so the climate never picks them |
| `own_colors` | river biome: `1` = its own grass and foliage colours on river columns (default: the land's; the water colour is always its own) |
| `trees_in_water` | `own_shore` biomes: `1` = trees may also stand in water up to 2 deep (swamp cypresses); otherwise only on dry low ground |
| `bed_plant` | `block, chance` (repeatable): plants on the bed under the sea or a river, at least 2 deep (tall plants need 3) |
| `water_feature`, `water_feature_density`, `water_feature_depth` | the same layer as `iceberg`: trees placed on water at least `depth` deep (default 4); `iceberg` kinds float at the surface, others (rocks) stand on the bed |
| `iceberg`, `iceberg_density` | `tree, weight` (repeatable, up to 8): icebergs on water 4+ deep (`iceberg` kind trees); per block² |

### `[cave_biome <name>]` (in `data/biomes/`)
A decorated cave region underground (design/biomes/crystal_caves.md),
applied after the cave decoration to stone and cave air under the surface
crust.

| Setting | Meaning |
|---|---|
| `depth` | `lo, hi`: y range |
| `region`, `region_scale` | `lo, hi`: range of its 3D region noise (−1..1); its scale in blocks (default 120; flattened 1.5× vertically) |
| `theme`, `theme_scale` | `crystal, sprout, stone, pool` blocks (repeatable, up to 8 themes); a second noise of `theme_scale` blocks (default 200) picks one per area |
| `rainbow` | share of 16-block cells that mix every theme per block |
| `moss` | `block, level`: floor patches where their noise is above `level` |
| `pool_threshold` | floors become the theme's pool (top 2 blocks) where the pool noise is above this (0 = none) |
| `sprout_chance`, `clump_chance`, `stalactite_chance` | per floor / ceiling block: the theme's sprout (spike shape: state 0 up, 1 down), crystal clumps (1–3 up), crystal stalactites (1–3 down) |
| `fungus` | `block, chance`: a floor plant |
| `ore` | `block, chance`: replaces stone inside the region |
| `pillar_chance`, `pillar_radius` | per 16×16 cell of a chunk: a disc where all cave air becomes the theme's crystal (floor-to-ceiling pillars); radius range |
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

### `menu.cfg` (Milestone 17)

| Key | Value | Meaning |
|---|---|---|
| `seed` | number | the world shown behind the main menu |
| `time` | hour 0–24 | the (still) time of day there |
| `speed` | blocks/s | how fast the camera glides along the path |
| `look_at` | x, y, z | the point the camera keeps facing |
| `point` | x, y, z | the path, two or more points in order; at the end it fades and starts again |

## Item files (`data/items/*.items`, Milestone 18)

Read in file-name order after the blocks. Every block is an item by itself
(its first state; the flowing states of liquids are not), with the block's
name and a title made from it ("stone_bricks" → "Stone bricks"). Records:

| Record | Key | Meaning |
|---|---|---|
| `[tab <id>]` | `title` | the tab's name in the Creative inventory |
| | `icon` | the item shown on the tab |
| | `blocks` | name patterns (`*` = anything, comma-separated): a block item goes to the first tab one of whose patterns matches its name |
| `[hidden]` | `blocks` | patterns of block items left out of the Creative inventory (e.g. `*_wall_sign`) |
| `[item <name>]` | `title` | the shown name |
| | `texture` | a 16×16 picture in `assets/textures/items/` (items that are not blocks) |
| | `block` | the block it places |
| | `stack` | 1–64 (default 64) |
| | `tab` | the tab id (items that match no tab pattern go to the last tab) |
| | `hidden` | `1`: not in the Creative inventory |
| | `tool` | `pickaxe`, `axe`, `shovel` or `hoe`: the item is that tool (default none) |
| | `tier` | `wood`, `stone`, `copper`, `iron`, `diamond`, `mythril`, `adamantite`, `star_crystal` (default hand) |
| | `speed` | mining speed with the right tool (default 1 = by hand) |
| | `durability` | uses before it breaks (0 = never wears); each block a tool breaks (not ones that break at once) wears it by one |
| | `repair` | a tool's repair material (item patterns), used at a station with `repair = 1` (the Tinker's table) |
| | `binding` | the binding (item patterns) each repair also needs |
| | `fill` | `<block>, <item>` (Milestone 19 part 3b, up to 16 in all items): right click with this item on that block (looked at, plants and other liquids in between are looked through) takes the block away and the item becomes `<item>` — an empty bucket scoops a water source (`fill = water, water_bucket`). In Survival one item of a stack turns; the new one goes into the inventory (dropped if there is no room) |
| | `leaves` | the item left in hand once this one is used up (placed): a water bucket places water and leaves the bucket |
| | `food` | `hunger, saturation` (Milestone 20): the item can be eaten (hold the use button); hunger points it fills (0–20) and saturation it adds (never above hunger) |
| | `poison` | % chance that eating it gives food poisoning |
| | `eat_time` | seconds it takes to eat (default `eat_time` in survival.cfg) |
| | `always_edible` | `1`: can be eaten with full hunger (milk) |
| | `cures_poison` | `1`: ends food poisoning |
| | `weapon` | (Milestone 21) `sword`, `axe`, `spear` or `mace`: what kind of weapon it is (axes are tools too). Swords sweep; axes and maces hit hard (a longer hit pause) |
| | `damage` | health points a full swing takes (default: combat.cfg `hand_damage`) |
| | `swing` | seconds the swing meter takes to fill (default `hand_swing`) |
| | `knockback` | × the usual knock-back (default 1) |
| | `reach` | extra blocks of reach (spears 1) |
| | `armor` | (Milestone 21 part 2) where it is worn: `head`, `chest`, `legs`, `feet`, `shield` (the off hand) or `trinket` (the 2 charm slots) |
| | `protection` | protection points it gives worn in its slot (see combat.cfg) |
| | `weight` | `light` (default), `medium` or `heavy`: how much it slows (see combat.cfg) |

An `[item]` with an existing item's name (a block's, too) changes that item.

### `mining.cfg` (Milestone 18)

| Record | Key | Meaning |
|---|---|---|
| `[material <name>]` | `hardness` | seconds-ish: time = hardness × 1.5 (× 5 when the block won't drop), divided by the right tool's `speed`; `0` = at once, below 0 = unbreakable |
| | `tool` | the tool that mines it fast (`pickaxe`, `axe`, `shovel`, `hoe`) |
| | `tier` | the tier that tool needs for the block to drop anything (`hand` = no need) |
| | `blocks` | block name patterns (`*` = anything) |
| | `shapes` | block shapes (`plant`, `tall_plant`, `fluid`, …) |
| `[drops]` | `<block pattern> = <item> [count]` | what a block drops instead of itself; `none` = nothing |
| `[bonus]` | `<block pattern> = <item> <count>, <percent>` | a chance of something extra besides the usual drop (resin from logs, plant fibre from grass). A block can match two `[bonus]` lines (Milestone 19 part 3: grass gives plant fibre and seeds); each is rolled on its own |

A block takes the first material whose `shapes` or `blocks` match it (all
its states alike); unmatched blocks are hardness 1, any tool, no tier. The
first matching `[drops]` line counts; otherwise a block drops its own item.

## Recipe files (`data/recipes/*.recipes`, Milestone 18)

Read in file-name order after the items. Stations first (a recipe can
only name a station defined before it).

| Record | Key | Meaning |
|---|---|---|
| `[station <name>]` | `block` | the block that opens this station's crafting grid on right click (sneak + right click places a block against it) |
| | `grid` | 2 or 3 (default 3) |
| `[container <name>]` | `block` | the block that opens these slots on right click (a chest) |
| | `slots` | 1–27 (default 27) |
| | `joins` | `1`: two side by side with the same facing open as one container of twice the slots |
| `[station <name>]` | `repair` | `1`: its grid also repairs tools (a worn tool + 1–3 pairs of its `repair` material and `binding` → a third of its durability back per pair) |
| `[furnace <name>]` | `block` | the furnace block (right click opens input, fuel, output) |
| | `lit` | the block shown while it burns (same facing; also opens it) |
| | `speed` | 1–8: smelts and burns fuel that many times faster (default 1) |
| | `blast` | `1`: can also smelt the `[smelt]` recipes marked `blast` |
| `[smelt <name>]` | `input` | item patterns it smelts |
| | `result` | `<item> [count]` |
| | `seconds` | time in a furnace of speed 1 (default 10) |
| | `blast` | `1`: only in a furnace with `blast = 1` |
| `[fuel]` | `<item pattern> = seconds` | how long one item burns (one line per fuel; one item smelts in 10 s) |
| `[rack <name>]` | `block` | a drying rack (Milestone 19 part 3): the empty rack block. Right click with a `hang` input puts it up; when it is dry, right click takes the result |
| | `hang` | `<input item>, <wet block>, <result item>, <dry block>` — what can hang: the rack shows the wet block while it dries, the dry block when done (up to 16 lines in all racks) |
| | `seconds` | drying time (default 10). Breaking a full rack drops what `mining.cfg` says (the hide and the rack) |
| `[grave <name>]` | `block` | a gravestone (Milestone 20 part 2): the block the game places where a player died with the `grave` death rule; right click gives back everything it holds (each item into the slot it came from if that is empty, else wherever it fits; the rest drops) and the block crumbles |
| `[recipe <name>]` | `shape` | rows split by `/`, up to 3 × 3; one character per cell: a key letter, or `.` for an empty cell. A shape matches anywhere in the grid, mirrored too |
| | `A` … `Z` | a key: item name patterns (`*` = anything; a comma list = any of them) |
| | `ingredients` | instead of a shape: up to 9 patterns, one item each, in any cells (shapeless) |
| | `result` | `<item> [count]` (count 1–64, default 1) |
| | `station` | made only at this station (default: by hand, which also works at any station whose grid is big enough) |
| | `each` | a pattern with one `*`: the record becomes one recipe per item whose name fits, and `{}` in every value is what `*` stood for. A copy whose result or an ingredient names no item is left out without a warning |
| | `only` | with `each`: only where what `*` stood for fits these patterns |

Example: every kind of planks gives its own slab:

```
[recipe wood_slab]
each = *_planks
shape = PPP
P = {}_planks
result = {}_slab 6
```

A recipe bigger than 2 × 2 needs a 3 × 3 grid, so it is made at a
workbench. Debug builds check a few known grids at start and log
`recipes: self-check PASS`.

## Mob files (`data/mobs/*.mob`, Milestone 19)

Animals (design/mobs/passive_animals.md). Read in file-name order after the
items and biomes; models must come before the mobs that use them. Adding an
animal never needs assembly. Records:

| Record | Key | Meaning |
|---|---|---|
| `[model <name>]` | `skin_size` | `64 64` (every skin is 64 × 64; one texture array) |
| | `part` | `name, motion, pivot x y z, box x y z, size w h d, u v` — one box (up to 32 per model). Pixels: 16 = one block; the model faces north (−Z), y up from the feet centre. `box` is the box's low corner from the pivot (halves allowed), `size` whole pixels, `u v` its place in the skin. `motion`: `none`, `head` (turns and tilts with the look), `leg0` / `leg1` (swing in opposite phases when walking), `tail` (sways), `coat` (part 3: still; not drawn while the animal is shorn), `wing0` / `wing1` (part 3: left and right wings, beating while off the ground), `head_male` (part 3b: turns with the head, shown only on grown males — antlers) |
| `[mob <name>]` | `title` | the shown name |
| | `health` | hit points (a weapon takes its `damage`, Milestone 21; a fraction of a point is taken with that chance) |
| | `size` | `width height` of its body box, in blocks (babies half) |
| | `speed` | walking speed, blocks per second (running away: 2.2 ×) |
| | `temper` | `calm` (runs when hurt), `wild` (also runs from a player within 12 blocks) or `fierce` (part 3: when hit it charges the player for up to 6 s and knocks them back; its herd stays) |
| | `drop` | `item, min, max [, male] [, N%]` — loot when it dies (up to 4; babies drop nothing). Item `coat`: the variant's coat item, not dropped by a shorn animal. `male` (part 3b): only males drop it (antlers); `N%`: dropped at all only that often (rabbit's foot) |
| | `shear` | `tool, min, max` (part 3): right click with the tool takes the coat of a grown-up (min–max of its variant's coat item); the coat grows back when it grazes. The tool wears in Survival |
| | `glide` | fastest fall in blocks per second (part 3: chickens flutter down; their `wing0`/`wing1` parts beat while off the ground) |
| | `lays` | `item, min, max` (part 3): a grown-up drops the item every min–max seconds (eggs) |
| | `food` | items (up to 4): it follows a player holding one; feeding a grown-up makes it look for a mate, feeding a baby helps it grow (Milestone 19 part 2) |
| | `graze` | `1`: it eats grass (the grass block turns to dirt for 1–3 minutes) |
| | `sexes` | `1` (part 3b): each animal is born male or female (half each; saved); males show `head_male` parts and drop `male` loot |
| | `jump` | blocks it can jump up (part 3b, 1–4, default 1: a step; deer 2, goats 3); its paths may climb that high |
| | `fall` | blocks its paths may drop down (part 3b, 1–8, default 3; goats 6) |
| | `hops` | `1` (part 3b): it moves in little hops (rabbits) |
| | `eats` | block name patterns (part 3b, up to 8 animals): now and then it walks to such a block within 4 blocks and eats it — the block is gone for good (rabbits and flowers) |
| | `rams` | `distance, percent` (part 3b): a player standing within `distance` blocks gets rammed (a charge and knock-back, like a boar's) with `percent` % chance a second |
| | `milk` | `item, item` (part 3b): right click on a grown-up with the first item (a bucket) turns it into the second (a milk bucket) |
| | `baby_skin` | `variant, skin` (part 3b, after the `variant` line): the young of that look wear this skin (spotted fawns, yellow chicks) |
| | `ram_damage` | health points a charge or ram takes from the player (Milestone 20; boars 4, goats 2) |
| | `variant` | `name, skin, model [, coat]` — a look (`assets/textures/mobs/<skin>.png`); `coat` is the item its coat gives (sheep: its wool) |
| `[spawn]` | `mob` | the animal |
| | `variant` | one of its variants (default its first) |
| | `biomes` | biome names |
| | `chance` | % of those biomes' chunk columns that get a herd when first generated (the rules of a biome add up; above 100 every column) |
| | `herd` | `min, max` animals (1–16) |
| | `mix` | `variant, percent` (part 3, up to 4): that many % of the herd's animals get this other look of the same animal (a few black sheep in a white flock) |
| | `altitude` | the lowest ground (y) for this rule's herds (part 3b: goats on the higher slopes) |

Skin layout of a box with size w × h × d at (u, v), in pixels: top
(u+d, v) w × d, bottom (u+d+w, v) w × d, west side (u, v+d) d × h, front
(−Z) (u+d, v+d) w × h, east side (u+d+w, v+d) d × h, back (u+2d+w, v+d)
w × h — `tools/texgen/mobgen.py` paints skins from the same parts (and
`lead_rope`, the texture of the leads, part 3b).

Leads and name tags (part 3b) are items the game knows by name: `lead`
(right click on an animal: it follows the player, pulled along when more
than 6 blocks behind, the lead snaps and drops beyond 10; right click on a
fence ties every animal the player leads within 10 blocks to it) and
`name_tag` (right click on an animal opens a page to type its name, up to
23 characters, shown over its head within 24 blocks).

## Survival (`data/survival/survival.cfg`, Milestone 20)

Health, hunger and damage (design/survival/survival.md). Health and
hunger are in points (2 = one heart / one food icon); times in seconds.
Missing keys keep the built-in values.

| Key | Meaning |
|---|---|
| `health`, `hunger` | the most there is (20) |
| `start_saturation` | saturation after a respawn (5) |
| `exhaustion_per_point` | exhaustion that takes one saturation point, or one hunger point when saturation is gone (4) |
| `exhaust_sprint`, `exhaust_swim` | exhaustion per block sprinted / swum |
| `exhaust_jump`, `exhaust_sprint_jump` | per jump |
| `exhaust_mine`, `exhaust_damage`, `exhaust_heal` | per block broken, per hit taken, per health point regenerated |
| `regen_fast` | `normal` regeneration with full hunger and saturation left: 1 HP every … |
| `regen_slow`, `regen_hunger` | … else 1 HP every `regen_slow` while hunger ≥ `regen_hunger` |
| `starve_every` | at hunger 0: 1 HP every … (down to the difficulty's `starve_floor`) |
| `eat_time`, `eat_speed` | default eating time; walking speed while eating (×) |
| `poison_time`, `poison_exhaust` | food poisoning: how long, exhaustion per second |
| `fall_safe` | blocks fallen without harm; 1 HP for each block more (water, flying and climbing break falls) |
| `air`, `drown_damage` | seconds of air under water; HP each second without |
| `lava_damage`, `burn_time`, `burn_damage` | HP every half second in lava; seconds burning after it, HP each second (water puts it out) |
| `suffocate_damage`, `cactus_damage` | HP every half second with the head in a solid block / touching a cactus |
| `void_y`, `void_damage` | below this y: HP every half second |
| `hurt_time` | no new damage for this long after a hit (the void and starvation still hurt) |

`[difficulty <peaceful|normal|hard|extreme|ultra>]` sections: `damage`
(damage taken ×), `hunger` (exhaustion ×; 0 = no hunger drain, and hunger
fills back up), `regen` (`normal`, `fast` = 1 HP every `regen_every`
whatever the hunger, `full_only` = 1 HP every `regen_every` at full
hunger, `none`), `regen_every`, `starve_floor` (health starvation stops
at; 0 = it kills).

## Combat (`data/combat/combat.cfg`, Milestone 21)

The rules around the weapons' own numbers (item keys `weapon`, `damage`,
`swing`, `knockback`, `reach`). A hit before the swing meter is full does
`damage × (min_factor + (1 − min_factor) × meter²)` and knock-back ×
(0.4 + 0.6 × meter).

| Key | Meaning |
|---|---|
| `hand_damage`, `hand_swing` | the bare hand and items without `damage` / `swing` (seconds) |
| `min_factor` | the share of the damage a swing at an empty meter does |
| `crit_factor`, `crit_meter` | a swing with at least `crit_meter` while falling (not on the ground, in water, climbing or flying) does × `crit_factor` |
| `sweep_damage`, `sweep_fraction`, `sweep_radius` | a full sword swing on the ground also hits the animals within `sweep_radius` blocks of the target for `sweep_damage` + `sweep_fraction` × the damage |
| `reach_extra` | blocks of reach beyond the player's (to an animal's centre) |
| `exhaust_attack` | exhaustion per hit |
| `weapon_wear`, `tool_wear` | durability a hit takes from a weapon / another tool (Survival) |
| `hit_pause`, `crit_pause`, `heavy_pause` | seconds the animals and the arm hold still after a hit / a critical hit / an axe or mace hit (the longest that applies) |
| `shake` | the camera shake's strength (× the meter; 0 = none) |
| `protection_per_point`, `protection_cap` | (part 2) damage from rams, fire, lava and cactus × (1 − `protection_per_point` × min(points, `protection_cap`)); each worn piece wears 1 per such hit (not falls, drowning or starving) |
| `medium_slow`, `heavy_slow`, `heavy_hunger` | by the share of the body in each weight (helmet 15 %, chestplate 40 %, leggings 30 %, boots 15 %): walking × (1 − `medium_slow` × medium − `heavy_slow` × heavy); hunger from moving × (1 + `heavy_hunger` × heavy) |
| `shield_raise`, `shield_arc`, `shield_push` | a shield in the off hand is up after holding `place_block` `shield_raise` seconds (with nothing that eats or places in the main hand); it takes every ram from within `shield_arc` degrees in front: no damage, × `shield_push` knock-back, the shield wears by the damage; the player walks at sneak speed meanwhile |
| `roll_distance`, `roll_distance_medium`, `roll_time`, `roll_safe`, `roll_cooldown`, `exhaust_roll`, `roll_heavy` | the dodge roll (double-tap `move_left` / `move_right` / `move_back`, or `dodge`): `roll_distance` blocks in `roll_time` s, shortened toward `roll_distance_medium` by the medium + heavy share; no damage for `roll_safe` s; `roll_cooldown` s before the next; `exhaust_roll` hunger; none on a heavy share of `roll_heavy` or more, off the ground, in water, climbing, flying or blocking |

## Saved worlds (`saves/<name>/`, Milestone 17)

Written by the game; `--world <name>` picks the world (default `world`,
created if missing), `--nosave` neither loads nor saves. Only the parts
of the world that changed are stored: everything else is generated again
from the seed, identically.

### `world.dat` and `player.dat`

Text in the format above (the game rewrites them on every save, via a
`.tmp` file and a rename, so a crash never leaves half a file).

| File | Key | Meaning |
|---|---|---|
| world.dat | `format_version` | 1 (a newer version is logged as a warning) |
| | `name`, `seed`, `generator` | the world; `seed` and `generator` override world.cfg and `--seed` |
| | `game_mode` | `creative`, `survival`, `adventure` or `spectator` (creative and survival are playable so far) |
| | `difficulty` | `peaceful`, `normal`, `hard`, `extreme` or `ultra` (default `normal`) |
| | `hardcore` | `0`/`1` (only offered on Hard and above) |
| | `death` | (Milestone 20) what happens to the items when the player dies: `drop` (default; they fall where the player died), `grave` (a gravestone keeps them: `graves.dat`) or `keep` (they stay; below Hard only: on Hard and above it acts as `grave`) |
| | `day` | (Milestone 20) the day counter, from 1; the clock passing midnight adds one |
| | `hardcore_dead` | (Milestone 20) `1`: a Hardcore world whose player died; it only opens in spectator mode (written with `game_mode = spectator` once the player chose to spectate) |
| | `last_played` | local date and time of the last save, `YYYY-MM-DD HH:MM` (the world list sorts by it) |
| | `time` | time of day, 0–1 (0 = midnight); `--time` overrides it |
| player.dat | `eye_position` | x, y, z of the eyes (blocks, 4 decimals) |
| | `look` | yaw, pitch in radians |
| | `flying` | `0`/`1` |
| | `selected` | the hotbar slot in hand, 0–8 (Milestone 18) |
| | `slot` | one line per used slot: `index, item, count, durability` (0–8 the hotbar, 9–35 the inventory, 101 the off hand, 102–105 the armor: head, chest, legs, feet, 106–107 the charm slots (Milestone 21); 36 the stack carried by the mouse and 37–45 the crafting grid when the game quit with the inventory open: they go back into the slots on load); unknown items are skipped |
| | `held_block` | (saves from before Milestone 18) a block name: put in hotbar slot 0 |
| | `survival` | (Milestone 20) `health, hunger, saturation, exhaustion, air ticks, burning ticks, poison ticks, dead` |

`containers.dat` holds what is in the chests: a `[container x y z]`
record (the block position) per container that holds anything, then its
`slot = index, item, count, durability` lines (a double chest is two
records, 27 slots each). A furnace also has `station = <name>`,
`burn = <ticks left>, <ticks of that fuel>` and `cook = <ticks>` (it keeps
smelting while you are away; 20 ticks a second).

`racks.dat` (Milestone 19 part 3) lists the drying racks with a hide
drying: `rack = x, y, z, <ticks left>, <input item of the hang line>`. A
rack whose block changed meanwhile is forgotten.

`graves.dat` (Milestone 20 part 2) lists the gravestones still holding
items: `grave = x, y, z, <day>, <name>` (the block, the day its owner
died, their name), then its items, `item = <slot>, <item>, <count>,
<durability>` (the slot it was in: 0–35, 101 the off hand, 102–107 the armor and charms). Up to 64.

`thumb.png` (256 × 144 RGB) in the world folder is the picture shown in
the world list; the game rewrites it on every save.

### Region files (`overworld/region/r.<rx>.<rz>.vxr`)

Binary, little endian, 4096-byte sectors. One file holds 32 × 32 columns
(column `cx, cz` is in region `cx >> 5, cz >> 5`).

* Header (3 sectors): `VXRG`, u32 version (1), 8 reserved bytes, then
  1024 × {u32 first sector, u32 byte length}, index `(cx & 31) + (cz & 31) * 32`;
  0 = not saved.
* A record: `VXCZ`, u32 raw length, u32 compressed length, then the column
  compressed with the LZ format of `src/core/lz.asm` (LZ4-like). Raw:
  `VXCR`, u32 version, i32 cx, i32 cz, u32 section count, then per section
  u8 section index (0–39 from y −256), u8 kind and the blocks (index
  `y << 10 | z << 5 | x`): kind 0 one block id (u16); kind 1 a palette
  (u16 count, u16 ids) and one byte per block; kind 2 u16 per block.
  Sections that are all air are left out.

### Entity region files (`overworld/entities/e.<rx>.<rz>.vxe`, Milestone 19)

The animals, by region of 32 × 32 chunk columns (blocks `rx * 1024` …
`rx * 1024 + 1023`). Binary, little endian:

* Header (144 bytes): `VXEN`, u32 version (2), u32 animal count, u32 0, then
  128 bytes: a bit per column (`(cx & 31) + (cz & 31) * 32`), set once the
  column had its herd roll (it never gets another from generation).
* Then 128 bytes per animal: f64 x, y, z (feet centre), f32 yaw, u16 health,
  u16 flags (1 = baby, 2 = shorn: part 3, 4 = male: part 3b), u32 age in
  ticks, 24 bytes `mob:variant` (zero-padded), u32 herd id (0 = none; part
  2 — files from part 1 have 0 there); then (part 3b) u32 lead (0 none, 1
  held by the player, 2 tied to a fence), i32 × 3 the fence post, 24 bytes
  its name (zero-padded), 20 bytes 0. Version 1 files (64-byte records:
  the first 64 bytes of these) still load. An unknown `mob:variant` (a
  removed data file) is dropped with a warning.

