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
| Cow | spotted black-white (plains, meadow); brown (forest, birch, dark forest, taiga); shaggy red highland (snowy taiga, tundra, steppe, alpine meadow); pale zebu (savanna) | calm | wheat | raw beef 1–3, raw leather 0–2 | milk with a bucket |
| Sheep | natural wool shades — white, cream, grey, brown, black; warmer tones in warmer biomes, a rare russet one. Mountain rams with curled horns on alpine meadows (plains, meadow, steppe, alpine meadow) | calm | wheat | raw mutton 1–2, 1 wool of its shade | shears take 1–3 wool; regrows after grazing |
| Pig | pink pig (plains, meadow, forest edges); bristly brown wild boar with tusks (forest, dark forest, old growth, jungle) | pig calm; boar charges back when hit | carrot, berries | raw pork 1–3 | |
| Chicken | white hen (plains, meadow); speckled brown (forests); colourful jungle fowl (jungle) | calm | seeds | raw chicken 1, feathers 0–2 | lays an egg every 5–10 min; flutters down slowly |
| Deer | red deer, bucks with antlers (forest, old growth, dark forest); white-tailed (birch grove); reindeer (taiga, snowy taiga, tundra) | wild: flees within ~12 blocks, leaps 2 blocks | berries (apples later) | raw venison 1–3, raw deer hide 0–2, antler 0–1 (bucks) | fawns spotted |
| Rabbit | brown (plains, meadow, forest); sandy (desert, badlands, savanna); white (snowy biomes) | wild: hops, flees | carrot, berries | raw rabbit 1, raw rabbit hide 0–1, rabbit's foot (rare) | nibbles flowers |
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

## Recipes (approved 2026-10-14)
| Item | Recipe |
|---|---|
| Bucket | 3 iron bars in a V (workbench) |
| Shears | 2 iron bars diagonally (workbench) |
| Lead | 4 leather + 1 iron bar (workbench) |
| Name tag | 1 leather + 1 iron bar (workbench) |
| Cooked meats | smelt the raw meat in a furnace |

Naming: right-click an animal with a name tag; a small journal page asks
for the name; the tag is used up.

## Hides and drying (owner, 2026-10-14)
Animals drop **raw** hides that must be salted and dried before they are
leather:
* cows drop **raw leather**, deer **raw deer hide**, rabbits **raw rabbit
  hide** (no plain leather from animals any more);
* **salt first**: a raw hide + salt (crafted by hand) gives a **salted** hide;
* hang a salted hide on a **drying rack** (a placeable wooden block): right
  click puts it up (it shows on the rack), it dries in **about 2 minutes**,
  right click takes the result: salted raw leather → leather, salted deer
  hide → leather, salted rabbit hide → dried rabbit hide (4 of those craft
  into 1 leather);
* only salted hides can be hung; the rack holds one hide.

## Build order
1. Entity framework: storage, physics, rendering of cuboid models, hits, drops, saving per region, spawning — with the **cow** (all variants).
2. Pathfinding + behaviours: wander, flee, follow food, herds, grazing, sleep, breeding, babies.
3. Part 3a: hides, salt and the drying rack; sheep (shearing, wool regrowth), pig and wild boar, chicken (eggs); forage (seeds from grass, wild carrots, berries); shears.
4. Part 3b: deer, rabbit, goat; bucket and milking; leads; name tags.


## Still open
* Pigs and boars drop only pork (owner, 2026-10-14).
* Uses for antlers, goat horns, feathers and rabbit's feet (crafting, magic M27).
* Taming/pets, horses (steppe interview), bees, arctic animals, fish — later animals.

## Built
* **Part 1 (v0.19.1)**: the animal engine (data files, herds at
  generation and the trickle, saving, hits, loot, box models with
  shadows) and the **cow** in its four looks. Raw and cooked beef,
  leather. Not yet: paths, following food, herds keeping together,
  grazing, sleep, breeding (part 2); the other animals (part 3).
* **Part 2 (v0.19.2)**: A* paths; following a player holding wheat;
  feeding (right click) and breeding, babies that keep near a grown-up and
  grow up in 20 minutes; herds that stay together, gather and lie down at
  night and run together; grazing (grass → dirt, grows back). Wild wheat
  plants (plains, meadow, steppe) give wheat.
* **Part 3a (v0.19.3)**: raw leather from cows, salt, the drying rack
  (hang a salted hide, leather in 2 minutes); sheep in seven looks with
  mixed flocks, shears, shorn coats growing back on grazing; pigs and
  fierce wild boars; chickens that flutter down and lay eggs; seeds from
  grass, wild carrots, berries; cream and russet wool. My own choice to
  check: the drying rack recipe (6 sticks: `SSS / S.S / S.S`).
* See them all: `voxelb.exe --mob-gallery --pos 41.5 108 -36 --look 0 -20`
  (or `--mob-gallery sheep`, `pig`, `boar`, `chicken`, `ram`).
* See them: the plains around spawn of the default seed (20261009),
  e.g. `voxelb.exe --pos 41.5 106 -36 --look 0 -25`.
