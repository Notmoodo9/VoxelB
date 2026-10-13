# Progress

## Current state
**Milestone 18, part 2: Mining, drops, Survival (without health yet): DONE** (v0.18.2, Windows CI: see below)

Every version has its own release on GitHub ("VoxelB v<version> -
<title>"), including the past milestones v0.1.0 – v0.16.0 (D92).

Next: **Milestone 18, part 3: crafting and chests** (2x2 and 3x3 grids,
workbench, recipe book, chests that join; design/items/items_inventory.md).

---

## Milestone 18, part 2 — done (2026-10-13): mining and drops (D94)

### What was built
* **Survival** can be chosen when creating a world: you walk (no flying),
  blocks take time to mine, they drop items, placing uses them up. Health
  and hunger come with milestone 20.
* **Mining times** from `data/items/mining.cfg`: hardness, the tool that
  mines a block fast and the tier it needs to drop anything (the ore
  ladder: coal needs wood, copper/iron stone, silver/gold copper,
  diamond/emerald iron, mythril diamond, adamantite mythril, star crystal
  adamantite). Classic pace: sand ~0.75 s by hand, stone ~7.5 s by hand
  and nothing drops. (Tools arrive in part 4.)
* **Drops:** grass → dirt, stone → cobblestone, coal ore → coal, diamond /
  emerald / star crystal ore → the gem; leaves, glass, ice, grass plants
  nothing; everything else itself. New items coal, diamond, emerald, star
  crystal with their own pixel-art pictures (`tools/texgen/itemgen.py`).
* **Cracks** spread over the block while it's mined.
* **Dropped items** pop out, fall, slide, spin and bob, join nearby stacks,
  drift to you within 3 blocks and go into the inventory; gone after 5
  minutes.
* Debug overlay: game mode, dropped items count.

### Verified (scripted with xdotool)
* A Survival world made in the menu (`game_mode = survival` in
  world.dat). Holding break on sand: cracks after ~0.5 s, the block breaks,
  a small sand cube drops into the hole; mining the block underneath
  drops the player onto it and it is picked up (sand ×3 after 8 s of
  digging down); placing sand uses one (5 → 4). Double-tap jump does not
  fly in Survival. Creative: the Items tab shows coal, diamond, emerald,
  star crystal.
* Found and fixed: `--world "World 1"` created a folder named `"World`,
  whose region files could not be written.
* Debug build through the same steps: no assert; headless tests pass.

### Performance
* Mining: a few table lookups per tick. Drops: resting drops cost one
  merge check every 10 ticks; moving ones one collision probe per axis
  per tick and a 48-byte packet; drawing is one 36-vertex call per drop.

### Deferred
* Tools (part 4) — until then everything is mined by hand.
* Wall signs drop the wall-sign item (it places a wall sign); a pattern
  rule that maps it to the standing sign needs name substitution.
* Dropped items are not saved with the world.
* Under the software renderer used for testing, the screen capture
  sometimes catches a black frame (also on v0.18.1; a capture artefact).

---

## Milestone 18, part 1 — done (2026-10-13): items and the inventory (D93)

### What was built
* **Items:** every block is an item (639); `data/items/00_tabs.items`
  sorts them into Creative tabs (Building, Shapes, Colours & glass,
  Lights, Ores & crystals, Items, Nature) by name patterns.
* **Icons:** every item's icon drawn once into an atlas: 3D cubes, slabs,
  flat pictures for plants, doors, fences …
* **Inventory + hotbar:** 9 + 27 slots, stacks of 64, kept by the
  simulation and saved in `player.dat`. HUD hotbar on glass with counts;
  the slot in hand glows teal; its item's name shows for a moment. Keys
  1–9 and the mouse wheel select; middle click brings the targeted
  block's item to hand (Creative: a full stack); placing uses the item in
  hand (Survival will use it up).
* **Inventory screen (E):** drag stacks with the mouse (left: take / put /
  swap, right: half / one, shift: hotbar ↔ inventory), tooltips with the
  item's name. Creative: the catalog with icon tabs, a search field and
  scrolling; click takes a stack, right click one, shift-click puts one
  in the inventory, clicking it with a stack in hand throws it away.
* **Item in hand:** the held block as a lit 3D cube in the lower right
  (plants and items as a flat picture), swaying while walking, swinging on
  break / place.
* Controls: `inventory` and `hotbar_1..9` are rebindable; the Controls tab
  scrolls.

### Verified (scripted clicks and keys with xdotool)
* Hotbar with stone ×64 at start; key 3 + middle click on sand → sand ×64
  in slot 3 with "Sand" shown; placing stone and sand works (edits
  applied); `player.dat` has `selected` and `slot` lines and a reload
  restores them.
* Creative inventory: Lights tab → lime lamp taken and dropped into
  hotbar slot 2 (saved); search "glass" lists every glass block; E and Esc
  close the screen; the HUD hotbar hides while it's open.
* In hand: stone as a cube, a poppy as a flat picture.
* Debug build through the same steps: no assert; headless tests pass.

### Performance
* Icon atlas: 639 icons in 15 ms at start-up (release, llvmpipe).
* The inventory screen is one UI draw call; the item in hand one 36-vertex
  draw.

### Deferred
* Survival mode in world creation, mining times, drops (part 2).
* Crafting (2x2 / 3x3, recipe book) and chests (part 3); tools, smelting,
  repair (part 4).
* Hotbar keys over an inventory slot to swap it (Minecraft-style).

---

## Milestone 17, part 2c — done (2026-10-12): settings (D91)

### What was built
* **Settings screen** (main menu and pause menu), three tabs:
  * **Graphics:** presets Low / Medium / High / Ultra, plus render
    distance, far terrain (LOD), shadows, shadow detail, shadow distance,
    water, clouds, bloom, height fog, smooth lighting, ambient occlusion,
    fast leaves (after a restart), GPU culling, occlusion culling.
  * **Controls:** every action with two key slots: click, press the new
    key or mouse button (Delete: none, Esc: cancel); mouse sensitivity,
    invert mouse Y.
  * **Game:** field of view (50–110), autosave (off … 30 min), show HUD.
* Changes show at once (also behind the pause menu); render/LOD distance
  apply when the screen closes.
* Closing writes `graphics.cfg`, `controls.cfg` and the new `game.cfg`,
  keeping all their comments (only changed files are written).
* `autosave_minutes` moved from `world.cfg` to `game.cfg`; FOV is a
  setting now (was fixed at 70°).

### Verified (scripted clicks and keys with xdotool)
* Main menu → Settings → Low preset: every value switched, Low highlighted;
  Controls: second key of Move forward rebound to I; Game: FOV 70 → 75;
  Done → the three files rewritten with only those values changed
  (comments and other keys intact — checked with git diff), the render
  distance applied (spiral 1009 → 317 offsets) and LOD reset.
* In a world: Esc → pause → Settings → Low: the world behind loses
  shadows, bloom, clouds at once; Done → pause; a rebinding cancelled with
  Esc, Esc again back to the pause menu, Resume plays on.
* Debug build: Ultra preset (spiral 2121) and tab switching without
  warnings; debug and release headless tests pass.

### Performance
* Applying Low → High etc. costs nothing per frame; render distance
  changes stream columns in/out over the next frames like walking does;
  a shadow resolution change rebuilds 3 depth layers once.

### Deferred
* Audio volumes (milestone 24), GUI scale, a key-conflict warning.
* Presets tuned to the FPS targets (milestone 33).

---

## Milestone 17, part 2b — done (2026-10-12): world list and creation (D90)

### What was built
* **World list:** each world is a row with its picture, its name and
  "Creative - Normal - 2026-10-12 21:35 - 109 KB" (mode, difficulty,
  Hardcore if on, last played, size on disk); newest first; scrolls with
  the wheel. Buttons: Play world, New world, Delete, Back.
* **Pictures:** a recent view of the world (no HUD) is kept while playing
  and saved as `thumb.png` with the world.
* **Delete** asks "Delete this world?" (red Delete / Cancel) and removes
  the world's folder.
* **New world screen:** Name (prefilled "World N") and Seed text fields
  (empty = random, a number, or any text, which is hashed); game mode
  (Creative; Survival, Adventure, Spectator greyed "coming later");
  difficulty (Normal, the rest greyed) and Hardcore (greyed), stored in
  `world.dat` for later; Create world (or Enter) / Cancel.
* Names are made safe for folders; a taken name gets " (2)".
* `world.dat` gains `difficulty`, `hardcore`, `last_played`.

### Verified (scripted clicks and typing with xdotool)
* New world named "My Valley?" with seed "mountains": folder "My Valley",
  seed 4243777795 (the text's hash), `world.dat` with all keys, a 256 × 144
  `thumb.png` (checked with PIL).
* A second "My Valley" became "My Valley (2)" (random seed); the list
  showed both with pictures, newest first; Delete → question → Delete
  removed "My Valley" and its folder.
* Seed "12345" gave seed 12345; selecting a world and Play world loaded it
  ("loaded" in the log).
* Debug and release headless tests pass.

### Performance
* Thumbnail capture: one 256 × 144 blit every 2 s. Opening the world list:
  reading `world.dat`, walking the folder and decoding one 110 KB PNG per
  world (a few ms each under Wine).

### Deferred
* Settings screens (part 2c).
* Survival/Adventure/Spectator, difficulties and hardcore are selectable
  once those milestones exist (20, 32).
* Renaming worlds; text field cursor movement (arrow keys) and selection.

---

## Milestone 17, part 2a — done (2026-10-12): menus (D89, design/ui/menus.md)

### What was built
* **Main menu** over a live flyover: the camera glides toward the giant
  mountain range at sunset (`data/ui/menu.cfg`: seed, time, path); the
  title "VoxelB" in big teal-gradient text; Play, Settings (greyed until
  part 2c), Credits, Quit on a glass panel; screens slide and fade in.
* **Worlds:** the saved worlds (folders in `saves/`); click selects, click
  again (or Play world) plays; New world makes "World N" with a random
  seed and starts it. Back returns.
* **Credits** from `data/ui/credits.txt`.
* **Pause menu** (Esc in a world): Resume, Settings (greyed), Save & quit
  to menu, Save & quit game; the world keeps showing, darkened, behind the
  glass. Esc again resumes.
* **World switching** without restarting: save, unload, load the next world
  with its own seed, player and time.
* **New UI renderer:** our own SDF font (Inter), glass panels that blur
  the world behind them, glowing teal buttons; the HUD uses it too.
* Development options (`--world`, `--pos`, `--flytest`, `--flat`,
  `--seed`, `--survey`) still start straight in a world.

### Verified (scripted clicks with xdotool)
* Main menu over the sunset flyover; Credits; Play → Worlds ("No worlds
  yet") → New world → playing "World 1" (saved at once); Esc → pause menu →
  Save & quit to menu → the flyover again; Play → World 1 is listed;
  selecting and clicking it loads it (player restored).
* Debug build with asserts through the same path: no warnings; debug and
  release headless tests (now starting on the main menu) pass.

### Performance
* The UI is one draw call; the glass needs two small blits of the frame.
  World switching takes as long as the new view needs to stream in.

### Deferred (next parts of milestone 17)
* World list details (thumbnail, mode, last played, size), the world
  creation screen, deleting worlds (part 2b).
* Settings screens (part 2c).

---

## Milestone 17, part 1 — done (2026-10-12): saving and loading (D88)

### What was built
* **Worlds are saved** in `saves/<name>/` next to `data/`: `world.dat`
  (seed, generator, game mode, time of day), `player.dat` (position,
  look, flying, held block) and region files with every changed column.
* Saved on exit, every 5 minutes (`autosave_minutes` in world.cfg), and
  whenever an edited part of the world leaves the view, so edits are
  never lost by walking away.
* **Loaded** automatically: `--world <name>` picks a world (default
  `world`; created if missing). The player comes back where they were,
  looking the same way, with the same block in hand and the same time of
  day. `--nosave` turns saving off (tests).
* Our own **LZ compression** in asm (`src/core/lz.asm`), with a round-trip
  self test; an edited column takes ~25 KB.
* **Versioned formats** (`format_version`, region and record versions),
  documented in DATA_FORMAT.md.

### Verified
* Self test: 192 KB of mixed data compresses to 33.6 KB and expands
  identically; a corrupt stream is refused.
* Dig a hole and put a stone into it, quit: the world saves (1 column,
  25 KB, 3 ms); start again with the same world: the hole and the stone are
  there, the player stands where they stood, looking the same way, and
  the clock continues.
* With a small render distance and `--flytest`: blocks broken at the start
  are saved when their column leaves the view ("a changed column left the
  view"); starting the world again and going there loads it ("loaded 1").
* Debug and release headless tests pass (they now also save on exit).

### Performance
* Saving a column: 1–3 ms on the main thread (only edited columns);
  loading one: a few ms extra in the generation job. Unedited columns cost
  nothing.

### Known issues
* Space of records that grew is not reused (region files can grow a
  little with repeated saves).
* Liquid updates still pending when the game closes are not saved.

---

## Milestone 16, part 3 — done (2026-10-12): flowing water and lava (D87)

### What was built
* **Flowing liquids** in the simulation: water spreads up to 7 blocks
  from a source, a level lower per block, falls straight down where it
  can and spreads again where it lands; it dries up when its source is
  gone. Lava does the same, slower and only 3 blocks. Plants are washed
  away.
* Everything is event driven: dig next to a lake and the water runs into
  the hole; generated oceans and lakes don't move until something next
  to them changes.
* **Rendering:** flowing water is drawn lower the farther it is from its
  source, with the water shader (refraction, reflections); steps between
  levels have their own small walls, and the source's faces into its own
  flowing water are hidden.
* **Data:** new blocks `flowing_water` and `flowing_lava` (`shape = fluid`,
  `source`, `flow_range`, `flow_delay`).
* `--held <block>` start option (e.g. `--held water`) for placing liquids.
* Debug overlay: a `fluid` line (cell updates, changes, waiting).

### Verified
* A water source placed on the beach (`--pos 0.5 102.6 4.5 --look 0 -35
  --held water`, right click): the water spreads over the sand in steps
  and runs down the beach's terraces (293 blocks changed); replacing the
  source with sand dries it all up again (992 changes in total).
* Lava placed at night (`--time 20 --held lava`): a diamond 3 blocks
  wide, stepped down, lighting the beach red.
* Debug build with asserts: no warnings; debug and release headless
  tests pass.

### Performance
* While water spreads, a tick takes 6 µs on average (max ~30 µs);
  ~2000 cell updates for 292 changes. Each change remeshes its column
  (and neighbours in light range) on the workers; changes in the same
  column are merged into one remesh.

### Deferred
* Currents pushing the player; flowing toward the nearest drop; infinite
  water sources; lava + water making stone or obsidian.

---

## Milestone 16, part 2 — done (2026-10-12): breaking and placing blocks

Windows CI green: run #78.

### What was built (D86)
* **Targeting:** the block under the crosshair (within 5 blocks) gets a
  thin dark outline; a crosshair and the held block's name are drawn on
  screen (`src/ui/hud.asm`).
* **Creative editing:** left click breaks instantly, right click places
  the held block against the face you look at, middle click picks the
  targeted block as the held block (starts as stone). Holding a button
  repeats it 4 times a second.
  * Doors and tall plants break as a whole; a flower or grass on a block
    breaks with it.
  * You can't place a solid block inside yourself; liquids and plants can
    be built into.
* **Through the simulation:** the client only sends requests; the
  simulation checks and applies them (when no worker reads that column)
  and announces each change.
* **Instant remeshing and relighting:** the changed column, and the
  neighbours within light range, are meshed and lit again on the workers
  while the old mesh stays on screen (no flicker), then swapped in.
* New controls: `break_block`, `place_block`, `pick_block`; `reach` in
  player.cfg.
* Debug overlay: a `target` line (block, position, held block, edits,
  rejected requests, remeshed columns).

### Verified (scripted mouse clicks with xdotool)
* Looking down at the sand: two clicks dig a two-deep hole (2 edits, the
  column and its neighbours remeshed, the hole's sides are shaded by the
  new light), a right click puts stone into it, a middle click picks it.
* Holding the break button with the target out of reach does nothing (no
  request).
* Debug build with asserts: 25 s of held clicks, no warnings or asserts.
* Debug and release headless tests pass.

### Performance
* A remesh is one normal column mesh job (light ~16 ms + meshing ~20 ms on
  the test machine, on a worker); the change shows within one or two
  frames after the job. Ticks stay at a few microseconds.

### Known issues
* Edits are lost when their column unloads (more than render distance + 4
  chunks away); saving comes with milestone 17.
* Placed stairs, doors etc. keep the state they were picked with (no
  facing from the player's view yet).
* The outline is always the whole cell, also for slabs and plants.

### Deferred
* Survival breaking (time, tools, drops): milestones 18 and 20.

---

## Milestone 16, part 1 — done (2026-10-12): simulation, packets, player physics

Windows CI green: run #76.

### What was built (D85)
* **Simulation / client split.** The simulation (`src/sim/`) runs at a
  fixed 20 ticks per second and owns the player's body and the clock; the
  client (`src/client/`) sends inputs and draws what the simulation sends
  back. They talk only through two packet queues (`src/core/packet.asm`).
* **Smooth view:** the camera is placed at the player's eyes between the
  last two ticks, so movement is smooth at any frame rate.
* **Player physics with collision** against every block, including shaped
  blocks (slabs, stairs, fences 1.5 high, doors, trapdoors, panes, walls,
  ladders):
  * walking, sprinting (forward), sneaking (never walks off an edge),
    jumping, gravity;
  * automatic step-up onto slabs and stairs;
  * swimming in water (slower in lava), climbing out onto banks;
  * climbing ladders and vines (jump or walk into them; sneak holds on);
  * **Creative flight:** press Space twice quickly to start or stop
    flying; Space / Shift go up and down; Ctrl flies 5× faster; landing
    ends the flight.
* **Data:** `data/entities/player.cfg` (all sizes and speeds),
  `gravity` in world.cfg; block settings `collision`, `climbable`,
  `liquid` (water and lava are marked as liquids, cocoa pods are not
  climbable). The fly speeds moved from controls.cfg to player.cfg.
* **Debug overlay:** `player` line (mode, on ground / in water / climbing /
  sneaking / sprinting, speed) and `sim` line (tick, TPS, tick time,
  packets).
* **Fix:** the shadow framebuffer was used before it had an attachment (a
  GL warning on every start since M14 part 2).

### Verified (scripted keys with xdotool, Wine + llvmpipe)
* Default spawn: the player falls and stands on the sand, eyes at 1.62.
* Holding W: walks 14 blocks north, drops down a one-block step, stops
  at a one-block wall. W + Space: jumps up the wall and walks on through
  tall grass (no collision with plants).
* Block gallery (`--flat`): walking north over an oak slab steps up to
  y 100.5 without jumping and back down after it.
* Lake: Shift flies down into the water and lands on the bottom (flight
  ends), Space swims up to the surface.
* `--flytest`: noclip flight at 60 blocks/s, 20.2 TPS, streaming keeps up.
* Debug and release headless tests pass, no GL warnings left.

### Performance
* A tick takes 2–13 µs on average (max ~30 µs): gathering ~50–600
  collision boxes and clipping against them. Negligible next to a frame.
* On the software renderer (~2 s per frame) the simulation is capped at
  10 ticks per frame, so it runs at ~4.5 TPS there (slow motion); on a
  real GPU it runs at the full 20 TPS.

### Known issues
* Stairs collide as slab + back half (inner and outer corners are not
  modelled).
* At a water surface with Space held the player bobs with the feet at the
  surface.

### Deferred
* Fall damage and health (milestone 20).
* Crawling under 1.5-high gaps (the body stays 1.8 high while sneaking).
* A simulation thread (the queues already allow it).

---

## Milestone 15, part 1 — done (2026-10-12): water rendering

### What was built (D84)
* **Refraction:** the riverbed and lake floor show through the water,
  bent by the moving waves.
* **Depth colour:** shallow water is clear and turquoise; deep water
  turns deep blue (red light is absorbed first), tinted by the biome's
  water colour and lit by the sun, sky and block light.
* **Reflections:** screen-space reflections of hills, trees and the shore
  on calm water, falling back to the sky colour (Fresnel: stronger at
  grazing angles), plus a sun/moon glint. Pools in caves don't reflect
  the bright sky.
* **Waves:** 4 moving swells and ripples shade the surface (per pixel).
* **Shore foam:** a pulsing blocky foam where the water is very shallow.
* **Underwater:** the surface is visible from below, and a dense
  blue-green fog (darker at night) covers everything while the camera is
  in water.
* **Setting** `water_quality` (graphics.cfg): 0 simple, 1 refraction +
  colour + foam, 2 also reflections (default).

### Verified
* Debug and release headless tests pass, with no GL errors or asserts.
* Screenshots:
  * river at 10:00 (`--pos -128 110 -165 --look 0 -25 --time 10`):
    clear turquoise water, the riverbed and lily pads visible;
  * lake at sunset (`--pos -128 98 -190 --look 0 -8 --time 17.5`): the
    hill and its trees mirrored in the water, the pink sky reflected,
    the shallows see-through;
  * underwater (`--pos -128 94.5 -205 --look 0 -5 --time 10`): blue-green
    fog, seagrass, the sandy bottom fading into the distance.
* A camera inside a solid block sees black (expected; collision comes in
  M16).

### Performance (llvmpipe software GL, 1280×720, view loaded, lake view)
| | Frame time |
|---|---|
| `water_quality = 0` | ~1890 ms |
| `water_quality = 2` (default) | ~2140 ms |

The full-screen copy and the per-pixel reflection march cost ~13% on the
software renderer; on a GPU they cost well under a millisecond.

### Deferred
* **Flowing water simulation** (M15 part 2): with the block edits of M16.
* Caustics on the bottom; biome-tinted underwater fog; rain ripples
  (weather, M25).
* Reflections of things off screen (only the sky is used there).

---

## Milestone 14, part 2 — done (2026-10-12): cascaded shadows and clouds

### What was built (D83)
* **Cascaded shadow maps** from the sun (and the moon at night), 3
  cascades out to 160 blocks.
  * Soft edges (16-tap hardware PCF); the edges don't shimmer
    (texel-snapped, world-anchored).
  * The cascades are worked out on the GPU (`shaders/shadow_setup.comp`);
    the casters are culled per cascade by `cull.comp` and drawn with
    `chunk.vert` + `shaders/shadow.frag`.
  * Leaves and plants cast shadows through their alpha.
  * The near cascade is drawn every frame, the far two in turn.
* **Sun direction in the shading**: faces turned away from the sun or
  moon, and shadowed ground, keep only the sky's fill light. Slopes now
  read clearly at any time of day.
* **Clouds**: a drifting layer at y 230–278, raymarched per pixel with
  sun-lit tops and grey undersides.
  * Coloured by the time of day: white at noon, orange at sunset, dim at
    night.
  * Correctly in front of or behind terrain.
* **Settings**: `shadows`, `shadow_resolution` (512–4096),
  `shadow_distance` (32–512), `clouds` (graphics.cfg); `cloud_cover`,
  `cloud_height` (world.cfg).
* **Streaming**: the GPU upload budget now grows on slow frames, like
  the job cap. The view completes in ~20 s on the test machine (was ~29 s).
* **Debug overlay**: the `sky` line also shows the shadow casters.

### Verified
* Debug and release headless tests pass, with no GL errors or asserts.
* Screenshots:
  * clouds over the valley at 10:00 (`--pos 0 180 0 --look 0 10 --time
    10`): soft layered clouds behind the mountain;
  * shadows at 15:30 (`--pos -10 135 30 --look 30 -35 --time 15.5`):
    soft tree shadows on the sand, shadowed terrain steps, shaded slopes
    facing away from the sun.
* Bugs found and fixed on the way:
  * an unaligned SSE constant crashed the first frame;
  * the shadow map sampler shared a texture unit with the Hi-Z pyramid;
  * GL arguments read `rcx` after the macro had overwritten it.

### Performance (llvmpipe software GL, 1280×720, view loaded)
| | Frame time |
|---|---|
| M14 part 1 | ~950 ms |
| + clouds, shadows off | ~940 ms |
| + shadows, clouds off | ~1600 ms |
| + both (default) | ~2200 ms |

A software renderer is slow at shadow-map filling and per-pixel cloud
marching; on a GPU both cost a few milliseconds. Both can be switched off
in graphics.cfg.

### Deferred
* Quality presets that set these together (M33).
* Clouds casting shadows on the ground; LOD terrain casting shadows.
* Biome-tinted fog, auto-exposure.
* Translucent (coloured glass, water) shadows.

---

## Milestone 14, part 1 — done (2026-10-12)

### What was built (D82)
* **HDR rendering**: the world renders into a 16-bit float target, and a
  post pass (`post.asm`, `shaders/post.frag`) tonemaps it (ACES) with a
  saturation/vibrance grade.
  * **Bloom** (`shaders/bloom.comp`): glowing blocks, lava and the sun
    bleed soft light.
* **Sky** (`sky.asm`, `shaders/sky.frag`):
  * a blue gradient by day; orange and pink glows at sunrise and sunset;
  * the sun with halos; the moon opposite it;
  * twinkling stars at night.
* **Day/night cycle** (`src/world/daycycle.asm`):
  * `day_length` (20 min) and `start_time` (8:00) in world.cfg;
  * `--time <hour>` to start at any hour; hold **T** to fast-forward;
  * surfaces are lit by warm low sun, white noon light or blue
    moonlight.
* **Fog**: distance fog and height fog (mist in low ground), coloured by
  the sky in the view direction (golden at sunset, dark blue at night).
  Caves get dark fog.
* **Settings**: `bloom`, `height_fog`.
* **Debug overlay** line `sky`: time of day and day length.

### Verified
* Debug and release headless tests pass, with no GL errors or asserts.
* Screenshots from `--pos 0 180 0`:
  * noon (`--time 12`): vivid terrain, soft haze on distant ranges;
  * sunset, looking west (`--time 17.6 --look 270 2`): pink-orange sky,
    golden haze, silhouetted trees;
  * night (`--time 23 --look 90 10`): starry sky, moonlit snow, glowing
    crystals.

### Performance (llvmpipe software GL, 1280×720, render distance 16 + LOD 64)
| | M13 | M14.1 |
|---|---|---|
| Frame time at spawn (loaded) | ~750 ms | ~950 ms |

The extra cost is the full-screen sky, fog and post passes; a software
renderer is slow at those. On a GPU they cost well under a millisecond.

### For the owner
* Day length is 20 minutes (like Minecraft) and the game starts at 8:00.
  Both are in `data/world/world.cfg`. Say if you want a different
  default.

### Deferred
* Cascaded shadows and clouds: part 2.
* Biome-tinted fog, underwater fog (M15), weather (M25), auto-exposure.
* A shader include mechanism so `sky_color()` is not duplicated.

---

## Milestone 13 — done (2026-10-12)

### What was built (D81)
* **Light engine** (`src/world/light.asm`, `src/include/light.inc`):
  every column's mesh job builds a light volume (the column plus a
  16-block margin from all 8 neighbours).
  * Skylight: straight down from the sky, then a flood fill under
    overhangs, into caves and under trees.
  * RGB block light: a flood fill from every emitting block, three
    channels at once (SIMD byte maths).
  * New block setting `light_filter`: water and leaves dim light by 1 per
    block.
* **Smooth lighting and AO**: the mesher gives every face 4 corner lights
  (the mean of the open cells around each corner) and ambient occlusion,
  and only merges faces whose light matches.
  * The light words go into a parallel GPU buffer.
  * The fragment shader mixes the corners bilinearly.
  * Emitting blocks light their own faces.
* **Held light** (L, `toggle_held_light`): a warm light around the camera
  (`held_light = 14, 11, 6` in graphics.cfg), a stand-in until held items
  exist (M18).
* **Settings**: `smooth_lighting`, `ambient_occlusion`, `held_light`.
  Start options: `--held-light`, and `--daylight <percent>` to preview
  night lighting before the day/night cycle (M14).
* **Light values for the M10 content that was waiting for M13**:
  * crystal sprouts and glow pools in their grotto's colour;
  * glow moss, glowcaps;
  * the glowing forest's bellflowers, star blooms and glow ferns.
  * Crystals, lava, lamps, glowstone and the fantasy woods already had
    their values in the block files.
* **Streaming**: meshing now waits for all 8 neighbours; columns are
  generated 2 rings beyond the render distance.
* **GPU buffers**: the quad buffer is now 256 MB, plus a 256 MB light
  buffer. Light-aware merging roughly doubles the quads.
* **Debug overlay** line `light`: light-volume time per column and the
  held-light state. The stream log also counts light sources.

### Verified
* Debug and release headless tests pass, with no GL errors or asserts.
  The test now waits 40 s, because streaming does more work per column.
* Screenshots:
  * terrain steps get soft AO, and overhangs and the forest floor are
    shaded;
  * the flat gallery at `--daylight 5`: lava lights its neighbours
    orange;
  * the glowing forest at night (`--pos -64 125 40 --look 180 -20
    --daylight 8`): crystal clusters light the ground blue, and the
    glowing trees and plants shine;
  * crystal grotto (`--pos 64 -70 0 --look 0 25`): dark veined rock lit
    by the crystals.
* All 797 columns of the view load (they waited for missing diagonal
  neighbours until the generation ring was widened).

### Performance (llvmpipe software GL under Wine, 3 workers, render distance 16)
| | M12 | M13 |
|---|---|---|
| Quads in the GPU buffer | 5.9 M | 11.8 M |
| Quads drawn at spawn | 525 k | 709 k |
| Frame time at spawn | ~560 ms | ~750 ms |
| Light volume per column | — | avg 16.7 ms, max 47 ms |
| Mesh job per column (incl. light) | ~20–34 ms | ~40 ms |
| View complete (797 columns) | ~13 s | ~24 s (2 more rings generated) |

### For the owner
* The glacier design said "light from the blue ice in caves comes with
  M13". Should blue glacier ice give off a faint blue glow in ice caves,
  or did that mean light shining through the ice? It is unchanged for
  now (ice is opaque to light).
* The light colours chosen for the grotto sprouts and pools, glow moss,
  glowcaps and glowing-forest plants are listed in the block files. Say
  if any should be brighter or dimmer.

### Deferred
* Faster light volumes: SIMD flood fill; reuse neighbour data instead of
  decoding 9 columns per job (M33 performance pass).
* Fewer quads with lighting: merge faces whose light differs only
  slightly, or move to compute-shader meshing (M33).
* Light updates for block edits (M16 re-meshes the affected columns).
* The held light casts no shadows and passes through walls.
* LOD tiles are always lit as open sky (night darkens them through the
  daylight uniform in M14).

---

## Milestone 12 — done (2026-10-12)

### What was built (D80)
* **LOD tiles** (`src/world/lod.asm`, `src/include/lod.inc`): beyond the
  full-detail columns the terrain is drawn as tiles of 32 × 32 cells of
  2, 4, 8, 16 or 32 blocks (levels 1–5).
  * Heights are the real terrain function with the biomes' hill, dune,
    plateau, mesa and flatten settings blended in.
  * Top blocks follow the surface rules: sea floor + water, snow, steep
    rock, beach, glacier ice/snow, a leaf canopy over forests, else the
    biome's ground.
  * Side faces go down to lower neighbours: the top block, then filler,
    then rock.
  * Meshing is greedy for tops and water.
* **Rings**: level L covers r[L−1]..r[L] around the camera, where
  r0 = (render_distance − 2) chunks and each ring is double the previous,
  up to `lod_distance`.
  * Default (16 + 64 chunks): 3 levels, about 1200 tiles, 1.4 M quads
    (11 MB of the quad buffer).
  * `lod_distance = 256` uses all 5 levels.
* **Streaming** (`lod_update`, main thread, never waits):
  * worker jobs, up to 8 per worker in flight, submitted only while the
    job queue is short, so full-detail columns always come first;
  * at most 1 MB of uploads per frame;
  * a hash map of tiles; tiles no ring needs are freed.
* **Rendering**: tiles add records to the M11 GPU-driven pipeline (land
  with the opaque pass, water with the translucent pass).
  * `cull.comp` handles tile boxes.
  * The vertex shader decodes LOD quads. The level comes from a third
    instanced attribute.
  * A second tint map holds the tiles' biome colours.
* **Seams and smooth transitions**: every level, including the full
  detail, is clipped to its ring in the fragment shader. Neighbouring
  levels cross-fade over a band of 8% of the radius with a complementary
  screen-door dither, so there are no cracks and no hard edge.
* **Fog** scales with the LOD radius: the far edge fades into the sky.
* **Setting** `lod_distance` (graphics.cfg, 0–256 chunks, default 64;
  0 = off).
* **Debug overlay** line `lod`: levels, distance, ready tiles + jobs in
  flight, quads, drawn records, generation average/max µs. The log shows
  the same every 2 s, plus `lod: all rings complete after ms`.

### Verified
* Debug and release headless tests pass. Debug runs with GL debug output
  on: no GL errors or asserts.
* Screenshots from spawn at y 180 and y 300 (seed 20261009) show
  distant mountains, lakes, snowfields and forests to the 2048-block
  horizon. They fade into the sky, with no visible seams at the ring
  boundaries.
* `--flytest` for 60 s (debug): tiles are freed and replaced as the
  camera moves; clean exit.
* `lod_distance = 256`: 5 levels, 1259+ tiles, 1.6 M quads within
  100 s; clean exit.

### Performance (llvmpipe software GL under Wine, 1280×720, render distance 16)
| | LOD off | LOD 64 chunks |
|---|---|---|
| Spawn frame time (all loaded) | ~420 ms (2.3 FPS) | ~520 ms (1.9 FPS) |
| Tiles / quads | — | 1204 / 1.42 M |
| Tile generation (worker) | — | avg 3.8 ms, max ~11 ms |
| All rings complete | — | 53 s at ~2 FPS* |

\* The job cap is per frame, so at 60 FPS a 3-worker machine finishes the
rings in about 2 s (1204 tiles × 3.8 ms / 3 workers). On llvmpipe the
frame rate is the limit. Full-detail streaming is unchanged: view
complete in ~12–14 s, the same as before, because LOD jobs wait for a
short queue.

### Fix after the owner's test (Intel UHD 630, Windows)
* Nothing but sky rendered on the owner's Intel GPU (records drawn,
  Hi-Z culled 0: every fragment was discarded by the ring clipping). The
  ring radii came from an explicit-location uniform float array, and the
  level from an integer vertex attribute; both are now on the simplest
  paths:
  * two `vec4` uniforms read with constant branches;
  * the level from a float attribute, the same path as the origins.
  * A radius of 0 now clips nothing, so a missing uniform can no longer
    blank the screen.
* Still to confirm on the owner's PC. Workaround meanwhile:
  `lod_distance = 0`.

### Deferred
* LOD tiles ignore player edits (none exist yet; M16 adds breaking and
  placing, then edited columns will rebuild their tiles).
* Frozen seas and river variants are drawn as plain water in LOD tiles;
  trees are a flat canopy.
* The LOD tint map repeats every 16384 blocks. At `lod_distance = 256`
  (radius 8192) the two farthest edges share texels.
* Tile generation is scalar; SIMD noise is a later performance pass
  (M33).

---

## Milestone 11 — done (2026-10-11)

### What was built (D79)
* **Offscreen scene target** (renderer.asm): colour + 32-bit float depth
  texture, blitted to the window. The overlay draws on top.
* **Persistent draw-record ring**: 3 fenced frame slots of 32768 records
  (3 MB), coherently mapped. The CPU visibility walk writes records
  instead of drawing.
* **Compute culling** (`shaders/cull.comp`): an exact AABB frustum test
  and a Hi-Z occlusion test against the previous frame's depth pyramid
  (reprojected). It writes the indirect commands.
* **Multi-draw indirect**: one `glMultiDrawArraysIndirect` per pass
  (opaque, cutout, translucent; the translucent order is kept). The
  vertex shader gets each draw's origins from the record ring, bound as
  an instanced vertex buffer (base instance = record).
* **Hi-Z pyramid** (`shaders/hiz.comp`): an R32F mip chain of the
  farthest depth, built after the draws.
* **Compute shader support** in shader.asm (`shader_create_compute`, with
  hot reload).
* **Settings**: `gpu_culling`, `occlusion_culling` (graphics.cfg).
* **Debug overlay**: walk sections, GPU-drawn records, Hi-Z culled,
  quads, multi-draws.

### Verified
* Debug and release headless tests pass. The debug build ran with GL
  debug output on: no GL errors, no asserts, clean exit.
* Screenshots with GPU culling on and off are the same, apart from
  animated plants and water.
* At spawn the overlay shows 460 walk sections, 775 GPU-drawn records,
  93 Hi-Z culled, 3 multi-draws per frame.

### Performance (llvmpipe software GL under Wine, 1280×720, 16 chunks)
| View | Before (one draw per range) | GPU cull + Hi-Z | GPU cull, no Hi-Z | CPU commands (gpu_culling 0) |
|---|---|---|---|---|
| Spawn | ~310 ms (3.1 FPS) | ~250 ms (4.0 FPS) | — | ~310 ms |
| Glacier flank (mountains) | — | ~477 ms | ~530–640 ms | ~550–610 ms |

On a real GPU the absolute numbers will be far better. These show the
relative gain: about 20% fewer frame milliseconds from culling on the
software rasterizer.

### Known issues
* Single-phase Hi-Z: a section revealed from behind an occluder can
  appear one frame late.
* The quad uploads still use `glNamedBufferSubData`; a persistent staging
  ring is possible later.

---

## Milestone 10, part 21 — done (2026-10-11)

### Design interview
Two rounds plus approval: `design/biomes/river.md`.
* Four variants by the land around them:
  * temperate: clear blue-green water, lush banks, willows, lily pads,
    river weed, stepping stones;
  * frozen: iced over with open channels;
  * muddy: jungle and swamp;
  * oasis: a green strip in dry lands.
* Fish later.

### What was built
* **Per-column river classes and river biomes** (D78):
  * the coarse grid keeps the river value;
  * every column is water, bank or neither;
  * river columns take the land biome's `river_biome` for ground, plants,
    trees, water features and the water tint.
* **Waterlogged blocks**: a block setting `waterlogged`. The mesher draws
  the cell as water around the plant.
* **Water features**: the iceberg layer generalised (`water_feature*`,
  with a minimum depth; rocks stand on the bed).
* **Bed plants** (`bed_plant`) under water. New biome settings
  `river_biome`, `own_colors`, `trees_in_water`.
* **Data**:
  * `data/biomes/24_rivers.biome`: river, frozen_river, muddy_river,
    oasis_river;
  * trees `willow` and `river_stone`;
  * blocks `river_weed` (2 tall) and `river_grass` (texgen);
  * `river_biome` on the cold, jungle/swamp and dry-land biomes.
* **Survey**: the nearest river of each variant.
* MAX_TREES 64 → 96.

### How to see it (seed 20261009)
* Temperate river: `voxelb.exe --pos -128 118 -165 --look 0 -30`.
* Oasis river: `voxelb.exe --pos -576 135 175 --look 0 -30`.
* Frozen river: `voxelb.exe --pos -1408 140 -330 --look 0 -35`.

### Verified
* Debug and release headless tests pass. The debug build ran over the
  river with no asserts and a clean exit.
* Screenshots: temperate (lily pads, weed under water with no air
  pockets), oasis (green strip, palms on the banks after the fix), frozen
  (floes and channels, snowy gravel banks).

### Known issues
* The muddy river was not caught in a screenshot (the survey's spot showed
  a temperate river). It uses the same mechanism.
* Where a river meets a lake or the sea, its water colour changes at a
  4-block cell edge.

### Performance
Unchanged: at the temperate river the 16-chunk view is ready after
12.5 s (11.9 s without the river biomes; this spot is heavier than
earlier ones). Meshing ~12.7 ms per column on average.

---

## Milestone 10, part 20 — done (2026-10-11)

### Design interview
Two rounds plus approval: `design/biomes/crystal_caves.md`.
* Glittering grottos in large deep caverns, one colour per grotto, with
  rare rainbow mixes.
* Dark veined rock; crystal sprouts on floors and ceilings; clumps; giant
  pillars.
* Glowing moss and fungi, glowing pools, more crystal ore.

### What was built
* **Cave-biome system** (D77): `[cave_biome]` records with a depth range,
  a 3D region noise and a theme noise. A decoration pass after the cave
  decoration (new module `src/world/cavebiome.asm`):
  * veined stone and ore;
  * floor-to-ceiling crystal pillars;
  * pools, moss, sprouts (up and down), glowcaps, clumps, stalactites.
* **Crystal caves** (`data/biomes/70_crystal_caves.biome`): 5 colour
  themes, deep (−220 to 0), 6.4% of the deep volume.
* **New blocks** (texgen), per colour: `<c>_veined_stone` (glowing
  cracks), `<c>_crystal_sprout` (spike shape, the crystal's texture),
  `<c>_glow_pool` (translucent, animated, glowing).
* **Survey**: logs the region share and the nearest grotto.

### How to see it (seed 20261009)
* A grotto right under spawn, from the cave below it:
  `voxelb.exe --pos 64 -70 0 --look 0 25`.

### Verified
* Debug and release headless tests pass. Debug and release ran in the
  grotto with no asserts and clean exits.
* Screenshots: veined walls, sprouts, clumps and moss in the grotto.
  The vein texture and theme scale were reworked after the first look.

### Known issues
* Pillars and pools were not clearly caught in a screenshot. They are
  built and in the data, but caves are hard to frame from fixed camera
  positions.
* A pillar can plug a tunnel that passes through it.
* Pools are blocks, not fluids, until M15.

### Performance
The 16-chunk view at the grotto is ready after 7.3 s (7.1 s without
crystal caves: ~3%). Meshing ~10.3 ms per column on average.

---

## Milestone 10, part 19 — done (2026-10-11)

### Design interview
Two rounds plus approval: `design/biomes/glacier.md`.
* Ice caps on the high cold mountains, with tongues down the valleys.
* Snow fields up high; bare packed and blue ice lower down.
* Crevasse fields, blue cliffs, seracs, a few ice caves.
* Gravel moraines with boulders, and milky turquoise meltwater lakes.

### What was built
* **Glacier** (`data/biomes/54_glacier.biome`): 3.1% of land near the
  origin.
* **Smoothed-height biomes** (D76): a new biome setting `smooth_height`,
  so glaciers reach down valleys. The blend map keeps smoothed heights
  (`bmap_hs`).
* **Ice layer** (new module `src/world/glacier.asm`):
  * `glacier_pass` raises the heightmap to the ice surface: a cap on
    ridges, valleys filled to a broad surface;
  * the ice ends in a sheer wall, with a moraine ridge beyond;
  * seracs on steep ice; crevasse depths per column;
  * `glacier_block` picks snow, packed ice and blue ice, and cuts
    crevasses and ice caves.
  * New biome settings: `ice_block`, `ice_deep`, `ice_snow`, `ice_cap`,
    `ice_fill`, `ice_edge`, `moraine_block`, `moraine_height`,
    `crevasse`, `ice_caves`, `serac`.
* Nothing grows on the ice (trees and plants skip it). Boulders sit on
  the moraines.
* INFO grew to 40 bytes.

### How to see it (seed 20261009)
* Over the glacier: `voxelb.exe --pos 256 330 -330 --look 0 -35`.
* Its flank with seracs and crevasses:
  `voxelb.exe --pos 256 215 -385 --look 340 -12`.

### Verified
* Debug and release headless tests pass. Debug and release ran over the
  glacier with no asserts and clean exits.
* Screenshots: the ice cap from above (snow cap, bare ice, crevasse lines,
  moraine ring) and its flank (seracs).
* A release-only crash (an unaligned `andps` operand) was found and fixed.

### Known issues
* The glacier near spawn sits on a single mountain, so its tongues are
  short. Long valley tongues need a big range.
* Ice caves and meltwater lakes were not seen in screenshots. Both are in
  the code and data, but they are uncommon.

### Performance
Unchanged: the 16-chunk view over the glacier is ready after ~10.5 s on 3
workers, with or without the glacier biome (mountain terrain is heavier).
Meshing 9.3 ms per column; 7.2 FPS average under Wine with llvmpipe.

---

## Milestone 10, part 18 — done (2026-10-11)

### Design interview
Two rounds plus approval: `design/biomes/frozen_ocean.md`. Frozen ocean
was picked first; glaciers get their own interview.
* All cold seas freeze into broken pack ice, with snowy and bare floes,
  channels of deep teal-blue water and pressure ridges. The ice opens up
  toward warmer seas.
* Icebergs: many small, some tall jagged, rare giant tabular ones.
* Snowy gravel shores with shore-fast ice; a gravel, clay and stone sea
  floor.

### What was built
* **Frozen ocean** (`data/biomes/62_frozen_ocean.biome`): ocean heights
  in the cold climates. 21% of the sea near the origin is frozen.
* **Sea ice** (D75): a new pass, `flora_sea_ice`, with a new INFO byte.
  * Voronoi floes with frayed edges and varied channels.
  * Snowy or bare floes; ridge lines along shared floe edges.
  * The ice fades with temperature; shallow water is always frozen.
  * Settings: `sea_ice`, `sea_ice_floe`, `sea_ice_cover`, `sea_ice_snow`,
    `sea_ice_ridge`, `sea_ice_shore_depth`.
* **Icebergs**: a new tree kind `iceberg`, with tree setting `top_block`.
  * A new candidate layer on deep water, with the biome settings
    `iceberg` and `iceberg_density`.
  * Sections under the sea are built block by block where icebergs reach
    into them (`FCTX.bot`).
  * Trees (data): `small_iceberg`, `tall_iceberg`, `giant_iceberg`.
* **Shores and sea floor**: new biome settings `beach_patch`,
  `seabed_block` and `seabed_patch`. Snowy tundra, snowy taiga and ice
  spikes now have snowy gravel shores too.
* **Survey**: logs the frozen share of the sea and the nearest open
  frozen sea.

### How to see it (seed 20261009)
* Over the pack ice and icebergs:
  `voxelb.exe --pos 300 150 60 --look 330 -25`.
* At sea level among the floes:
  `voxelb.exe --pos 330 110 120 --look 320 -5`.
* The snowy gravel shore and shore-fast ice:
  `voxelb.exe --pos 192 200 60 --look 0 -40`.

### Verified
* Debug and release headless tests pass. The debug build ran over the
  frozen sea with no asserts.
* Screenshots: from above, at sea level among the floes, and the shore.
  The floes and ridges were reworked after the first look.

### Known issues
* The pack ice is one block thick.
* Ridges still show small breaks and run along both sides of a channel.

### Performance
Unchanged: meshing 9.7 ms per column on average. The full 16-chunk view
(797 columns) is ready after 8.0 s on 3 workers over the frozen sea. 7.0
FPS average under Wine with llvmpipe.

---

## Milestone 10, part 17 — done (2026-10-10)

### Design interview
Three rounds plus approval: `design/biomes/meadow.md`.
* Highland meadows on the temperate foothills.
* Mint grass with pastel flower drifts: lavender, lupins and buttercups
  lower down; alpine flowers higher up.
* Lone spruces, birch clumps, mossy boulders, clear ponds.
* Beehives and streams are deferred.

### What was built
* **Meadow** and **alpine meadow** (`data/biomes/22_meadow.biome`):
  * temperate climates at heights 140–180 and 181–230, priority 2;
  * 6.0% of land near the origin.
* **Groves** (D74): new biome settings `grove_chance`, `grove_radius`,
  `grove_density` and `grove_tree` for tree clumps. `in_clearing` and
  the new `in_grove` share one routine, `in_disc`.
* **New blocks** (texgen):
  * `lavender`, `blue_lupin`, `pink_lupin`, `white_lupin` (2 tall);
  * `clover`, `buttercup`, `edelweiss`, `gentian`, `alpine_aster`.
* **Trees** (data): `meadow_spruce`, `meadow_stone`, `big_mossy_boulder`.
* Sky islands and the glowing forest moved to priority 3, to keep their
  pockets.

### How to see it (seed 20261009)
* Flower drifts, spruces and boulders:
  `voxelb.exe --pos -300 172 -180 --look 300 -25`.
* Over the meadow: `voxelb.exe --pos -250 180 -192 --look 270 -35`.
* From above: `voxelb.exe --pos -300 330 -200 --look 0 -89`.

### Verified
* Debug and release headless tests pass. The debug build ran in the
  meadow with no asserts.
* Screenshots: the drifts close up, over the meadow and from above. Birch
  groves were checked with a forced grove chance, then set back.

### Known issues
* The alpine band lies mostly on steep slopes (bare stone), so its
  flowers are on the ledges. A gentler foothill terrain shape would need
  terrain changes and was not part of this design.

### Performance
Unchanged: meshing 10.1 ms per column on average. The full 16-chunk view
(797 columns) is ready after 9.5 s on 3 workers. 6.3 FPS average under
Wine with llvmpipe.

---

## Milestone 10, part 16 — done (2026-10-11)

### Design interview
Two rounds plus approval: `design/biomes/ice_spikes.md`.
* Rare tundra pockets with a mixed forest of ice spires.
* Packed ice with blue-ice cores and tips.
* Snow with packed-ice patches and frozen ponds.

### What was built
* **Ice spikes** (`data/biomes/53_ice_spikes.biome`), ~1.1% of land near
  the origin (tundra climate, rarity 0.72–1.00).
* **New kind** `spike` (D73): a tapering spire with a core block.
* **Trees** (data): small (4–10), tall (15–30) and giant (35–50) ice
  spikes.
* **New block** `blue_ice` (texgen).

### How to see it (seed 20261009)
* Among the spires: `voxelb.exe --pos -400 120 -600 --look 0 12`.
* Over the pocket: `voxelb.exe --pos -384 170 -560 --look 0 -12`.

### Verified
* Debug and release headless tests pass. The debug build ran among the
  spikes with no asserts.
* Screenshots: the spike forest close up, over the pocket and from above.

### Known issues
* The top 30% of the tall spikes is a single-block blue needle. It reads
  well, but it is thin.

### Performance
Unchanged: generation ~13 ms per column, meshing ~10 ms.

---

## Milestone 10, part 15 — done (2026-10-11)

### Design interview
Two rounds plus approval: `design/biomes/mushroom_fields.md`.
* Rare islands in the ocean, with purple-grey mycelium and pink specks.
* Giant red domes, flat brown caps, glowing blue ones, rare colossal ones.
* Shelf fungi and puffballs; spore haze later.

### What was built
* **Mushroom fields** (`data/biomes/60_mushroom_fields.biome`): ocean-floor
  pockets of the rarity field, lifted into islands with beaches (D72).
* **New kind** `mushroom`: a stem, a dome or flat cap, gills underneath,
  shelf fungi. New tree setting `underside`.
* **Trees** (data): red, brown and glowing giants; colossal red and brown
  (15–25 tall, caps up to 10 radius).
* **New blocks** (texgen): `mycelium`, `puffball`.
* **Survey**: logs the nearest island lifted from the sea.

### How to see it (seed 20261009)
* From above: `voxelb.exe --pos 192 320 256 --look 0 -89`.
* Among the mushrooms: `voxelb.exe --pos 230 125 300 --look 220 -8`.

### Bugs found and fixed while testing
* The survey's lifted-island test also matched the swamp (it flattens
  just above the sea). It now needs a level 6+ above the sea.
* The first, rarer placement made pockets too small to survive the biome
  blend: no islands appeared. Widened to rarity 0.66 and depth ≤ 86.

### Verified
* Debug and release headless tests pass. The debug build ran on the island
  with no asserts.
* Screenshots: the island from above (beach ring, mycelium, all three
  mushroom kinds) and among the mushrooms (incl. a colossal brown one).

### Known issues
* The nearest island sits close to the coast, not far out at sea, because
  ocean near land is also deep enough.
* The `--survey` land shares do not count it: it is ocean-floor terrain
  before the lift.

### Deferred
* Spore haze (BACKLOG, particles).

### Performance
Unchanged: generation ~13 ms per column, meshing ~10 ms; 2.1 FPS over the
island on software GL.

---

## Milestone 10, part 14 — done (2026-10-11)

### Design interview
Three rounds: `design/biomes/sky_islands.md`.
* A rare lush flower-meadow region with an archipelago of floating
  islands (Y 200–320, 10–50 wide).
* Meadow tops with trees; inverted-cone stone undersides with exposed
  ores and crystals; hanging roots.
* Waterfalls later.

### What was built
* **Sky islands** (`data/biomes/21_sky_islands.biome`), ~2.8% of land
  near the origin (plains climate, rarity 0.72–1.00).
* **Floating islands** (D71), a new terrain feature from data:
  * `island_chance`, `island_radius`, `island_height`;
  * `island_ore` (ores and crystals in the stone);
  * `island_roots` (a new `hanging_roots` block).
* Islands get trees, plants and flowers on top from their biome.
* **Survey**: logs the nearest floating island.

### How to see it (seed 20261009)
* The nearest pocket, by a mountain: `voxelb.exe --pos -640 250 -390 --look 0 -4`.
* Looking up from its meadow: `voxelb.exe --pos -640 170 -480 --look 0 20`.
* That pocket is narrow, so its islands are few and small. The full
  archipelago (screenshotted with the biome over all plains for the test)
  shows in the wider regions further out.

### Verified
* Debug and release headless tests pass. The debug build ran at the sky
  islands with no asserts.
* Screenshots:
  * an island seen from below (stone underside, blue crystal, roots);
  * the archipelago at island height, with layers of islands, trees and
    roots (test placement);
  * the real pocket from above and from the side.

### Known issues
* Islands thin out towards a region's edges (their chance follows the
  vegetation density), so narrow pockets have few islands.
* No waterfalls yet (M15).

### Performance
* Island columns fill a few more sections block by block. Generation
  ~13 ms per column, meshing ~10 ms, unchanged within noise.
* 3 FPS on software GL at the pocket.

---

## Milestone 10, part 13 — done (2026-10-11)

### Design interview
Three rounds plus approval: `design/biomes/glowing_forest.md`.
* Rare magical pockets in the temperate forests, glowing cyan and teal.
* Tall weeping glowwoods; dark blue-green ground with luminous moss.
* Glowing bellflowers, star-blooms, glow ferns and glowcaps.
* Cyan pools and blue crystal clusters.
* Fireflies later.

### What was built
* **Glowing forest** (`data/biomes/34_glowing_forest.biome`), ~1.2% of
  land near the origin. One pocket sits right next to spawn.
* **A rarity field** (D70): a fourth climate value with its own noise and
  a biome `rarity` range, for rare pockets on top of the weirdness bands.
* **Weeping glowwoods**: the round kind, with curtains of glowing leaves
  hanging from the crown (`hanging_vines` = the leaves).
* **New glowing blocks** (texgen, all with glow layers):
  `glow_bellflower`, `star_bloom`, `glow_fern`, `glow_moss`.
* **Cyan pools** (`water_color`) and blue crystal clusters.

### How to see it (seed 20261009)
* From above, next to spawn: `voxelb.exe --pos -64 175 20 --look 180 -25`.
* Inside, among the glowwoods: `voxelb.exe --pos -64 128 64 --look 160 -5`.

### Bugs found and fixed while testing
* A weirdness band for the glowing forest replaced the plain forest and
  broke it up. Replaced by the rarity field.
* The first weeping curtains were solid walls of glowing leaves. Thinned
  to 4.5% of leaves, 2–6 long.

### Verified
* Debug and release headless tests pass. The debug build ran in the
  glowing forest with no asserts.
* Screenshots:
  * from above;
  * inside (the floor with glow ferns, flowers, glowcaps and moss);
  * crystals.

### Known issues
* By day the glow is texture brightness only. The forest lights up the
  night once lighting arrives (M13).

### Deferred
* Fireflies (BACKLOG, M14+).

### Performance
Unchanged: generation ~12–15 ms per column, meshing ~10 ms.

---

## Milestone 10, part 12 — done (2026-10-11)

### Design interview
Three rounds plus approval: `design/biomes/dark_forest.md`.
* Pockets inside wet forests: tall gnarled dark-oak giants (20–30) that
  twist and lean, with crooked sprawling branches and dense dark crowns.
* Smaller dark oaks and bushes between; a very dim, closed canopy.
* Leaf litter, ferns, small mushrooms, moss, roots and fallen logs; rare
  glowing mushrooms.

### What was built
* **Dark forest** (`data/biomes/33_dark_forest.biome`), ~3.1% of land
  near the origin (forest weirdness 0.21–0.40).
* **New kind** `gnarled` (D69): a drifting trunk, knotted roots and
  crooked branches.
* **Trees** (data): `gnarled_dark_oak`, `small_dark_oak`,
  `dark_oak_bush`, `fallen_dark_oak`. Dark-oak leaves are now
  foliage-tinted (very dark emerald here).
* **`glowcap`**: a new glowing mushroom plant (texgen, with a glow layer).
  It grows in small clusters and in the litter near trunks.

### How to see it (seed 20261009)
* A dark forest pocket from above: `voxelb.exe --pos 512 160 1080 --look 200 -25`.
* The pocket sits beside a birch grove, a jungle and a swamp, which shows
  how the borders fray.

### Verified
* Debug and release headless tests pass. The debug build ran over the
  dark forest with no asserts.
* Screenshots:
  * the canopy;
  * the floor among gnarled trunks (moss, litter, ferns);
  * glowcaps (raised chance for the test).
* For the tests the dark forest was temporarily given the whole forest
  climate.

### Known issues
* Under the canopy it is dim only in colour. Real darkness comes with
  lighting (M13).

### Performance
Unchanged: generation ~12–15 ms per column, meshing ~10 ms; 2.4 FPS on
software GL over the dark forest.

---

## Milestone 10, part 11 — done (2026-10-10)

### Design interview
Four rounds plus approval: `design/biomes/swamp.md`.
* A bayou in the warm, wet lowlands: tall cypresses with flared trunks,
  flat layered moss-draped crowns and knees.
* Half water, half land: shallow murky olive pools between muddy grassy
  islands.
* Lily pads (some flowering), cattails and reeds.
* A witch hut, left for the structures milestone.

### What was built
* **Swamp** (`data/biomes/48_swamp.biome`), on ~4.6% of land near the
  origin (wet lowlands only).
* **Water colour per biome** (D68): a third tint layer (`tint = water`,
  `water_color`, `water_reference`). The water keeps its brightness and
  takes the biome's hue; every other biome keeps blue water.
* **Terrain settings** (D68):
  * `flatten` (the pool-and-island maze);
  * `own_shore` (grass and mud shores, mud pool floors).
* **Water plants**: a `water_plant` list. `lily_pad` and
  `flowering_lily_pad` float on the water.
* **Cypress** (new kind `cypress`): flared trunks, layered flat crowns
  with `spanish_moss` strands, and knees. Logs can now stand in water.
* **New blocks** (texgen): `spanish_moss`, `lily_pad`,
  `flowering_lily_pad`, `cattail`, `reeds`.
* **Tint fix for leaves, plants and water in every biome** (D68). The
  cutout and translucent draw lists lost each section's world z, so those
  faces sampled the biome colour map at the wrong place. Leaves and
  plants in every biome now show their designed colours. The jungle
  canopy, for one, is now its full emerald.

### How to see it (seed 20261009)
* Among the cypresses, over murky water with lily pads:
  `voxelb.exe --pos 0 100 192 --look 200 -5`.
* The swamp canopy and pools from above:
  `voxelb.exe --pos 0 125 150 --look 180 -20`.

### Bugs found and fixed while testing
* The draw-list world-origin bug above, which made the swamp water stay
  blue.
* Strong red water factors turned the water's sparkles yellow. Fixed by
  recolouring by brightness.
* The first swamp climate took 9.4% of land (forests and jungles shrank).
  Narrowed to the wettest lowlands: 4.6%.

### Verified
* Debug and release headless tests pass. The debug build ran in the
  swamp with no asserts.
* Screenshots:
  * the swamp at water level and from above;
  * the jungle canopy and a forest after the tint fix;
  * blue sea water outside the swamp.

### Known issues
* The jungle's emerald now reads very bright, since its foliage colour
  finally applies. It can be toned down in data if wanted.

### Deferred
* The witch hut is in BACKLOG for M23.
* Fireflies and fog wait for M14.

### Performance
Unchanged: generation ~15 ms per column, meshing ~10–13 ms; 1.4 FPS on
software GL among the cypresses.

---

## Milestone 10, part 10 — done (2026-10-10)

### Design interview
Three rounds plus approval: `design/biomes/steppe.md`.
* A wide-open, gently rolling grassland filling the cool, dry temperate
  band, in cool silver-green and gold.
* Tall silvery feather grass, steppe wildflowers, sagebrush, and rare
  wind-bent birches.
* Rocky outcrops, menhirs and very rare stone circles.
* Small ponds and white salt flats in hollows.

### What was built
* **Steppe** (`data/biomes/47_steppe.biome`), on ~6.8% of land near the
  origin. The "none" land is down from ~13% to ~9.5%.
* **New blocks** (texgen):
  * `feather_grass` (2 tall, silvery plumes) and `sagebrush`;
  * flowers `blue_sage`, `yarrow`, `pasqueflower`;
  * `salt`.
* **Engine settings** (D67):
  * `dry_ponds` (salt flats from the pond feature);
  * tree `lean` (wind-bent trunks and crowns);
  * a new kind `stone_ring` (stone circles).
* **Trees** (all data): `windswept_birch`, `steppe_outcrop`, `menhir`,
  `stone_circle`.

### How to see it (seed 20261009)
* Feather grass, a salt flat, an outcrop and a wind-bent birch:
  `voxelb.exe --pos -470 112 -560 --look 200 -6`.
* The steppe meeting the tundra from above:
  `voxelb.exe --pos -448 300 -512 --look 0 -89`.
* Stone circles are very rare (~1 per 600×600 blocks).

### Verified
* Debug and release headless tests pass. The debug build ran in the
  steppe with no asserts.
* Screenshots:
  * the steppe at ground level and from above;
  * a stone circle and a menhir, with their frequency raised for the test.

### Known issues
* Short grass tufts take the sage tint but read greener than the feather
  grass.

### Performance
Unchanged: generation ~15–16 ms per column, meshing ~13 ms; 1.9 FPS on
software GL over the steppe (feather grass is two quads per plant).

---

## Milestone 10, part 9 — done (2026-10-10)

### Design interview
Three rounds plus approval: `design/biomes/badlands.md`.
* A very rare wonder: mesas and buttes 30–60 high with sheer cliffs in
  warm sunset bands that are level and slightly wavy.
* Canyons with dry washes and red sand with sparse scrub.
* Dead bushes, cacti and bleached dead trees.
* Rare striped hoodoos and arches.
* Gold ore high up, even in the cliffs.

### What was built
* **Badlands** (`data/biomes/46_badlands.biome`), on ~2% of land near the
  origin, as pockets inside deserts.
* **Terrain** (D66):
  * terraced mesas (`mesa_height`, `mesas` noise);
  * banded rock from per-biome band tables (`strata`, `strata_thickness`,
    `strata_min_y`, with a `strata` wave noise);
  * dry washes (`wash_block`) and red-sand shores (`beach_block`).
* **Striped rocks**: `log = strata` makes hoodoos, arches and boulders
  take the bands.
* **Gold**: a `badlands_gold` ore with the new ore setting `strata = 1`,
  in the cliffs from y 60 up.
* **Dead trees**: a new `dead_wood` log (bleached bark, texgen), and a
  forked `dead_tree` with no leaves.
* **Ragged biome borders for every biome**: columns near a border pick
  between the two strongest biomes using the detail noise. The straight
  snow edges (taiga/snowy taiga, tundra/grass) and sand edges now fray
  naturally.

### How to see it (seed 20261009)
* A sheer striped mesa cliff over a red-sand shore:
  `voxelb.exe --pos -515 135 425 --look 355 -6`.
* The same pocket from above: `voxelb.exe --pos -512 260 470 --look 0 -35`.
* Hoodoos and arches are rare (~1 per 150×150 and 400×400 blocks).

### Bugs found and fixed while testing
* The first climate pocket gave only 0.3% of land in scattered spots.
  Widened to ~2%, restricted to deserts.
* Low badlands near lakes showed beach sand, because the shore band
  ignored the biome. Fixed with `beach_block`.
* The first mesa mask was too weak (small bumps). The threshold and ramp
  were raised and the noise widened.
* Biome edges ran in straight lines along the blend lattice: the ragged
  borders above.

### Verified
* Debug and release headless tests pass. The debug build ran at the
  badlands with no asserts.
* Screenshots:
  * the striped mesa cliff;
  * the badlands from above;
  * hoodoos, an arch and gold in the cliffs, with their frequency raised
    for the test;
  * the tundra with ragged borders.

### Known issues
* The badlands pockets near the origin are a few hundred blocks wide, not
  the 600–1500 of a large region. They are bounded by the desert climate
  and the weirdness pocket.
* Where a pocket's ragged edge crosses a mesa cliff, the cliff turns to
  the neighbour's steep block (stone or sandstone).

### Performance
Unchanged within noise: generation ~15 ms per column, meshing ~13 ms.
0.4 FPS on software GL in views with jungle in range.

---

## Milestone 10, part 8 — done (2026-10-10)

### Design interview
Three rounds plus approval: `design/biomes/snowy_tundra.md`.
* Large, bright, wind-swept snowy plains, fully snow-covered, with small
  bare patches of gravel and frozen dirt.
* Twiggy dwarf shrubs (some with red berries) and very rare stunted
  snowy spruces.
* Snow-capped boulders, snow drifts and small frozen ponds.

### What was built
* **Snowy tundra** (`data/biomes/52_snowy_tundra.biome`), on ~8.6% of
  land near the origin, in the cold, dry climate. The undesigned "none"
  land is down to ~13%.
* **Biome settings** (D65):
  * `top_patch_low`: a second patch kind where the detail noise is low;
  * `pond_top`: frozen ponds with an ice top over water.
* **New blocks**: `dwarf_shrub`, `lingonberry_shrub` (texgen).
* **Trees** (all data): `stunted_spruce`, `tundra_boulder`,
  `big_tundra_boulder` (snow caps) and `snow_drift`. MAX_TREES went from
  32 to 64.

### How to see it (seed 20261009)
* The tundra with frozen ponds, gravel and frozen-dirt patches, boulders
  and spruces: `voxelb.exe --pos 53 175 -285 --look 0 -50`.
* Out over the tundra towards a mountain and the coast:
  `voxelb.exe --pos 128 135 -128 --look 30 -12`.

### Bugs found and fixed while testing
* The tree registry was full (32): the new trees were dropped with a
  warning. It now holds 64.
* The first climate box gave 7.1% of land. Widened to 8.6%.
* The shrubs were too dense for a "full snow" look. Halved.

### Verified
* Debug and release headless tests pass. The debug build ran in the
  tundra with no asserts.
* Screenshots:
  * the tundra from above and at an angle;
  * frozen ponds, both patch kinds, boulders, spruces and shrubs.

### Known issues
* Snow drifts are subtle (white on white) until lighting and shadows come
  in M13–M14.
* The edge between snow and grass biomes is a sharp line (as between
  taiga and snowy taiga).

### Performance
Unchanged: generation ~16 ms per column, meshing ~14 ms with the jungle
and taiga in range. 4 FPS on software GL over the tundra (~300k quads).

---

## Milestone 10, part 7 — done (2026-10-10)

### Design interview
Four rounds plus approval: `design/biomes/jungle.md`.
* A hot, wet, very dense rainforest on rugged hills, in saturated emerald.
* Three layers: rare kapok giants, a closed canopy of mid trees, and a
  floor of bushes, ferns and tropical flowers.
* Vines everywhere, shelf fungi, cocoa pods, melon patches, bamboo groves
  and pools in the hollows.

### What was built
* **Jungle** (`data/biomes/55_jungle.biome`), on ~6% of land near the
  origin, in the hot and wet climate that had no biome before.
* **Kapok giants** (new kind `kapok`): buttress fins, a tall bare trunk, and
  thick branches ending in a wide umbrella crown, 30–45 tall.
* **Tree decorations from data** (D64): trunk vines, hanging strands, shelf
  fungi and cocoa pods (`vines`, `hanging_vines`, `fungus`, `pods`,
  `vine_length`).
* **Bamboo groves** (new kind `grove`) and a new `stalk` shape.
* **New blocks and textures:**
  * `vine`, `hanging_vine`, `shelf_fungus`, `cocoa_pod`, `melon`;
  * `bamboo`, `bamboo_leaves`;
  * `heliconia` (2 tall), `orchid`, `bird_of_paradise`, `hibiscus`.
* **Biome settings in use:**
  * melon patches use the meadow feature (64-block cells);
  * pools in the hollows use ponds with `pond_slope`;
  * jungle leaves are foliage-tinted.

### How to see it (seed 20261009)
* The canopy with kapoks rising above it:
  `voxelb.exe --pos -150 230 60 --look 250 -20`.
* The jungle floor (vines, strands, fungi, pods):
  `voxelb.exe --pos -150 128 60 --look 160 -8`.
* Melon patch and flowers on a jungle hillside:
  `voxelb.exe --pos -85 146 40 --look 0 -35`.
* Bamboo groves are rare (about one per 300×300 blocks); the nearest place
  inside the jungle is in the `--survey` output.

### Bugs found and fixed while testing
* The first climate box gave the jungle only 2% of land. It was widened
  in steps to 6%.

### Verified
* Debug and release headless tests pass. The debug build ran in the
  jungle with no asserts.
* Screenshots:
  * the canopy;
  * the floor;
  * kapoks and bamboo groves, with their weights raised for the test;
  * flowers and melons, with trees switched off for the test.
* A top-down view checked that the jungle colour blends smoothly into its
  neighbours.

### Known issues
* The jungle is the heaviest biome so far:
  * dense views draw 1.5–2.3M quads, 0.4–0.5 FPS on software GL;
  * generation and meshing are each ~4 ms slower per column (the leaves,
    vines and strands).
  * The GPU-driven pipeline (M11) and LOD (M12) are the planned answer.
* Buttress fins look a little stepped.

### Deferred
* Waterfalls wait for flowing water (M15).
* Eating cocoa and melons waits for items (M18).
* Jungle animals wait for the entity milestones.

### Performance
* Generation ~14–16 ms per column, meshing ~12.5–13.5 ms, in and around
  the jungle.
* Elsewhere unchanged (~10–11 and ~9 ms).

---

## Milestone 10, part 6 — done (2026-10-09)

### Design interview
Two rounds plus approval: `design/biomes/savanna.md`.
* Golden dry grassland, mostly flat, with rare flat-topped plateaus.
* Scattered acacias, earthy termite-mound spires 3–6 tall, and rare huge
  baobabs.

### What was built
* **Savanna** (`data/biomes/45_savanna.biome`), on ~9% of land near the
  origin. It sits between plains and desert.
* **Plateaus** (D63): a new `plateaus` noise mask and the biome setting
  `plateau_height`. The tops are flat and the steep sides are coarse dirt.
* **Generator kinds** `acacia` (forked trunk with flat leaf pads) and
  `baobab` (bulging bottle trunk with stubby branches).
* **Termite mounds**: a new `termite_mound` block, placed as `rock` spires.
* **Survey**: logs the nearest plateau top.
* **Biome tint fixed (all biomes)** (D63). Biome grass and foliage colours
  had never reached the screen in any biome:
  * the world origin passed to the shader was read from the wrong offset;
  * the tint factor was capped at ×2.
  * Plains, forests, birch groves, oases and both taigas now show their
    designed colours.

### How to see it (seed 20261009)
* Golden savanna with acacias and termite mounds:
  `voxelb.exe --pos -280 140 -20 --look 250 -15`.
* From above: `voxelb.exe --pos -300 230 -60 --look 270 -30`.
* A plateau rising from the savanna:
  `voxelb.exe --pos -470 150 192 --look 90 -8`.
* Baobabs are rare (about one per 150×150 blocks). Look around
  `--pos -280 150 -20`.

### Bugs found and fixed while testing
* The tint bug above.
* The first savanna climate box took land from the desert. Fixed by giving
  the desert priority 1 and the oasis priority 2.

### Verified
* Debug and release headless tests pass.
* Screenshots:
  * golden grass with acacias and termite mounds;
  * a plateau seen from the side;
  * baobabs (with their weight raised for the test);
  * plains, taiga and snowy taiga showing their own colours after the tint
    fix.

### Known issues
* Plateau sides are steep ramps rather than sheer cliffs.
* Grass plants are a darker, olive gold than the grass blocks, because
  their textures are darker.

### Performance
Unchanged: generation ~10–11 ms per column, meshing ~9 ms; 3–5 FPS on
software GL in savanna views (~320–560k quads drawn).

---

## Milestone 10, part 5 — done (2026-10-09)

### Design interview
Two rounds plus approval: `design/biomes/taiga.md`.
* A large, dense, cool-green taiga with tall layered conical spruces.
* Ferns, grass, red berry bushes, mossy boulders and needle litter.
* A colder snowy taiga beside it.

### What was built
* **Taiga** (`data/biomes/50_taiga.biome`) and **snowy taiga**
  (`51_snowy_taiga.biome`). Together they cover ~27% of land near the
  origin; the undesigned "none" land is down to ~31%.
* **Conifer trees** (D62): layered spruce cones; snowy spruces use
  `spruce_snowy_leaves`.
* **New blocks**: `spruce_needle_floor` (needle litter), `berry_bush`.
* **Mossy boulders**: rocks can take a second block for their upper half.
* **Fallen spruces.**

### How to see it (seed 20261009)
* Taiga over a coast: `voxelb.exe --pos 384 190 -200 --look 0 -20`.
* Inside the taiga: `voxelb.exe --pos 384 135 -230 --look 330 0`.
* Snowy taiga beside the taiga:
  `voxelb.exe --pos 448 200 -390 --look 0 -25`.

### Bugs found and fixed while testing
* Spruce trunks poked out above the needles. The trunk now stops 3 below
  the tip.

### Verified
* Debug and release headless tests pass.
* Screenshots:
  * the taiga from the air;
  * among the spruces;
  * the snowy taiga next to the taiga.

### Known issues
* The snow edge between taiga and snowy taiga is a sharp line.

### Performance
Unchanged (generation ~12 ms per column, meshing ~10 ms). Dense taiga
views draw ~900k quads, about 1.3–1.5 FPS on software GL.

---

## Milestone 10, part 4 — done (2026-10-09)

### Design interview
Two rounds plus approval: `design/biomes/desert.md`.
* Large golden-sand deserts with rolling dunes and flat basins, sandstone
  below.
* Flowering cacti with some arms, and dead bushes.
* Sandstone boulders, spires and rare arches; half-buried fossils.
* Very rare, lush oases.

### What was built
* **Desert biome** (`data/biomes/40_desert.biome`):
  * ridged dunes up to 20 high (D61);
  * sand over sandstone, with sandstone on steep slopes;
  * cacti, dead bushes, boulders, spires, arches and fossils.
* **Oasis** (`41_oasis.biome`): rare pockets inside deserts with grass,
  pools, palms, bushes and flowers.
* **New generator kinds** in `flora.asm`:
  * `cactus`: arms, plus a flower on top;
  * `rock`: boulders and spires;
  * `arch`: a sandstone half-ring;
  * `fossil`: a bone spine and ribs;
  * `palm`: a curved trunk with drooping fronds.
* **New blocks**: `cactus`, `cactus_flower`, `dead_bush`, `bone_block`.
* **Biome settings**: `dune_height`, `steep_block`, `pond_slope`; noise
  `dunes` (ridged). Tree setting `chance`.
* Pond cells are now 64 blocks. Plains and forest chances were rescaled.

### How to see it (seed 20261009)
* Desert with dunes, cacti and a spire:
  `voxelb.exe --pos -448 170 130 --look 0 -20`.
* Flowering cacti with arms, dead bushes:
  `voxelb.exe --pos -458 130 120 --look 330 -25`.
* Oasis (palms, pools, grass) near a coast:
  `voxelb.exe --pos -1250 150 -1880 --look 300 -35`,
  or from above `--pos -1230 210 -1900 --look 0 -89`.
* Arches and fossils are rare (about one per 400×400 and 300×300 blocks).
  The survey does not list them yet.

### Bugs found and fixed while testing
* Oasis pools were missing:
  * the pond rim had to be nearly flat (oases sit on slopes);
  * ponds were refused at beach height.
  * Fixed with `pond_slope`, 64-block pond cells, and a sea-level check
    instead of a beach check.
* The first desert climate box gave deserts on only 4.7% of land near the
  origin; widened to 7.6%.

### Verified
* Debug and release headless tests pass.
* Screenshots:
  * dunes with cacti and dead bushes;
  * a flowering cactus with arms;
  * a sandstone spire;
  * fossils and an arch (with their density raised for the test);
  * an oasis with palms and pools.

### Performance
Unchanged: generation ~11–13 ms per column, meshing ~10–11 ms; 3–4 FPS
on software GL.

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
