# Underground: caves, ravines, aquifers, lava, ores (Milestone 9)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09, 3 rounds.

## Summary
A rich underground: about 10–15% of the rock is hollow. It has:
* huge caverns (bigger deeper down), winding tunnels, narrow passages and
  vertical shafts;
* some cave mouths in hillsides and valleys, rare dramatic ravines, and
  every so often a massive cavern that opens to the sky;
* underground lakes (aquifers) and deep lava lakes;
* stalactites, stalagmites, natural pillars and varied cave floors;
* classic and fantasy ores by depth, with deep-stone variants, mountain
  emeralds and a bonus on cave walls.

All numbers live in `data/world/caves.cfg` and `data/world/ores.cfg`.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Amount | rich: ~10–15% of the underground hollow |
| Cave types | huge caverns, winding tunnels, narrow passages, vertical shafts |
| Entrances | tunnels sometimes open into hillsides and valleys; ravines; and every so often a massive cavern opens to the surface, visible from above ground |
| Ravines | rare and dramatic: 100–300 long, 30–80 deep, cutting into caves |
| Depth | caverns grow bigger and hotter deeper, but some massive caverns are near the surface and visible from above |
| Aquifers | underground lakes with their own water levels; caves under the sea flood with seawater |
| Lava | deep lava lakes in caverns (new lava block: static for now, glowing orange, animated) |
| Decoration | stalactites and stalagmites (new dripstone blocks), pillars in caverns, gravel/clay/mud patches on cave floors |
| Ores | classic + fantasy; mixed cluster sizes with rare large veins; mountain emeralds; slightly more ore on cave walls; diamond and fantasy ores only in deep stone; deep variants of ores that occur below Y 0 |
| Later | underground fantasy biomes (unrelated to the surface biome) and underground structures: own designs later |

## New blocks
* `lava` (glowing orange, animated, light 15/8/2 from M13)
* `dripstone_block`, `pointed_dripstone` (a new spike shape; it tapers
  automatically into base, middle and tip)
* Ores: `coal_ore`, `copper_ore`, `deep_copper_ore`, `iron_ore`,
  `deep_iron_ore`, `silver_ore`, `deep_silver_ore`, `gold_ore`,
  `deep_gold_ore`, `emerald_ore`, `diamond_ore`, `mythril_ore` (blue),
  `adamantite_ore` (red), `star_crystal_ore` (glowing, light from M13)

## Numbers (Claude's proposal, tunable)
### Caves
| Feature | Proposal |
|---|---|
| Caverns | 3D "cheese" noise; rare near Y 60, common below Y 0, largest (50–150 wide) below Y −100; natural pillars come from the noise |
| Tunnels | 3–8 wide, everywhere from Y −240 to just below the surface |
| Narrow passages | 1–2 wide, between Y −200 and 80 |
| Vertical shafts | 2–4 wide, 30–120 deep, rare |
| Cave mouths | tunnels break the surface in about 1 of 6 places where they come close |
| Sky caverns | about one per 2000×2000 blocks: a giant cavern open to the sky |
| Ravines | about one per 1000×1000 blocks; 100–300 long, 6–20 wide at the top, 30–80 deep |
| Aquifers | regions ~64 blocks across each get a water level; ~40% of regions above Y −90 hold a lake; caves below sea level near the sea are flooded |
| Lava | regions below Y −90 get a lava level between Y −230 and −120: cave air below it is lava |
| Dripstone | on about 8% of cave ceiling and floor spots, 1–4 blocks long |
| Floors | gravel, clay and mud patches on ~25% of cave floor area |

### Ores (Y ranges; clusters per 32³ section where common)
| Ore | Y range (peak) | Cluster | Frequency | Notes |
|---|---|---|---|---|
| coal | 0 … 400 (100–200) | 6–14 | very common | +50% inside mountains |
| copper | −40 … 160 (50) | 4–10 | common | + rare large veins |
| iron | −120 … 300 (20, and 250 in mountains) | 4–9 | common | + rare large veins |
| silver | −150 … 40 (−50) | 3–7 | uncommon | |
| gold | −200 … 20 (−100) | 3–7 | uncommon | |
| emerald | 180 … 700, only inside mountains | 1–3 | rare | |
| diamond | −240 … −60 (−180) | 2–6 | rare | deep stone only |
| mythril | −240 … −120 | 2–5 | rare | deep stone only |
| adamantite | −252 … −170 | 2–4 | very rare | deep stone only |
| star crystal | −252 … −200, near lava | 1–3 | rarest | glows |
Ores in deep stone use their `deep_` variant. Cave walls get +30% ore attempts.

## As built (M9)
* Sky caverns are an open bowl from the surface (up to 140 deep in the
  middle) over caverns with natural pillars; they hold no lakes.
* Shafts are round pipes (radius 1.0–1.8), at most one per 160×160 cell,
  in 30% of cells.
* Where two aquifer regions (or a lake and the flooded coast) meet with
  different levels, the rock stays as a thin barrier instead of water
  standing as a wall.
* Ores come out at about 0.2% of the rock in the loaded area with these
  numbers; raise `per_section` in `data/world/ores.cfg` for more.

## Open
* Cave biomes and underground structures (later, own interviews).
* What ores are used for, tool tiers: M18.
