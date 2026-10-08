# Voxel Game in x86-64 Assembly — Project Spec & Agent Instructions

You are the lead engineer on this project. This file is the source of truth for
WHAT we are building and HOW you must work. Re-read it at the start of every
session. Your job is to WRITE, BUILD, RUN and FIX code — not to plan or describe it.

---

## 1. Rules for the agent (non-negotiable)

1. **Execute, don't plan.** When given a milestone, write the code, build it, run it,
   fix errors, and only then report. Never answer with only a plan.
2. **No placeholders.** Never leave stubs, `; TODO: implement`, empty routines, or
   "rest unchanged" comments in place of real code. If something is deliberately
   deferred to a later milestone, it must still compile and behave sensibly (e.g. a
   feature flag that is off), and be listed in `PROGRESS.md` under "Deferred".
3. **Always build and run.** After every meaningful change: assemble, link, launch,
   and check the result. A milestone is not done until it builds with zero errors and
   runs without crashing. If you cannot see the screen, add logging / screenshot dumps
   / headless test modes so you can verify behavior yourself.
4. **One milestone at a time.** Finish the current milestone fully before starting the
   next. Keep each milestone small enough to finish in one session. Split if needed.
5. **Keep `PROGRESS.md` updated** at the end of every milestone: what was done, what
   works, known bugs, deferred items, next milestone. This is your memory across sessions.
6. **Commit to git** after each working milestone with a clear message.
7. **I design the game, you engineer it.** Split every open question into two kinds:
   - **Technical** (data structures, algorithms, shaders, file formats, threading):
     decide yourself, choosing what best serves *vibrant visuals* and *performance*,
     note it in `DECISIONS.md`, and keep going. Only ask if it's expensive to undo.
   - **Creative / gameplay** (what a biome looks like, what lives there, what a mob
     does, recipes, item stats, boss attacks, how a mechanic feels): **always ask me
     first** using a Design Interview (section 1a). Never invent creative content
     on your own without my answers.
8. **Never break expandability.** All game content (blocks, items, biomes, mobs,
   recipes, structures, realms, loot) comes from data files, never hardcoded tables.
9. **Measure performance.** Every rendering/world milestone must report FPS, frame
   time, and chunk gen/mesh times in the debug overlay and in `PROGRESS.md`.

---

## 1a. Design Interviews — how we decide content together

Milestones marked **🎨 DESIGN** in the roadmap start with an interview, and so does
any time you're about to add new creative content (a new biome, mob, item set,
structure, boss, realm, mechanic). The flow:

