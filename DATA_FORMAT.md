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
| `sway` | `0`/`1` | the block waves in the wind (leaves) |
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
