# Design backlog

Creative and gameplay content that needs a Design Interview (AGENTS.md §1a)
before it is built. Ordered by roadmap milestone. Nothing has been designed
yet; each item gets its own doc in `design/` when we interview it.

| Status | Item | Milestone | Notes |
|---|---|---|---|
| done | Terrain shape | M8 | `design/terrain/overworld_terrain.md` |
| done | Caves, ravines, aquifers, lava lakes | M9 | `design/terrain/underground.md` |
| done | Ore list, depth ranges, rarity | M9 | `design/terrain/underground.md`; tool tiers in M18 |
| todo | Underground fantasy biomes (unrelated to the surface biome) | after M10 | from the M9 interview |
| todo | Underground structures | M23 | from the M9 interview |
| done | Biome system: size, borders, layout | M10 | `design/biomes/biome_system.md` |
| done | Plains | M10 | `design/biomes/plains.md` |
| done | Forest | M10 | `design/biomes/forest.md` |
| done | Old-growth forest (rare pockets in forests) | M10 | `design/biomes/old_growth_forest.md` |
| done | Birch grove (small pockets in forests) | M10 | `design/biomes/birch_grove.md` |
| done | Dark forest | M10 | `design/biomes/dark_forest.md` |
| done | Rivers (temperate, frozen, muddy, oasis) | M10 | `design/biomes/river.md` |
| done | Steppe (the cool, dry gap) | M10 | `design/biomes/steppe.md` |
| todo | Transition biomes (forest edge, desert scrubland, …) | M10 | from the biome system interview |
| done | Desert + oasis | M10 | `design/biomes/desert.md` |
| done | Savanna | M10 | `design/biomes/savanna.md` |
| done | Jungle | M10 | `design/biomes/jungle.md` |
| done | Badlands | M10 | `design/biomes/badlands.md` |
| done | Swamp | M10 | `design/biomes/swamp.md` |
| done | Taiga + snowy taiga | M10 | `design/biomes/taiga.md` |
| done | Snowy tundra | M10 | `design/biomes/snowy_tundra.md` |
| done | Ice spikes | M10 | `design/biomes/ice_spikes.md` |
| done | Frozen ocean | M10 | `design/biomes/frozen_ocean.md` |
| done | Glacier | M10 | `design/biomes/glacier.md` |
| done | Glowing forest | M10 | `design/biomes/glowing_forest.md` |
| done | Sky islands (floating islands) | M10 | `design/biomes/sky_islands.md` |
| done | Mushroom fields | M10 | `design/biomes/mushroom_fields.md` |
| done | Meadow (and alpine meadow) | M10 | `design/biomes/meadow.md` |
| done | Crystal caves (cave-biome system) | M10 | `design/biomes/crystal_caves.md` |
| todo | Babbling streams down the meadow slopes | M15 | from the meadow interview (needs rivers and flowing water) |
| todo | Fireflies (glowing forests, swamps) and spore haze (mushroom fields): drifting particles | M14+ | from the biome interviews |
| todo | Trees and vegetation per biome | M10 | |
| done | Block set v1 and texture style | M7 | `design/blocks/block_set.md` (262 blocks, 16x16 vibrant shaded) |
| done | Shaped blocks | M7b | `design/blocks/shaped_blocks.md` |
| todo | Sign text, pressure plate mechanisms (wiring) | M16+ | from the M7b interview |
| building | Items, inventory, chests, crafting, tool tiers, smelting | M18 | `design/items/items_inventory.md` |
| done | Passive animals (cow, sheep, pig/boar, chicken, deer, rabbit, goat) | M19 | `design/mobs/passive_animals.md`; later: bees and beehives on meadow trees (meadow interview); seals, polar bears, walruses (frozen ocean interview); river fish (river interview) |
| building | Survival: health, hunger, damage, death, difficulty levels, Hardcore | M20 | `design/survival/survival.md` |
| building | Combat: melee, ranged, armor, runes | M21 | `design/combat/combat.md`; named weapons with dungeons/bosses (M23/M29); accessories later |
| todo | Hostile mobs and spawning rules | M22 | |
| todo | Structures: villages, ruins, dungeons; swamp witch hut; badlands mineshafts | M23 | witch hut and mineshafts from the biome interviews |
| todo | Audio: SFX, ambience, music | M24 | |
| todo | Weather | M25 | |
| todo | Villagers/NPCs and trading | M26 | |
| todo | Magic: spells, staffs, mana | M27 | |
| todo | Temperature and thirst, plus gear (Extreme/Ultra) | M28 | |
| todo | Bosses | M29 | one boss at a time |
| todo | Minimap and waypoint beacon | M30 | |
| todo | Second realm | M31 | |
| todo | Game title, window title, logo | any time | the window is titled "VoxelB" (repo name) for now |
| todo | Rework terrain generation and biomes, and add many more biomes | after M10 (owner, 2026-10-11) | the owner plans a bigger pass on terrain and biomes later |
| todo | Progressive LOD: more detail near the player, fading gradually to no detail at the horizon | M34 (owner, 2026-10-12) | after M12; "for way later" |
| todo | Character preview in the inventory (the player figure on the journal page) | M19+ | from the journal UI interview; needs the player model |
| done | Journal UI, off hand, recipe book toggle, Shift+drag | M18 part 5 | `design/ui/journal_ui.md` |
