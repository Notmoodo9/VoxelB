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

Sections and nested records (for blocks, biomes, items, …) will be added to
this format by Milestone 7 (block registry). This document is extended then.

## Files

| File | Read by | Contents |
|---|---|---|
| `data/config/controls.cfg` | `src/platform/input.asm` | key bindings (actions → up to 2 keys) and mouse/fly settings |
| `data/config/graphics.cfg` | `src/world/stream.asm` | graphics settings (render distance) |
| `data/world/flat_test.cfg` | `src/world/world.asm` | **debug** test world: placeholder blocks, layers, test structures |

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

### `flat_test.cfg` (debug content, Milestones 5–6)

The world is infinite: every column gets the layers; the test structures
sit around the origin.


| Key | Value | Meaning |
|---|---|---|
| `block` | `name, RRGGBB` | declare a placeholder block with a flat colour (ids in order, 1..255) |
| `layer` | `block, top_y` | bottom-up layers; each fills up to `top_y` (inclusive) |
| `test_structures` | `0`/`1` | banded hills and pillars around the origin |
| `structure_blocks` | `block, block, …` | hill bands, bottom to top (up to 8) |
| `pillar_block` | `block` | block used for the pillars |

The parser is shared (`src/core/cfg.asm`). Every reader reports problems as
`<file>: <message>` warnings and keeps going.