1. **Stop before writing content code.** Tell me what you're about to build and that
   you need my input. (You may build the underlying *engine system* first — e.g. the
   biome framework — since that's technical.)
2. **Ask questions in rounds of 3–5**, using your multiple-choice question tool if
   you have one, otherwise a numbered list. Every question should offer 2–4 concrete
   options plus "something else", and mark your recommendation. Ask about the look,
   feel, contents and rules — e.g. for a biome: terrain shape, colors/palette, blocks,
   plants and trees, animals and mobs, structures, ambient sound/music, weather,
   resources, rarity, how it borders other biomes.
3. **Ask follow-ups based on my answers.** Dig into anything I got excited about or
   left vague. Keep going until you could build it without guessing. If I say "you
   decide" for something, make a choice and tell me what you chose.
4. **Write it down.** Save the result as a design doc in `design/` (e.g.
   `design/biomes/glowing_forest.md`): a short summary, every decision, and anything
   still open. Show me a summary and let me correct it.
5. **Then build it**, following the design doc exactly. When it's in-game, tell me how
   to go see it (e.g. a seed + coordinates or a debug teleport command) so I can react,
   and ask if anything should change.
6. **Ideas of your own are welcome** — suggest them as options in the interview, never
   sneak them in.

For big content groups (e.g. "all the cold biomes"), interview one item at a time,
starting with the most important, and build each before the next so I can see
progress. Keep a running list of everything still to design in `design/BACKLOG.md`.

---

## 2. Tech stack (fixed)

| Area | Choice |
|---|---|
| Language | x86-64 assembly, **NASM** syntax. GLSL for shaders. |
| Platform | **Windows x64**, Win32 API directly (no SDL/GLFW). |
| Linker | MSVC `link.exe` or `lld-link` (pick one, document in `BUILD.md`). |
| Graphics | **OpenGL 4.6 core** via WGL (`wglCreateContextAttribsARB`), compute shaders allowed and encouraged. Load GL functions manually. |
| Audio | XAudio2 (3D positional via X3DAudio) or WASAPI. |
| Input | Raw Input for mouse, Win32 keyboard messages; rebindable. |
| Threads | Win32 threads + a custom job system with lock-free queues. |
| SIMD | SSE4.2 baseline, AVX2 fast paths with CPUID detection. |
| Build | One script `build.bat` that builds everything from a clean checkout. |

### Assembly conventions
- Strict **Win64 ABI**: shadow space, 16-byte stack alignment at calls, preserve
  nonvolatile registers (RBX, RBP, RDI, RSI, R12–R15, XMM6–XMM15).
- One module per system (`src/render/`, `src/world/`, `src/ui/` …), with `%include`d
  headers for structs (`struc`/`endstruc`), constants and macros.
- Every procedure has a header comment: purpose, inputs, outputs, clobbered registers.
- Use macros for prologue/epilogue, Win32/GL calls and error checks to keep code readable.
- Debug build with logging + asserts; release build stripped and optimized.

---

## 3. Performance targets (top priority alongside visuals)

- **Default:** 16 chunks full detail + **64 chunks LOD** at **60+ FPS** on a mid-range
  PC (GTX 1060 / RX 580 class GPU, 4–6 core CPU).
- **Scalable up to:** 64 chunks full detail + **256 chunks LOD** on high-end hardware.
- No stutter while moving: generation and meshing run on worker threads; main thread
  never waits on chunk work.
- Required techniques (implement progressively):
  - Palette-compressed chunk storage; cubic sections.
  - Greedy or binary greedy meshing (AVX2), or compute-shader meshing.
  - Packed vertex/quad formats (vertex pulling from SSBOs).
  - GPU-driven rendering: persistent mapped buffers, `glMultiDrawElementsIndirect`,
    compute-shader frustum culling + Hi-Z occlusion culling.
  - Multi-level LOD (2×/4×/8×/16× downsampled meshes) for distant terrain, with
    seam/skirt handling and smooth transitions.
  - Memory pools/arenas, no per-frame heap allocation.

---

## 4. World

### Dimensions
- Horizontally **infinite** (practically limited only by coordinate precision; use
  chunk-relative coordinates for rendering to avoid float jitter far from origin).
- Vertical range **Y = -256 to 1024**. Sections of 32×32×32 (40 sections per column).
- Typical land level **≈ 100**. Sea level ≈ 96 (configurable per realm).
- Fully **seed-based** and deterministic: same seed → same world, always.

### Terrain generation
- Layered noise (OpenSimplex2 or similar, SIMD) driving parameters such as
  continentalness, erosion, peaks/valleys, temperature, humidity, weirdness — mapped
  through tunable spline curves in data files.
- **Mountains in tiers:** hills → mountains → high mountains → rare **giant ranges**
  reaching toward Y 1000. Giant peaks only appear in large, rare ranges, never alone.
  Cliffs, overhangs, plateaus, valleys between ranges.
- **Underground:** large 3D-noise caves (huge open caverns, winding tunnel networks,
  narrow passages), deep **ravines** cutting from the surface, underground lakes and
  aquifers, lava lakes deep down, cave biomes.
- **Water:** oceans (shallow/deep), rivers that follow terrain, lakes; flowing water.
- **Ores** distributed by depth and biome; rarer and more valuable deeper, requiring
  higher tool tiers.
- **Structures:** trees (varied per biome), rock formations, villages, ruins,
  dungeons, boss arenas. Structure placement is seed-based and data-driven.

### Biomes (all data-driven)
- **Temperate:** plains, forest, birch forest, dark forest, meadow, river.
- **Hot/dry:** desert, savanna, badlands/mesa, jungle, swamp.
- **Cold:** taiga, snowy tundra, ice spikes, glaciers, frozen ocean.
- **Fantasy/exotic:** mushroom fields, crystal caves, floating islands, glowing forests.
- Smooth biome blending (colors, height, vegetation) — no hard seams.

### Realms / dimensions
- A realm system from early on: each realm has its own generator settings, biomes,
  sky/fog/lighting, gravity/rules, mobs, and save folder. The overworld is just the
  first realm. New realms are added via data files + optional new generator modules.

---

## 5. Visuals — vibrant, connected, Minecraft-like but prettier

- Textured blocks (pixel art) using a **texture array**, with biome tinting for grass,
  leaves, water. Colors should be **saturated and vibrant**, never washed out.
- **Lighting:** sunlight + **colored (RGB) block light** with flood-fill propagation
  (torches warm, crystals blue/purple, lava orange). **Held torches/light items emit
  dynamic light** around the player. Smooth lighting + ambient occlusion.
- **Shadows:** cascaded shadow maps from the sun/moon, soft edges.
- **Water:** transparent, animated, with **reflections** (screen-space + sky fallback),
  refraction, depth-based color, foam at shores, underwater fog.
- **Sky:** physically-inspired atmosphere, sun, moon, stars, colorful sunrises/sunsets,
  volumetric-looking clouds.
- **Fog:** distance + height fog that blends LOD terrain into the sky for sweeping
  vistas; biome-tinted.
- **Day/night cycle** and **weather** (rain, snow, storms with lightning, cloud cover)
  that affect lighting, fog and sound.
- Post-processing: HDR, tonemapping, color grading, bloom. All effects toggleable in
  settings with quality presets (Low/Medium/High/Ultra).

---

## 6. Gameplay

### Modes & difficulty
- **Creative:** unlimited blocks, flying, no damage, instant break.
- **Survival** with difficulties: **Peaceful, Normal, Hard, Extreme, Ultra.**
  - Extreme and Ultra add **temperature and thirst** systems.
  - **Hardcore** (one life, world locked on death) is a toggle available on
    Hard, Extreme and Ultra.
- **Adventure** (no free block breaking; for maps) and **Spectator** (fly through
  blocks, observe).

### Player & survival
- Physics: walking, sprinting, sneaking, jumping, swimming, climbing, fall damage.
- Health, hunger (food, cooking, starvation, regeneration).
- Extreme/Ultra: body temperature (biome, weather, time, clothing, fires) and thirst
  (dirty water causes sickness; **filtered/boiled water**, canteens, water filters,
  insulated/cooling gear — RLCraft-style).
- Crafting (hand + workbench + specialized stations), tool tiers with durability,
  mining speed by tool/material, smelting.

### Combat
- **Melee:** swords, axes, spears with swing timing/cooldown, knockback.
- **Ranged:** bows, crossbows, throwables, with projectile physics.
- **Armor & stats:** armor tiers, damage resistance, upgrade/enchant-like system.
- **Magic:** spells, staffs, mana.

### Creatures (entity system, data-driven)
- Passive animals per biome (food, materials, breeding).
- Hostile mobs spawning in darkness, caves, at night; difficulty-scaled.
- **Bosses** tied to structures/realms with unique attacks.
- **Villagers/NPCs** in villages with trading.
- Shared AI framework: pathfinding over voxel terrain, behaviors as data.

### Waypoints & map
- Toggleable **minimap** built in.
- **Waypoint beacon:** a hard-to-craft placeable item; each placed beacon appears on
  the minimap/full map with a name.

---

## 7. Interface

- Main menu, **world creation** (name, seed, mode, difficulty, hardcore toggle),
  world list, pause menu.
- Settings: graphics (presets + every effect individually, render distance, LOD
  distance), audio volumes, controls (rebindable), mouse sensitivity, FOV.
- Inventory grid, hotbar, chests, crafting UIs, drag and drop, tooltips.
- HUD: health, hunger, (thirst/temperature on Extreme+), armor, mana, held item.
- **F3-style debug overlay:** FPS, frame times, coordinates, chunk, biome, light
  levels, seed, loaded/queued chunks, gen/mesh times, GPU memory.
- Bitmap/SDF font rendering of our own.

---

## 8. Audio
- Sound effects (footsteps by material, block break/place, combat, mobs, UI).
- **3D positional audio** and ambient soundscapes (wind on mountains, cave echo/reverb,
  rain, water).
- Music per biome/situation with crossfading. Uses a simple audio format (WAV/OGG via
  a small decoder) defined in data files.

---

## 9. Architecture for expansion

- **Data-driven registries** loaded at startup from `data/`: blocks, items, biomes,
  terrain splines, structures, mobs, recipes, loot tables, sounds, realms. Use one
  simple text format (documented in `DATA_FORMAT.md`) with a parser written in asm.
  Adding a new block or biome must require **zero assembly changes**.
- **Multiplayer-ready (single-player for now):** strict split between
  *simulation* (server side: world, entities, ticks at fixed 20 TPS) and *client*
  (rendering, input, audio, UI). They communicate only through a message queue of
  serializable packets, so a network transport can be added later without a rewrite.
  All world changes go through commands/events. Simulation is deterministic where possible.
- **Save system:** region files of compressed chunks, player data, world metadata
  (seed, mode, difficulty, realm states), versioned format with upgrade path. Autosave.
- **Systems are modules** with clear init/update/shutdown entry points.

---

## 10. Repository layout

```
build.bat            BUILD.md   PROGRESS.md   DECISIONS.md   DATA_FORMAT.md
src/
  core/      (entry, memory, jobs, timing, logging, math, noise)
  platform/  (win32 window, input, files, threads)
  render/    (gl loader, shaders, chunk meshing, LOD, sky, water, shadows, post, ui draw)
  world/     (chunks, generation, biomes, structures, lighting, saving, realms)
  sim/       (server-side tick, entities, physics, AI, gameplay, crafting)
  ui/        (menus, hud, inventory, debug overlay, font)
  audio/
  include/   (structs, constants, macros)
shaders/
data/        (blocks, items, biomes, mobs, recipes, structures, realms, sounds)
assets/      (textures, sounds, music)
tools/       (helper scripts, e.g. texture packing, test runners)
design/      (design docs from our interviews + BACKLOG.md)
```

---

## 11. Roadmap (milestones — do them in order)

**Foundation**
1. Toolchain + `build.bat`; Win32 window, message loop, clean exit; logging.
2. OpenGL 4.6 core context via WGL, GL loader, clear color, vsync toggle, timing/FPS.
3. Raw input, rebindable keys, fly camera, shader loading/hot-reload, debug text overlay.
4. Memory arenas/pools, job system with worker threads.

**World core**
5. Chunk/section data structures (palette compression), flat test world, mesher, render.
6. Infinite streaming: load/unload around player on worker threads, no stutter.
7. Data-driven block registry + parser + texture array.
8. 🎨 DESIGN — Terrain: heightmap noise + splines, tiered mountains and rare giant ranges.
9. 🎨 DESIGN — Caves, ravines, aquifers, lava, ores.
10. 🎨 DESIGN — Biomes + blending + vegetation/trees.

**Rendering power**
11. GPU-driven pipeline: persistent buffers, multi-draw indirect, compute culling, Hi-Z.
12. LOD system to 64+ chunks (scalable to 256).
13. Lighting: skylight + RGB block light propagation, smooth light, AO, held lights.
14. Sky, day/night, fog, cascaded shadows, HDR/tonemap/bloom.
15. Water rendering (reflections, refraction) + flowing water simulation.

**Playable game**
16. Sim/client split + message queue; player physics & collision; break/place; Creative.
17. Save/load (region files) + main menu, world creation with seed, settings menus.
18. 🎨 DESIGN — Items, inventory, hotbar, chests, crafting, tool tiers, smelting.
19. 🎨 DESIGN — Entity framework + passive animals + pathfinding.
20. 🎨 DESIGN — Survival: health, hunger, damage, death, difficulties Peaceful→Ultra, Hardcore.
21. 🎨 DESIGN — Combat: melee, ranged, armor.
22. 🎨 DESIGN — Hostile mobs + spawning rules.
23. 🎨 DESIGN — Structures: villages, ruins, dungeons.
24. 🎨 DESIGN — Audio: SFX, 3D positional, ambient, music.
25. 🎨 DESIGN — Weather.
26. 🎨 DESIGN — Villagers/NPCs + trading.
27. 🎨 DESIGN — Magic.
28. 🎨 DESIGN — Temperature & thirst + gear (Extreme/Ultra).
29. 🎨 DESIGN — Bosses.
30. 🎨 DESIGN — Minimap + waypoint beacons.
31. 🎨 DESIGN — Realm system: second realm.
32. Adventure & Spectator modes.
33. Performance & visual polish pass; quality presets tuned to targets.

🎨 DESIGN milestones: build the engine system first if needed, then run a Design
Interview (section 1a) for each piece of content before building it. Biomes, mobs,
structures, bosses, realms, items and magic are each interviewed one at a time.

Later milestones can be split further. Add new ones to the end; don't reorder
finished ones.

---

## 12. Definition of done (every milestone)

- [ ] For 🎨 DESIGN work: design doc written in `design/` and approved by me.
- [ ] Builds from clean with `build.bat`, zero errors.
- [ ] Runs and the new feature visibly/measurably works (verified by you).
- [ ] No placeholders; deferred items listed.
- [ ] FPS/timing numbers recorded if rendering or world code changed.
- [ ] `PROGRESS.md` updated; committed to git.
