# Passive animals (Milestone 19)

Interviewed 2026-10-13. Engine: the entity framework, A* pathfinding over
blocks and data-driven behaviours (all technical, see DECISIONS). Content:
seven familiar animals with our own look, each with variants by biome.

## Summary
Blocky cuboid animals (head, body, legs, plus ears/horns/tails boxes) with
16x16-style pixel skins and limb-swing animation. Farm animals are calm and
follow you when you hold their food; wild ones (deer, rabbits) flee. Herds
are placed when chunks generate and a slow trickle refills empty areas.
Animals are always saved and never despawn. Feed two adults to breed; babies
are small with big heads and follow their mother.

## Global rules
| Topic | Decision |
|---|---|
| Model style | blocky cuboids, pixel-art skins, limb swing; per-animal model + skins in data files |
| Identity | familiar real-world animals, our own look and twists |
| Temperament | farm animals calm (follow food); wild ones flee when you come close |
| Hurting | simple hits now: health, damage by held item, knockback, red flash, then it runs. Refined in M21 |
| Drops | raw meat (cooks in the furnace) + the animal's material |
| Breeding | feed two adults of the same kind their food; a baby appears; grows up in ~20 min (feeding a baby speeds it up). Breeding cooldown 5 min |
| Babies | half size, oversized head; fawns spotted, chicks yellow fluff; babies follow their mother |
| Spawning | herds placed at chunk generation (per-biome lists) + slow respawn that refills empty areas; never a flood |
| Density | lively: a herd of 2–6 every few chunks on grassland; fewer in forests and cold biomes |
| Persistence | every animal saved where it is; nothing despawns |
| Movement | real paths (A*): step up 1 block, avoid cliffs/lava, swim across water, walk around obstacles |
| Herds | members stay together; when one is hurt the whole herd flees |
| Grazing | cows, sheep, goats, deer eat grass: the grass block turns to dirt for a while and regrows; sheep regrow wool |
| Sleep | animals lie down at night near their herd and wake at dawn (a hit wakes them) |
| Name tags | a crafted tag names an animal; the name floats above it |
| Leads | a lead leashes an animal to you (rope drawn); tie it to a fence |
| Sounds | wait for the audio milestone (M24) |

## The animals
| Animal | Variants (biome) | Temperament | Food (follow + breed) | Drops | Extras |
|---|---|---|---|---|---|
| Cow | spotted black-white (plains, meadow); brown (forest, birch, dark forest, taiga); shaggy red highland (snowy taiga, tundra, steppe, alpine meadow); pale zebu (savanna) | calm | wheat | raw beef 1–3, leather 0–2 | milk with a bucket |
| Sheep | natural wool shades — white, cream, grey, brown, black; warmer tones in warmer biomes, a rare russet one. Mountain rams with curled horns on alpine meadows (plains, meadow, steppe, alpine meadow) | calm | wheat | raw mutton 1–2, 1 wool of its shade | shears take 1–3 wool; regrows after grazing |
| Pig | pink pig (plains, meadow, forest edges); bristly brown wild boar with tusks (forest, dark forest, old growth, jungle) | pig calm; boar charges back when hit | carrot, berries | raw pork 1–3 | |
| Chicken | white hen (plains, meadow); speckled brown (forests); colourful jungle fowl (jungle) | calm | seeds | raw chicken 1, feathers 0–2 | lays an egg every 5–10 min; flutters down slowly |
| Deer | red deer, bucks with antlers (forest, old growth, dark forest); white-tailed (birch grove); reindeer (taiga, snowy taiga, tundra) | wild: flees within ~12 blocks, leaps 2 blocks | berries (apples later) | raw venison 1–3, deer hide 0–2, antler 0–1 (bucks) | fawns spotted |
| Rabbit | brown (plains, meadow, forest); sandy (desert, badlands, savanna); white (snowy biomes) | wild: hops, flees | carrot, berries | raw rabbit 1, rabbit hide 0–1, rabbit's foot (rare) | nibbles flowers |
| Goat | white shaggy mountain goat (high slopes, alpine meadow) | climbs and jumps 3 blocks; no damage on short falls; sometimes rams you if you stand too close | wheat | raw mutton 1–2, goat horn (sometimes) | milk with a bucket |

## Forage (until farming comes)
* Short grass sometimes drops **seeds** when broken (chicken food).
* **Wild wheat** — a new tall plant on plains, meadow and steppe; picking it gives **wheat**.
* **Wild carrot** — a new plant with white umbel flowers on plains, meadow and forest edges; gives **carrots**.
* **Berry bushes** (already in the world) give **berries**.

## New items
seeds, wheat, carrot, berries; raw/cooked beef, mutton, pork, chicken,
venison, rabbit; egg; leather, feather, deer hide, rabbit hide, antler,
goat horn, rabbit's foot; bucket, milk bucket; shears; lead; name tag.
Cream and russet wool blocks join the 16 dyed wools.
Eating and hunger come in M20; until then food is ingredients and breeding food.

## Proposed recipes (my proposal — please correct)
| Item | Recipe |
|---|---|
| Bucket | 3 iron bars in a V |
| Shears | 2 iron bars diagonally |
| Lead | 4 leather + 1 iron bar (ring) |
| Name tag | 1 leather + 1 iron bar |
| Leather | 1 deer hide, or 4 rabbit hide |
| Cooked meats | smelt the raw meat in a furnace |

Naming: right-click an animal with a name tag; a small journal page asks for the name.

## Build order
1. Entity framework: storage, physics, rendering of cuboid models, hits, drops, saving per region, spawning — with the **cow** (all variants).
2. Pathfinding + behaviours: wander, flee, follow food, herds, grazing, sleep, breeding, babies.
3. Sheep, pig/boar, chicken, deer, rabbit, goat; forage plants and items; shearing, milking, eggs, leads, name tags.

## Still open
* What pigs/boars give besides pork (tusks?) — none for now.
* Uses for antlers, goat horns, feathers and rabbit's feet (crafting, magic M27).
* Taming/pets, horses (steppe interview), bees, arctic animals, fish — later animals.

## Built
* **Part 1 (v0.19.1)**: the animal engine (data files, herds at
  generation and the trickle, saving, hits, loot, box models with
  shadows) and the **cow** in its four looks. Raw and cooked beef,
  leather. Not yet: paths, following food, herds keeping together,
  grazing, sleep, breeding (part 2); the other animals (part 3).
* See them: the plains around spawn of the default seed (20261009),
  e.g. `voxelb.exe --pos 41.5 106 -36 --look 0 -25`.
